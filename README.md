# Claude Code Remote Control Server for Dokploy

A minimal Docker image for running Claude Code as a headless remote-control server on a VPS, with support for persistent workspaces and spawned sessions.

This project is intended for self-hosted use with platforms like Dokploy. It is designed for people who want an always-on Claude Code workspace without keeping an SSH session open.

## Features

- Runs Claude Code in a containerized, headless setup.
- Works well with Dokploy and other Docker-based deployment platforms.
- Supports a persistent workspace volume.
- Fixes permissions automatically for a blank mounted volume.
- Starts a remote-control server that can spawn multiple worktree sessions.

## What this image does

The container starts as root only long enough to fix ownership of the mounted workspace directory. It then drops privileges and runs Claude Code as a non-root user for safer day-to-day use.

By default, the server starts with support for up to 5 spawned worktree sessions. You can change that in the Dockerfile or override the startup command in your deployment platform.

## Dockerfile

```dockerfile
FROM node:20-slim

RUN apt-get update && apt-get install -y \
    git \
    curl \
    jq \
    python3 \
    util-linux \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

RUN useradd -m -s /bin/bash claude
RUN mkdir -p /home/claude/workspace

WORKDIR /home/claude/workspace

ENTRYPOINT ["/bin/bash", "-c", "chown -R claude:claude /home/claude/workspace && exec runuser -u claude -- claude remote-control server --spawn-worktree-sessions 5"]
```

## Requirements

- A VPS or other Linux host that can run Docker containers.
- A deployment platform such as Dokploy, or plain Docker / Docker Compose.
- A valid Claude / Anthropic account with access to Claude Code.
- A persistent volume mounted to `/home/claude/workspace`.

## Dokploy setup

Create a new Docker-based application in Dokploy and use this repository as the source.

Then configure a persistent volume:

- Volume type: Docker volume
- Mount path: `/home/claude/workspace`

This is important because the workspace contains your files and should survive restarts or redeployments.

## Docker Compose

Dokploy can deploy Docker Compose applications, so this repository can also be used directly in that workflow [web:50]. The restart policy shown below is a practical default for long-running services because it brings the container back after crashes or host reboots while still respecting a manual stop [web:59].

```yaml
services:
  claude-remote:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: claude-remote
    restart: unless-stopped
    init: true
    stdin_open: true
    tty: true
    environment:
      TZ: Europe/Berlin
    volumes:
      - claude-workspace-data:/home/claude/workspace
    healthcheck:
      test: ["CMD-SHELL", "pgrep -af 'claude remote-control server' >/dev/null || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

volumes:
  claude-workspace-data:
    name: claude-workspace-data
```

### Compose notes

- `init: true` helps with cleaner process handling inside the container.
- `stdin_open` and `tty` are optional, but they can make interactive debugging easier.
- The named volume keeps your workspace persistent across restarts and redeployments.
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
      dockerfile: Dockerfile
    container_name: claude-remote
    restart: unless-stopped
    init: true
    stdin_open: true
    tty: true
    environment:
      TZ: Europe/Berlin
      SETUP_MODE: "true"
      SPAWN_WORKTREE_SESSIONS: "5"
    volumes:
      - claude-workspace-data:/home/claude/workspace
      - claude-config-data:/home/claude/.claude
    healthcheck:
      test: ["CMD-SHELL", "[ \"$SETUP_MODE\" = \"true\" ] || pgrep -af 'claude remote-control server' >/dev/null"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

volumes:
  claude-workspace-data:
    name: claude-workspace-data
  claude-config-data:
    name: claude-config-data
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
