#!/usr/bin/env bash
#
# docker-entrypoint.sh — boot sequence for claude-remote-server.
#
# Remote Control requires subscription auth obtained via the interactive
# `/login` flow. Long-lived OAuth tokens (CLAUDE_CODE_OAUTH_TOKEN) are
# NOT supported by `claude remote-control server`, so the only way to
# authenticate is:
#
#   1. Deploy once with SETUP_MODE=true, exec in, run `claude` and
#      complete `/login` + `/status`. This writes short-lived
#      credentials to /home/claude/.claude/.credentials.json (persistent
#      on the config volume) and onboarding state to
#      /home/claude/.claude.json (NOT in the volume).
#
#   2. Copy the three identity fields from ~/.claude.json into Dokploy
#      as CLAUDE_ACCOUNT_UUID / CLAUDE_EMAIL / CLAUDE_ORGANIZATION_UUID.
#      On every subsequent boot the entrypoint regenerates ~/.claude.json
#      from those vars, so the redeploy doesn't lose onboarding state.
#
#   3. Flip SETUP_MODE=false and redeploy.
#
# Phases, in order:
#   1. Fix ownership of mounted volumes (fresh Docker volumes can come
#      up root-owned, which breaks the non-root `claude` user).
#   2. Strip any API-key env vars that would override subscription auth.
#   3. Optionally start sshd when ENABLE_SSH=true.
#   4. If SETUP_MODE=true, print login instructions and sleep forever.
#   5. Verify persisted credentials exist on the config volume.
#   6. Materialise ~/.claude.json from the onboarding env vars.
#   7. Exec `claude remote-control server`.

set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*"; }
err() { printf '[entrypoint] ERROR: %s\n' "$*" >&2; }

CLAUDE_HOME="/home/claude"
WORKSPACE_DIR="${CLAUDE_HOME}/workspace"
CONFIG_DIR="${CLAUDE_HOME}/.claude"
SSH_DIR="${CLAUDE_HOME}/.ssh"
ONBOARDING_JSON="${CLAUDE_HOME}/.claude.json"

# ---------------------------------------------------------------------------
# 1. Fix volume ownership
# ---------------------------------------------------------------------------
# The named volumes (claude-workspace-data, claude-config-data) mount on top
# of image-built directories. On first boot Docker copies the image contents
# into the empty volume, but subsequent recreates can land as root-owned.
# We fix it every boot so persisted logins don't silently break.
sudo mkdir -p "$WORKSPACE_DIR" "$CONFIG_DIR" "$SSH_DIR" /var/run/sshd
sudo touch "$SSH_DIR/authorized_keys"
sudo chmod 700 "$SSH_DIR"
sudo chmod 600 "$SSH_DIR/authorized_keys"
sudo chown -R claude:claude "$WORKSPACE_DIR" "$CONFIG_DIR" "$SSH_DIR"

