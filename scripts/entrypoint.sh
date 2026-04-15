#!/usr/bin/env bash
#
# docker-entrypoint.sh — boot sequence for claude-remote-server.
#
# Remote Control requires subscription auth obtained via the interactive
# `/login` flow. Long-lived OAuth tokens (CLAUDE_CODE_OAUTH_TOKEN) are
# NOT supported by `claude remote-control server`, so the only auth path
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
# 6. Launch the Remote Control server
# ---------------------------------------------------------------------------
log "starting: claude remote-control server --spawn-worktree-sessions ${SPAWN_WORKTREE_SESSIONS:-5}"
exec claude remote-control server \
  --spawn-worktree-sessions "${SPAWN_WORKTREE_SESSIONS:-5}"
