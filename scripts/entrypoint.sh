#!/usr/bin/env bash
#
# docker-entrypoint.sh — boot sequence for claude-remote-server.
#
# Remote Control requires subscription auth obtained via the interactive
# `/login` flow. Long-lived OAuth tokens (CLAUDE_CODE_OAUTH_TOKEN) are
# NOT supported by `claude remote-control`, so the only auth path
# is:
#
#   1. Deploy with SETUP_MODE=true.
#   2. Open a container terminal and run `claude` / `/login` / `/status`.
#   3. Set SETUP_MODE=false and redeploy.
#
# Everything `claude` writes lives under $HOME, and $HOME itself is a
# named volume (claude-home-data), so credentials, ~/.claude.json,
# dotfiles, and ~/.ssh/authorized_keys all persist across redeploys
# automatically — no env-var copying, no symlink dance.
#
# Phases:
#   1. Fix ownership of mounted volumes (a fresh Docker volume can come
#      up root-owned, which breaks the non-root `claude` user).
#   2. Strip env vars that would override or break subscription auth.
#   3. Optionally start sshd when ENABLE_SSH=true.
#   4. If SETUP_MODE=true, print login instructions and sleep forever.
#   5. Verify persisted credentials exist on the home volume.
#   6. Pre-accept the one-time Remote Control consent dialog so the server
#      starts headless (no stdin available in a container).
#   7. Delete stale bridge environments left over from previous runs that
#      were force-killed before graceful shutdown could deregister them.
#   8. Exec `claude remote-control`.

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
# claude-home-data mounts on top of /home/claude and claude-workspace-data
# nests at /home/claude/workspace. Either can come up root-owned on first
# boot or after recreate; chown the whole tree every boot to be safe.
sudo mkdir -p "$WORKSPACE_DIR" "$CONFIG_DIR" "$SSH_DIR" /var/run/sshd
sudo touch "$SSH_DIR/authorized_keys"
sudo chmod 700 "$SSH_DIR"
sudo chmod 600 "$SSH_DIR/authorized_keys"
sudo chown -R claude:claude "$CLAUDE_HOME"

