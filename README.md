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
- The health check gives your deployment platform a simple way to detect whether the remote-control server process is still running.

## First startup

On first boot, open the container logs in Dokploy. Claude Code should print an authentication URL that you can open in your browser to connect the server to your account.

Once authenticated, the server should appear as an available environment in Claude Remote Control.

## Persistence and permissions

If you mount a completely blank volume, Docker usually creates it as root-owned. This image handles that automatically during startup so Claude Code can write to the workspace without manual permission fixes.

## Customization

You may want to customize the image for your own workflow. Common changes include:

- Installing extra Python packages.
- Adding build tools or editors.
- Changing the number of spawned sessions.
- Mounting additional project directories.
- Replacing the base image with a fuller Debian or Ubuntu-style environment.

## Security notes

This image is meant for personal or team self-hosting. Review the Dockerfile before deployment and only run it in environments you trust.

You should avoid mounting sensitive host paths unless you fully understand the implications.

## Disclaimer

This project is an independent community container setup and is not affiliated with, endorsed by, or maintained by Anthropic.

Claude Code, Claude, and related product names belong to their respective owners.

## License

MIT
