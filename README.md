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
