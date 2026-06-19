# Thin host image for self-hosting the Cyrus agent (see README.md).
#
# It bakes ONLY host-level prerequisites: the Cyrus CLI + Claude Code, git/gh/jq,
# a local Postgres, and `mise` plus the build deps needed to compile per-repo
# runtimes. It deliberately does NOT bake any app's Elixir/OTP/Node versions —
# those are installed per-repo via `mise install` and cached on the Fly volume.

FROM debian:bookworm-slim

ARG NODE_MAJOR=24

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# Base OS packages: build deps for compiling Erlang/OTP via mise, plus the
# Cyrus prerequisites (git, jq) and runtime utilities. ImageMagick is included
# because at least one onboarded app needs it.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg git unzip xz-utils procps locales \
      build-essential autoconf m4 libssl-dev libncurses-dev \
      libwxgtk3.2-dev libgl1-mesa-dev libglu1-mesa-dev libpng-dev \
      jq imagemagick \
      postgresql postgresql-contrib gosu \
    && sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

# Node (for running the cyrus-ai CLI itself) via NodeSource.
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI via the official apt repo.
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# The Cyrus agent + Claude Code, installed globally.
RUN npm install -g cyrus-ai @anthropic-ai/claude-code

# Unprivileged user that runs the agent. All persistent state lives under its
# home, which is where the Fly volume is mounted.
RUN useradd --create-home --uid 1000 --shell /bin/bash cyrus

# Bake the git credential helper into the image. /home/cyrus is NOT on the Fly
# volume (only /home/cyrus/.cyrus is), so a runtime `gh auth setup-git` would not
# survive a restart. Configuring it here makes git auth work on every boot,
# driven by the GH_TOKEN secret via `gh auth git-credential`.
RUN su cyrus -c "git config --global credential.'https://github.com'.helper '!gh auth git-credential'" \
    && su cyrus -c "git config --global credential.'https://gist.github.com'.helper '!gh auth git-credential'"

# mise installs per-repo runtimes from each repo's .tool-versions. Install it
# system-wide so the cyrus user picks it up via the activation in .bashrc.
ENV MISE_INSTALL_PATH=/usr/local/bin/mise
RUN curl -fsSL https://mise.run | sh \
    && echo 'eval "$(/usr/local/bin/mise activate bash)"' >> /home/cyrus/.bashrc \
    && chown cyrus:cyrus /home/cyrus/.bashrc

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Entrypoint runs as root (to start Postgres / fix volume perms) then drops to
# the cyrus user to exec the agent.
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