# ---------------------------------------------------------------------------
# 2. Strip conflicting auth env vars
# ---------------------------------------------------------------------------
# Claude Code Remote Control requires subscription auth. If an API key
# leaks in via Dokploy env it will silently take precedence and the
# server will reject every request.
if [[ -n "${ANTHROPIC_API_KEY:-}" || -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
  log "unsetting ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN (subscription auth only)"
fi
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN || true

# Long-lived OAuth tokens are not supported for `claude remote-control
# server`. Warn loudly if one leaks in, then clear it so it can't
# confuse the subscription-auth flow.
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

 When /status looks good:
   1. Set SETUP_MODE=false
   2. Redeploy

 The home volume keeps your login + ~/.claude.json across
 redeploys, so you only have to do this once.
============================================================
MSG
  exec sleep infinity
fi

# ---------------------------------------------------------------------------
# 5. Verify persisted credentials
# ---------------------------------------------------------------------------
# `/login` stores short-lived subscription credentials inside $CONFIG_DIR
# (which is on the home volume). If they're missing, the user hasn't
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
  3. Set SETUP_MODE=false and redeploy.

MSG
  exit 1
fi

log "persisted credentials: found in $CONFIG_DIR"

# ---------------------------------------------------------------------------
# 6. Skip the interactive "Enable Remote Control?" consent prompt
# ---------------------------------------------------------------------------
# `claude remote-control` shows a one-time y/n consent dialog the first time
# it runs on a machine. In a headless container there's no one to answer it,
# so the process blocks on stdin and the healthcheck eventually kills us.
#
# The prompt is gated on `remoteDialogSeen` in ~/.claude.json — once that key
# is true, the prompt is skipped and the server launches directly. Pre-set
# it here so the very first boot runs headless too. Idempotent: if the key
# is already set (e.g. user already ran /login + /remote-control manually),
# this is a no-op rewrite with the same value.
CLAUDE_JSON="${CLAUDE_HOME}/.claude.json"
if [[ -f "$CLAUDE_JSON" ]]; then
  if ! jq -e '.remoteDialogSeen == true' "$CLAUDE_JSON" >/dev/null 2>&1; then
    log "setting remoteDialogSeen=true in ~/.claude.json (skips consent prompt)"
    tmp="$(mktemp)"
    jq '. + {remoteDialogSeen: true}' "$CLAUDE_JSON" > "$tmp" && mv "$tmp" "$CLAUDE_JSON"
  fi
else
  log "creating ~/.claude.json with remoteDialogSeen=true (skips consent prompt)"
  printf '{"remoteDialogSeen": true}\n' > "$CLAUDE_JSON"
fi

# ---------------------------------------------------------------------------
# 7. Clean up stale bridge environments from previous runs
# ---------------------------------------------------------------------------
# `claude remote-control` registers a fresh environment every time it
# starts. On graceful SIGTERM it calls DELETE /v1/environments/bridge/<id>
# and the entry disappears from claude.ai/code. But if the container was
# force-killed (docker stop --time too short, SIGKILL, OOM, crash) the
# environment is left dangling and shows up as a stale session forever.
#
# There is no CLI flag to "resume" or reuse an environment ID, so the
# cleanest approach is to list all bridge environments tied to this
# machine name (the container hostname) and delete them ourselves right
# before launching a fresh one. Best-effort: swallow every error, because
# a failure here must not block startup.
cleanup_stale_bridge_environments() {
  local token org machine response ids id count=0
  token="$(jq -r '.claudeAiOauth.accessToken // empty' "$CONFIG_DIR/.credentials.json" 2>/dev/null || true)"
  org="$(jq -r '.oauthAccount.organizationUuid // empty' "$CLAUDE_JSON" 2>/dev/null || true)"
  machine="$(hostname)"

  if [[ -z "$token" || -z "$org" ]]; then
    log "cleanup: skipping (no access token or org UUID available)"
    return 0
  fi

  # List all environments. The ListEnvironments endpoint is paginated but
  # 100 is plenty for one machine's history of bridge sessions.
  response="$(curl -sS --max-time 10 \
    -H "Authorization: Bearer $token" \
    -H "x-organization-uuid: $org" \
    -H "anthropic-beta: ccr-byoc-2025-07-29" \
    "https://api.anthropic.com/v1/environments?limit=100" 2>/dev/null || true)"

  if [[ -z "$response" ]]; then
    log "cleanup: skipping (environments list request failed)"
    return 0
  fi

  # Match kind=bridge AND machine_name=current hostname. Tolerate field
  # name variations in case the API shape shifts slightly.
  ids="$(printf '%s' "$response" | jq -r --arg name "$machine" '
    (.data // .environments // [])[]?
    | select((.kind // "") == "bridge")
    | select((.machine_name // .name // "") == $name)
    | (.environment_id // .id // empty)
  ' 2>/dev/null || true)"

  for id in $ids; do
    if curl -sS --max-time 10 -o /dev/null -X DELETE \
        -H "Authorization: Bearer $token" \
        -H "x-organization-uuid: $org" \
        -H "anthropic-beta: ccr-byoc-2025-07-29" \
        "https://api.anthropic.com/v1/environments/bridge/$id" 2>/dev/null; then
      count=$((count + 1))
    fi
  done

  if [[ $count -gt 0 ]]; then
    log "cleanup: deleted $count stale bridge environment(s) for machine '$machine'"
  else
    log "cleanup: no stale bridge environments found for machine '$machine'"
  fi
}

cleanup_stale_bridge_environments || true

# ---------------------------------------------------------------------------
# 8. Launch the Remote Control server
# ---------------------------------------------------------------------------
# Build the argv from env vars. Defaults to worktree spawn mode because
# that's the point of this project (spawn on-demand sessions per
# worktree). Worktree mode requires $WORKSPACE_DIR to be a git repo —
# clone or `git init` one in there during SETUP_MODE.
args=(remote-control --spawn "${SPAWN_MODE:-worktree}")

if [[ -n "${CAPACITY:-}" ]]; then
  args+=(--capacity "$CAPACITY")
fi

if [[ -n "${SESSION_NAME:-}" ]]; then
  args+=(--name "$SESSION_NAME")
fi

if [[ "${VERBOSE:-false}" == "true" ]]; then
  args+=(--verbose)
fi

# Sandboxing is off by default in claude-code; only pass the flag when
# the user explicitly opts in.
if [[ "${SANDBOX:-false}" == "true" ]]; then
  args+=(--sandbox)
fi

log "starting: claude ${args[*]}"
exec claude "${args[@]}"
