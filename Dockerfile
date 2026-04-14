FROM node:20-slim

# System packages: git/curl/jq for developer ergonomics inside sessions,
# openssh-server for optional SSH (gated at runtime by ENABLE_SSH),
# sudo so the non-root `claude` user can fix volume ownership in the
# entrypoint.
RUN apt-get update && apt-get install -y --no-install-recommends \
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

# Claude Code is installed globally from npm; that's the only app layer.
RUN npm install -g @anthropic-ai/claude-code

# Non-root user. Subscription auth / OAuth token must resolve under this
# user's $HOME, never under root.
RUN useradd -m -s /bin/bash claude \
    && mkdir -p /home/claude/workspace /home/claude/.claude /home/claude/.ssh /var/run/sshd \
    && chmod 700 /home/claude/.ssh \
    && touch /home/claude/.ssh/authorized_keys \
    && chmod 600 /home/claude/.ssh/authorized_keys \
    && chown -R claude:claude /home/claude

# The entrypoint uses `sudo chown` to repair volume ownership on first boot.
RUN echo 'claude ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/claude \
    && chmod 440 /etc/sudoers.d/claude

# sshd is installed but never started at build time — `scripts/entrypoint.sh`
# launches it at runtime only when ENABLE_SSH=true. Key-only, claude user only.
RUN sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's@#AuthorizedKeysFile.*@AuthorizedKeysFile .ssh/authorized_keys@' /etc/ssh/sshd_config \
    && echo 'PermitRootLogin no' >> /etc/ssh/sshd_config \
    && echo 'AllowUsers claude' >> /etc/ssh/sshd_config

# Real entrypoint lives in scripts/entrypoint.sh — easier to read, diff,
# and debug than an embedded heredoc.
COPY scripts/entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER claude
WORKDIR /home/claude/workspace
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
