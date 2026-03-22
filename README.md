# Claude Code Remote Control Server for Dokploy

A Docker-based setup for running Claude Code as a headless remote-control server on a VPS with persistent storage, optional SSH access, and support for spawned worktree sessions.

This project is intended for self-hosted use with Dokploy or any Docker Compose-compatible platform.

## Features

- Headless Claude Code workspace for VPS hosting
- OAuth-token-based setup for easier headless deployment
- Fallback interactive `/login` flow if you prefer manual login
- Persistent workspace volume
- Persistent Claude config volume
- Optional SSH access into the container
- Remote Control server mode with spawned worktree sessions
- Runs Claude Code as the `claude` user

## Why this setup exists

Claude Code Remote Control requires Claude subscription authentication. In a headless container, the standard browser-based login flow can be awkward.

This setup supports two ways to authenticate:

1. Recommended: create an OAuth token on another machine and pass it through `CLAUDE_CODE_OAUTH_TOKEN`
2. Fallback: start in setup mode and run `claude`, then `/login`, inside the container terminal

## Files

### `Dockerfile`

Builds a Debian-based image with Claude Code installed globally, optional SSH support, and an entrypoint that starts the Remote Control server.

### `docker-compose.yml`

Defines the container, ports, persistent volumes, and environment-variable-driven configuration.

### `.env.example`

Provides the variables you can manage in Dokploy without editing the Compose file.

## Volumes

This setup uses two persistent Docker volumes:

- `claude-workspace-data` mounted at `/home/claude/workspace`, stores your project files
- `claude-config-data` mounted at `/home/claude/.claude`, stores Claude login data and local config

Both should be persistent in Dokploy.

## Recommended setup: OAuth token

The easiest headless flow is to generate an OAuth token on another machine that already has browser access.

On that machine, run:

```bash
claude setup-token
```

Then copy the generated token into Dokploy as the environment variable:

```env
CLAUDE_CODE_OAUTH_TOKEN=your-token-here
```

After that, deploy with:

```env
SETUP_MODE=false
```

This allows the container to start directly in server mode without needing interactive login during first boot.

## Fallback setup: interactive login

If you do not want to use an OAuth token, you can still log in interactively.

Set:

```env
SETUP_MODE=true
```

Deploy the container, then open the Dokploy terminal and run:

```bash
whoami
echo $HOME
claude
```

Inside Claude Code, complete:

```text
/login
/status
```

What to check:

- `whoami` should be `claude`
- `echo $HOME` should be `/home/claude`
- `/status` should show Claude subscription authentication, not API-key auth

After login succeeds:

1. Change `SETUP_MODE` to `false`
2. Redeploy the container

## Environment variables

This project is designed so you do not need to edit `docker-compose.yml` for normal configuration changes.

Use Dokploy's environment UI or a `.env` file to manage values such as:

```env
CONTAINER_NAME=claude-remote
DOCKERFILE_PATH=Dockerfile

TZ=Europe/Berlin
SETUP_MODE=false
SPAWN_WORKTREE_SESSIONS=5

SSH_HOST_PORT=2222
CLAUDE_CODE_OAUTH_TOKEN=

HEALTHCHECK_INTERVAL=30s
HEALTHCHECK_TIMEOUT=10s
HEALTHCHECK_RETRIES=5
HEALTHCHECK_START_PERIOD=30s
```

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
      SETUP_MODE: ${SETUP_MODE:-false}
      SPAWN_WORKTREE_SESSIONS: ${SPAWN_WORKTREE_SESSIONS:-5}
      CLAUDE_CODE_OAUTH_TOKEN: ${CLAUDE_CODE_OAUTH_TOKEN:-}
    ports:
      - "${SSH_HOST_PORT:-2222}:22"
    volumes:
      - claude-workspace-data:/home/claude/workspace
      - claude-config-data:/home/claude/.claude
    healthcheck:
      test:
        - CMD-SHELL
        - >
          pgrep -af "claude remote-control server" >/dev/null || exit 1
      interval: ${HEALTHCHECK_INTERVAL:-30s}
      timeout: ${HEALTHCHECK_TIMEOUT:-10s}
      retries: ${HEALTHCHECK_RETRIES:-5}
      start_period: ${HEALTHCHECK_START_PERIOD:-30s}

volumes:
  claude-workspace-data:
    name: claude-workspace-data
  claude-config-data:
    name: claude-config-data
```

## SSH access

If SSH is enabled in the image and you publish port 22 through Compose, you can connect to the container with an SSH client.

Example:

```bash
ssh -p 2222 claude@ssh.domain.com
```

For Dokploy, the practical approach is to point an `A` record like `ssh.domain.com` to your VPS IP and connect to the published TCP port.

## Dokploy notes

For Dokploy, create a Docker Compose application and point it at this repository.

Important points:

- Keep both named volumes persistent
- Prefer `CLAUDE_CODE_OAUTH_TOKEN` for headless setup
- Use `SETUP_MODE=true` only when doing manual login
- Complete fallback login from the Dokploy terminal, not from the log viewer
- After manual login, switch setup mode off and redeploy

## Troubleshooting

### Login does not persist after redeploy

Check these:

- `/home/claude/.claude` is mounted to a persistent named volume
- The volume names are explicitly set in Compose with `name:`
- You are logging in as user `claude`, not `root`
- You are not accidentally recreating or renaming the project volumes

### "You must be logged in to use Remote Control"

Possible causes:

- No `CLAUDE_CODE_OAUTH_TOKEN` was provided
- Interactive login was not completed
- Login was saved under the wrong user home directory
- API-key auth is taking precedence over subscription auth

### API-key auth interferes with Remote Control

Do not set these unless you intentionally want non-subscription auth:

- `ANTHROPIC_API_KEY`
- `ANTHROPIC_AUTH_TOKEN`

If those are present, remove them and redeploy.

## Security notes

This image is designed for self-hosting. Review the Dockerfile before deployment and only mount paths you trust.

Treat `CLAUDE_CODE_OAUTH_TOKEN` as a secret. Store it in Dokploy environment variables, not in a committed `.env` file.

## Disclaimer

This project is an independent community setup and is not affiliated with, endorsed by, or maintained by Anthropic.

Claude Code, Claude, and related product names belong to their respective owners.

## License

MIT
