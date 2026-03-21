FROM node:20-slim

RUN apt-get update && apt-get install -y \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    procps \
    python3 \
    util-linux \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

RUN useradd -m -s /bin/bash claude \
    && mkdir -p /home/claude/workspace /home/claude/.claude

RUN cat <<'EOF' > /usr/local/bin/docker-entrypoint.sh
#!/bin/bash
set -euo pipefail

mkdir -p /home/claude/workspace /home/claude/.claude
chown -R claude:claude /home/claude/workspace /home/claude/.claude

if [[ "${SETUP_MODE:-false}" == "true" ]]; then
  echo
  echo "SETUP_MODE=true"
  echo "Open a terminal in this container and run:"
  echo "  claude"
  echo
  echo "Then complete:"
  echo "  /login"
  echo "  /status"
  echo
  echo "After successful login, set SETUP_MODE=false and redeploy."
  echo
  exec tail -f /dev/null
fi

unset ANTHROPIC_API_KEY || true
unset ANTHROPIC_AUTH_TOKEN || true

exec runuser -u claude -- bash -lc \
  "cd /home/claude/workspace && exec claude remote-control server --spawn-worktree-sessions ${SPAWN_WORKTREE_SESSIONS:-5}"
EOF

RUN chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /home/claude/workspace

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
