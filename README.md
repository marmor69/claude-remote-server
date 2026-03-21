# Claude Code Remote Control Server for Dokploy

A minimal Docker setup for running Claude Code as a headless remote-control server on a VPS with persistent storage, first-run login support, and spawned worktree sessions.

This project is intended for self-hosted use with Dokploy or any Docker Compose-compatible platform.

## Features

- Headless Claude Code workspace for VPS hosting
- First-run setup mode for interactive login
- Persistent workspace volume
- Persistent Claude config volume
- Automatic permission fix for blank mounted volumes
- Remote Control server mode with spawned worktree sessions
- Non-root runtime for normal operation

## Why this setup exists

Claude Code Remote Control requires a claude.ai login and does not work with API-key authentication. A fresh headless container usually needs one interactive login before it can run as a background remote-control server.

This repo solves that by providing two modes:

- `SETUP_MODE=true` for the initial login
- `SETUP_MODE=false` for normal always-on server operation

## Files

### `Dockerfile`

Builds a small Debian-based image with Claude Code installed globally and a custom entrypoint.

### `docker-compose.yml`

Defines the service, persistent volumes, restart policy, and setup/server environment variables.

## Environment variables

This project is designed so you do not need to edit `docker-compose.yml` for normal configuration changes.

The Compose file reads values from a `.env` file and also passes that file into the container with `env_file`. This works well with Dokploy because Dokploy manages deployment variables through its Environment UI and writes them to a `.env` file for the Compose app.

### Example `.env`

```env
CONTAINER_NAME=claude-remote
DOCKERFILE_PATH=Dockerfile

TZ=Europe/Berlin
SETUP_MODE=true
SPAWN_WORKTREE_SESSIONS=5

WORKSPACE_VOLUME_NAME=claude-workspace-data
CONFIG_VOLUME_NAME=claude-config-data

HEALTHCHECK_INTERVAL=30s
HEALTHCHECK_TIMEOUT=10s
HEALTHCHECK_RETRIES=5
HEALTHCHECK_START_PERIOD=30s
```

## Volumes

This setup uses two persistent Docker volumes:

- `claude-workspace-data` mounted at `/home/claude/workspace`, stores your project files
- `claude-config-data` mounted at `/home/claude/.claude`, stores Claude login and local config

Both should be persistent in Dokploy.

## First-time login

Start with setup mode enabled:

```yaml
environment:
  SETUP_MODE: "true"
```

Deploy the container. It will stay running and print instructions instead of trying to start Remote Control immediately.

Then open the container terminal in Dokploy and run:

```bash
claude
```

Inside Claude Code, complete:

```text
/login
/status
```

What to check:

- `/login` should authenticate with your claude.ai account
- `/status` should show that you are using claude.ai authentication, not API-key auth
- If prompted, accept workspace trust for `/home/claude/workspace`

After login succeeds:

1. Edit your deployment config
2. Change `SETUP_MODE` to `"false"`
3. Redeploy the container

At that point, the container should start the Remote Control server automatically.

## Normal operation

With setup complete, use:

```yaml
environment:
  SETUP_MODE: "false"
  SPAWN_WORKTREE_SESSIONS: "5"
```

The container will start:

```bash
claude remote-control server --spawn-worktree-sessions 5
```

You can adjust the spawned session limit by changing `SPAWN_WORKTREE_SESSIONS`.

## Example `docker-compose.yml`

```yaml
services:
  claude-remote:
    build:
      context: .
      dockerfile: ${DOCKERFILE_PATH:-Dockerfile}
    container_name: ${CONTAINER_NAME:-claude-remote}
    restart: unless-stopped
    init: true
    stdin_open: true
    tty: true
    env_file:
      - .env
    environment:
      TZ: ${TZ:-Europe/Berlin}
      SETUP_MODE: ${SETUP_MODE:-true}
      SPAWN_WORKTREE_SESSIONS: ${SPAWN_WORKTREE_SESSIONS:-5}
    volumes:
      - ${WORKSPACE_VOLUME_NAME:-claude-workspace-data}:/home/claude/workspace
      - ${CONFIG_VOLUME_NAME:-claude-config-data}:/home/claude/.claude
    healthcheck:
      test: ["CMD-SHELL", "[ "$SETUP_MODE" = "true" ] || pgrep -af 'claude remote-control server' >/dev/null"]
      interval: ${HEALTHCHECK_INTERVAL:-30s}
      timeout: ${HEALTHCHECK_TIMEOUT:-10s}
      retries: ${HEALTHCHECK_RETRIES:-5}
      start_period: ${HEALTHCHECK_START_PERIOD:-30s}

volumes:
  ${WORKSPACE_VOLUME_NAME:-claude-workspace-data}:
    name: ${WORKSPACE_VOLUME_NAME:-claude-workspace-data}
  ${CONFIG_VOLUME_NAME:-claude-config-data}:
    name: ${CONFIG_VOLUME_NAME:-claude-config-data}
```

## Dokploy notes

For Dokploy, create a Docker Compose application and point it at this repository.

Important points:

- Keep both named volumes persistent
- Use setup mode for the first deployment
- Complete login from the Dokploy terminal, not from the log viewer
- After login, switch setup mode off and redeploy

## Troubleshooting

### "You must be logged in to use Remote Control"

The container is trying to start the server before claude.ai login exists.

Fix:

1. Set `SETUP_MODE=true`
2. Redeploy
3. Open Dokploy terminal
4. Run `claude`
5. Run `/login`
6. Run `/status`
7. Set `SETUP_MODE=false`
8. Redeploy

### Remote Control still does not work

Check these:

- You are logged in with a claude.ai subscription
- You are not forcing API-key auth with `ANTHROPIC_API_KEY`
- You are not forcing Bedrock, Vertex, or Foundry auth
- Your plan supports Remote Control
- Your organization has enabled Remote Control if you are on Team or Enterprise

## Security notes

This image is designed for self-hosting. Review the Dockerfile before deployment and only mount paths you trust.

The container runs as root only long enough to fix mounted-volume ownership, then drops to the non-root `claude` user for normal operation.

## Disclaimer

This project is an independent community setup and is not affiliated with, endorsed by, or maintained by Anthropic.

Claude Code, Claude, and related product names belong to their respective owners.

## License

MIT