# ---------------------------------------------------------------------------
# 2. Strip conflicting API-key auth
# ---------------------------------------------------------------------------
# Claude Code Remote Control requires subscription auth. If an API key
# leaks in via Dokploy env vars it will silently take precedence and the
# server will reject every request.
if [[ -n "${ANTHROPIC_API_KEY:-}" || -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
  log "unsetting ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN (subscription auth only)"
fi
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN || true

# Long-lived OAuth tokens are not supported for `claude remote-control
# server`. Warn loudly if one leaks in via env, then clear it so it can't
# confuse the subscription-auth flow below.
if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  log "WARNING: CLAUDE_CODE_OAUTH_TOKEN is set, but remote-control does not"
  log "         support long-lived tokens. Unsetting and using SETUP_MODE flow."
  unset CLAUDE_CODE_OAUTH_TOKEN
fi

# ---------------------------------------------------------------------------
# 3. Optional sshd
# ---------------------------------------------------------------------------
if [[ "${ENABLE_SSH:-false}" == "true" ]]; then
  if sudo /usr/sbin/sshd; then
    log "sshd started (port 22 inside container)"
  else
    err "failed to start sshd — continuing without SSH"
  fi
else
  log "SSH disabled (set ENABLE_SSH=true to enable)"
fi

cd "$WORKSPACE_DIR"

# ---------------------------------------------------------------------------
# 4. SETUP_MODE: wait for interactive login
# ---------------------------------------------------------------------------
if [[ "${SETUP_MODE:-false}" == "true" ]]; then
  cat <<'MSG'
============================================================
 SETUP_MODE=true — interactive login
============================================================
 Open a terminal into this container (Dokploy terminal or
 `docker exec -it <container> bash`) and run:

     claude
     /login
     /status

 Expected in /status: Claude subscription auth, NOT API key.

 When /status looks good, grab the three identity values:

     jq '.oauthAccount' ~/.claude.json

 and set them in Dokploy as:

     CLAUDE_ACCOUNT_UUID
     CLAUDE_EMAIL
     CLAUDE_ORGANIZATION_UUID

 Then set SETUP_MODE=false and redeploy.
============================================================
MSG
  exec sleep infinity
fi

# ---------------------------------------------------------------------------
# 5. Verify persisted credentials
# ---------------------------------------------------------------------------
# `/login` stores short-lived subscription credentials here; the config
# volume keeps them across redeploys. If they're missing, the user hasn't
# completed the SETUP_MODE flow yet.
if [[ ! -f "$CONFIG_DIR/.credentials.json" && ! -f "$CONFIG_DIR/credentials.json" ]]; then
  err "no persisted Claude credentials found in $CONFIG_DIR."
  cat >&2 <<'MSG'

You need to complete the one-time interactive login first:

  1. Set SETUP_MODE=true and redeploy.
  2. Open a terminal in the container and run:
         claude
         /login
         /status
  3. Copy the three fields from `jq '.oauthAccount' ~/.claude.json`
     into Dokploy as CLAUDE_ACCOUNT_UUID / CLAUDE_EMAIL /
     CLAUDE_ORGANIZATION_UUID.
  4. Set SETUP_MODE=false and redeploy.

MSG
  exit 1
fi

log "persisted credentials: found in $CONFIG_DIR"

# ---------------------------------------------------------------------------
# 6. Materialise ~/.claude.json from onboarding env vars
# ---------------------------------------------------------------------------
# `/login` writes two files:
#   - $CONFIG_DIR/.credentials.json  (persistent, on the config volume)
#   - $CLAUDE_HOME/.claude.json      (NOT on a volume — ephemeral)
#
# Because the second one lives at $HOME instead of inside $HOME/.claude/,
# a Dokploy redeploy wipes it and `claude remote-control server` comes
# up without onboarding state. Regenerate it deterministically from env
# vars on every boot.
if [[ -n "${CLAUDE_ACCOUNT_UUID:-}" \
   && -n "${CLAUDE_EMAIL:-}" \
   && -n "${CLAUDE_ORGANIZATION_UUID:-}" ]]; then
  onboarding_version="${CLAUDE_ONBOARDING_VERSION:-2.1.29}"
  jq -n \
    --arg ver "$onboarding_version" \
    --arg uuid "$CLAUDE_ACCOUNT_UUID" \
    --arg email "$CLAUDE_EMAIL" \
    --arg org "$CLAUDE_ORGANIZATION_UUID" \
    '{
      hasCompletedOnboarding: true,
      lastOnboardingVersion: $ver,
      oauthAccount: {
        accountUuid: $uuid,
        emailAddress: $email,
        organizationUuid: $org
      }
    }' > "$ONBOARDING_JSON"
  chmod 600 "$ONBOARDING_JSON"
  log "wrote $ONBOARDING_JSON (onboarding v$onboarding_version)"
elif [[ -f "$ONBOARDING_JSON" ]]; then
  log "onboarding env vars not set; using existing $ONBOARDING_JSON"
else
  err "no $ONBOARDING_JSON and onboarding env vars are missing."
  cat >&2 <<'MSG'

After your first SETUP_MODE login, copy these three values from
`jq '.oauthAccount' ~/.claude.json` into Dokploy:

  CLAUDE_ACCOUNT_UUID
  CLAUDE_EMAIL
  CLAUDE_ORGANIZATION_UUID

(Optional: CLAUDE_ONBOARDING_VERSION, defaults to 2.1.29)

These rebuild ~/.claude.json on every boot, so subsequent redeploys
don't lose your onboarding state.

MSG
  exit 1
fi

# ---------------------------------------------------------------------------
# 7. Launch the Remote Control server
# ---------------------------------------------------------------------------
log "starting: claude remote-control server --spawn-worktree-sessions ${SPAWN_WORKTREE_SESSIONS:-5}"
exec claude remote-control server \
  --spawn-worktree-sessions "${SPAWN_WORKTREE_SESSIONS:-5}"
