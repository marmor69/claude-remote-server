FROM node:20-slim

# Install essential tools (util-linux is added for runuser)
RUN apt-get update && apt-get install -y \
    git \
    curl \
    jq \
    python3 \
    util-linux \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# Create the dedicated user and workspace directory
RUN useradd -m -s /bin/bash claude
RUN mkdir -p /home/claude/workspace

WORKDIR /home/claude/workspace

# Start as root to chown the mounted volume, then securely step down to the claude user
ENTRYPOINT ["/bin/bash", "-c", "chown -R claude:claude /home/claude/workspace && exec runuser -u claude -- claude remote-control server --spawn-worktree-sessions 5"]
