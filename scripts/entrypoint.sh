#!/usr/bin/env bash
#
# docker-entrypoint.sh — boot sequence for claude-remote-server.
#
# Phases, in order:
#   1. Fix ownership of mounted volumes (fresh Docker volumes can come up
#      root-owned, which breaks the non-root `claude` user).
#   2. Strip any API-key env vars that would override subscription auth.
#   3. Optionally start sshd when ENABLE_SSH=true.
#   4. If SETUP_MODE=true, print login instructions and sleep so the
#      operator can `docker exec` in and run `claude` / `/login` / `/status`.
#   5. Resolve which auth source will be used (OAuth env-var token,
#      persisted credentials on the config volume, or fail fast with an
#      actionable error).
#   6. Exec `claude remote-control server`.

set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*"; }
err() { printf '[entrypoint] ERROR: %s\n' "$*" >&2; }

CLAUDE_HOME="/home/claude"
WORKSPACE_DIR="${CLAUDE_HOME}/workspace"
CONFIG_DIR="${CLAUDE_HOME}/.claude"
SSH_DIR="${CLAUDE_HOME}/.ssh"

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

 When /status looks good:
   1. Set SETUP_MODE=false
   2. Redeploy (the named volume keeps your login)
============================================================
MSG
  exec sleep infinity
fi

# ---------------------------------------------------------------------------
# 5. Resolve auth source
# ---------------------------------------------------------------------------
# Priority:
#   a) CLAUDE_CODE_OAUTH_TOKEN env var — preferred headless path.
#   b) Persisted credentials file on the config volume — left behind by a
#      prior SETUP_MODE login.
#   c) Nothing → fail fast with an actionable error, so Dokploy shows a
#      real error instead of a silent crash-loop.
auth_source=""

if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  auth_source="env-var OAuth token (CLAUDE_CODE_OAUTH_TOKEN)"
elif [[ -f "$CONFIG_DIR/.credentials.json" || -f "$CONFIG_DIR/credentials.json" ]]; then
  auth_source="persisted credentials in $CONFIG_DIR"
fi

if [[ -z "$auth_source" ]]; then
  err "no Claude authentication available."
  cat >&2 <<'MSG'

Fix one of the following and redeploy:

  1. Generate an OAuth token on a machine with browser access:
         claude setup-token
     then set CLAUDE_CODE_OAUTH_TOKEN in your Dokploy env.

  2. Or set SETUP_MODE=true, redeploy, open a container terminal,
     run `claude` and complete `/login` + `/status`, then set
     SETUP_MODE=false and redeploy again.

MSG
  exit 1
fi

log "auth source: $auth_source"

# ---------------------------------------------------------------------------
# 5b. Materialise ~/.claude.json from onboarding env vars
# ---------------------------------------------------------------------------
# The OAuth token alone is not enough: claude-code also reads
# /home/claude/.claude.json to confirm onboarding is complete and to know
# which account / organization the token belongs to. That file lives at
# $HOME, not inside the $HOME/.claude/ config volume, so it would be lost
# on every container rebuild — we regenerate it deterministically from
# env vars on every boot instead.
ONBOARDING_JSON="$CLAUDE_HOME/.claude.json"

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
elif [[ "$auth_source" == env-var* ]]; then
  err "CLAUDE_CODE_OAUTH_TOKEN is set but onboarding env vars are missing."
  cat >&2 <<'MSG'

The OAuth token path requires all of:

  CLAUDE_ACCOUNT_UUID       (your Claude account UUID)
  CLAUDE_EMAIL              (the email on your Claude account)
  CLAUDE_ORGANIZATION_UUID  (your Claude organization UUID)

Optional:
  CLAUDE_ONBOARDING_VERSION (defaults to 2.1.29)

Set them in your Dokploy env and redeploy.

MSG
  exit 1
else
  log "onboarding env vars not set; leaving $ONBOARDING_JSON untouched"
fi

# ---------------------------------------------------------------------------
# 6. Launch the Remote Control server
# ---------------------------------------------------------------------------
log "starting: claude remote-control server --spawn-worktree-sessions ${SPAWN_WORKTREE_SESSIONS:-5}"
exec claude remote-control server \
  --spawn-worktree-sessions "${SPAWN_WORKTREE_SESSIONS:-5}"
