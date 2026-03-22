FROM node:20-slim

RUN apt-get update && apt-get install -y \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    openssh-server \
    procps \
    python3 \
    sudo \
    util-linux \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

RUN useradd -m -s /bin/bash claude \
    && mkdir -p /home/claude/workspace /home/claude/.claude /home/claude/.ssh /var/run/sshd \
    && chmod 700 /home/claude/.ssh \
    && touch /home/claude/.ssh/authorized_keys \
    && chmod 600 /home/claude/.ssh/authorized_keys \
    && chown -R claude:claude /home/claude

RUN echo 'claude ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/claude \
    && chmod 440 /etc/sudoers.d/claude

RUN sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's@#AuthorizedKeysFile.*@AuthorizedKeysFile .ssh/authorized_keys@' /etc/ssh/sshd_config \
    && echo 'PermitRootLogin no' >> /etc/ssh/sshd_config \
    && echo 'AllowUsers claude' >> /etc/ssh/sshd_config

RUN cat <<'EOF' > /usr/local/bin/docker-entrypoint.sh
#!/bin/bash
set -euo pipefail

sudo mkdir -p /home/claude/workspace /home/claude/.claude /home/claude/.ssh /var/run/sshd
sudo touch /home/claude/.ssh/authorized_keys
sudo chmod 700 /home/claude/.ssh
sudo chmod 600 /home/claude/.ssh/authorized_keys
sudo chown -R claude:claude /home/claude/workspace /home/claude/.claude /home/claude/.ssh

sudo /usr/sbin/sshd || true

cd /home/claude/workspace

if [[ "${SETUP_MODE:-false}" == "true" ]]; then
  echo
  echo "SETUP_MODE=true"
  echo "Default container user: $(whoami)"
  echo "Home directory: $HOME"
  echo
  echo "Open the Dokploy terminal and run:"
  echo "  whoami"
  echo "  echo $HOME"
  echo "  claude"
  echo
  echo "Then inside Claude Code run:"
  echo "  /login"
  echo "  /status"
  echo
  echo "After successful login, set SETUP_MODE=false and redeploy."
  echo
  exec sleep infinity
fi

unset ANTHROPIC_API_KEY || true
unset ANTHROPIC_AUTH_TOKEN || true

exec claude remote-control server --spawn-worktree-sessions "${SPAWN_WORKTREE_SESSIONS:-5}"
EOF

RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER claude
WORKDIR /home/claude/workspace
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
