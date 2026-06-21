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

# The Cyrus agent + Claude Code, installed globally. cyrus-ai is pinned for
# reproducible, intentional upgrades (the Cyrus team ships frequently); bump it
# deliberately. 0.2.66 is the first release that refreshes a repo's base clone
# before each worktree, so edits to cyrus-setup.sh are picked up without a manual
# base-clone reset (see README).
RUN npm install -g cyrus-ai@0.2.66 @anthropic-ai/claude-code

# Unprivileged user that runs the agent. All persistent state lives under its
# home, which is where the Fly volume is mounted.
RUN useradd --create-home --uid 1000 --shell /bin/bash cyrus

# GitHub App auth helpers. We authenticate as a GitHub App (not a PAT) so PRs the
# agent opens carry the App's "[bot]" identity. Apps have no long-lived token, so
# these mint installation tokens on demand from the App private key (the
# GH_APP_* secrets):
#   - gh-app-token          mints an installation token (or derives the bot ident)
#   - git-credential-gh-app git credential helper that serves a fresh token
#   - gh                    wrapper that injects a fresh token into the real gh
# /usr/local/bin precedes /usr/bin on PATH, so the `gh` wrapper shadows the
# apt-installed gh at /usr/bin/gh. See bin/ for details.
COPY bin/ /usr/local/bin/
RUN chmod 0755 /usr/local/bin/gh-app-token /usr/local/bin/git-credential-gh-app /usr/local/bin/gh

# Bake the git credential helper into the image. /home/cyrus is NOT on the Fly
# volume (only /home/cyrus/.cyrus is), so a runtime `gh auth setup-git` would not
# survive a restart. Configuring it here makes git auth work on every boot via the
# App credential helper (which mints a token per operation).
RUN su cyrus -c "git config --global credential.'https://github.com'.helper 'gh-app'"

# Fallback git committer identity for the cyrus user. The entrypoint derives the
# real identity (the App's "[bot]" account) from the GitHub App at boot and
# overrides this; this baked value only applies if that derivation fails (e.g.
# missing GH_APP_* secrets), so commits still get *some* stable identity rather
# than a guessed user@host (AP-894). Base clones must NOT carry a local
# user.name/user.email — local scope would override both (see README).
RUN su cyrus -c "git config --global user.name 'savvycal-agent[bot]'" \
    && su cyrus -c "git config --global user.email '295432075+savvycal-agent[bot]@users.noreply.github.com'"

# Make Anthropic's official `code-review` plugin available to every Claude
# session on this host. The Cyrus agent launches `claude` with
# `--setting-sources=user,project,local`, so a user-scope install is picked up
# globally via `enabledPlugins` in the cyrus user's settings. We bake it here
# (into /home/cyrus/.claude, which is the image layer — the Fly volume only
# covers ~/.cyrus) so it survives restarts and needs no per-repo setup. Both
# commands are non-interactive and only clone a public GitHub repo (no auth
# token needed at build time). Provides the `/code-review:code-review` skill.
RUN su cyrus -c "claude plugin marketplace add anthropics/claude-plugins-official \
    && claude plugin install code-review@claude-plugins-official --scope user"

# Auto-approve agent-invoked code-review so the fully-headless agent can run it
# without a permission prompt (with no human to approve, the prompt would be
# denied). The agent is launched with `--permission-mode default`; a
# `permissions.allow` rule in user settings short-circuits to approval BEFORE the
# harness's stdio deny-handler runs, and merges with (does not replace) the
# harness's own `--allowedTools`. jq edits the cyrus-owned settings.json written
# above (run as root, then restore ownership).
#
# We allow BOTH the bare `code-review` and the namespaced `code-review:code-review`
# matchers (each with a ` *` variant covering invocations that pass arguments).
# This matters: when asked naturally ("run a code review"), the model invokes the
# skill by its bare alias `Skill(code-review)`, not the namespaced form — so a
# namespaced-only rule misses it, the headless prompt denies it, and the agent
# silently falls back to reviewing by hand (observed on a real issue).
RUN jq '.permissions.allow = ((.permissions.allow // []) + ["Skill(code-review)", "Skill(code-review *)", "Skill(code-review:code-review)", "Skill(code-review:code-review *)"] | unique)' \
      /home/cyrus/.claude/settings.json > /home/cyrus/.claude/settings.json.tmp \
    && mv /home/cyrus/.claude/settings.json.tmp /home/cyrus/.claude/settings.json \
    && chown cyrus:cyrus /home/cyrus/.claude/settings.json

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
