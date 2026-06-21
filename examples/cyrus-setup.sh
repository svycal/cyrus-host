#!/bin/bash
#
# Cyrus repository setup script — SELF-HOSTED host variant.
#
# This is the real cyrus-setup.sh from our `appointments-app` repo, included here
# as a worked example. Each repo Cyrus serves keeps its own copy at the repo root.
#
# Runs automatically when Cyrus creates a new Git worktree for a Linear issue,
# preparing the environment before the issue is processed. Must be
# non-interactive and finish within Cyrus's 5-minute timeout.
#
# This targets our self-hosted Cyrus host (svycal/cyrus-host), which runs as the
# unprivileged `cyrus` user (no sudo). The host image already provides:
#
#   * Erlang/Node build deps + `mise`  -> we only install this repo's runtimes,
#     and the mise cache persists on the host volume (one-time compile per repo).
#   * A running PostgreSQL with postgres/postgres on localhost  -> we just assert
#     reachability instead of starting the cluster and configuring auth.
#
# See: https://www.atcyrus.com/docs/setup-scripts
set -euo pipefail

# --- Logging -----------------------------------------------------------------
#
# Tee all output (stdout + stderr) to a log file in the worktree so a failed run
# is easy to inspect after the fact, while still streaming to the console for
# Cyrus's own run logs. The file is gitignored (see .gitignore) so it never gets
# swept into the agent's changes. Appended (not truncated) so a re-run keeps the
# previous attempt's log.
SETUP_LOG="cyrus-setup.log"
exec > >(tee -a "$SETUP_LOG") 2>&1
echo "===== cyrus-setup.sh started $(date -u +%Y-%m-%dT%H:%M:%SZ) ====="

# --- Toolchain (per-repo runtimes via mise) ----------------------------------
#
# mise and the Erlang/Node build deps are baked into the host image; here we only
# materialize this repo's pinned runtimes from .tool-versions. The first run on a
# given repo compiles Erlang/OTP, but the mise cache lives on the host volume, so
# subsequent worktrees reuse it and stay well under the timeout.
echo "Installing language runtimes from .tool-versions..."
mise install --yes

MIX=(mise exec -- mix)
NPM=(mise exec -- npm)

if ! "${MIX[@]}" --version >/dev/null 2>&1; then
  echo "Error: mix/Elixir is unavailable after mise install." >&2
  exit 1
fi

if ! "${NPM[@]}" --version >/dev/null 2>&1; then
  echo "Error: npm/node is unavailable after mise install." >&2
  exit 1
fi

# --- Dev secrets -------------------------------------------------------------
#
# config/dev.exs does `import_config "dev.secret.exs"`, which is gitignored and
# therefore absent in a fresh worktree. import_config raises on a missing file,
# so every dev-env mix command would fail to load config. Seed it from the
# committed example (idempotent; never overwrite an existing file).
if [ ! -f config/dev.secret.exs ] && [ -f config/dev.secret.exs.example ]; then
  cp config/dev.secret.exs.example config/dev.secret.exs
  echo "Seeded config/dev.secret.exs from the example."
fi

# --- Per-worktree database name ----------------------------------------------
#
# The host runs multiple worktrees against one shared PostgreSQL. Write a
# worktree-scoped .env.local with distinct DEV_DB_NAME/TEST_DB_NAME so concurrent
# worktrees don't collide. config/runtime.exs loads .env.local via Dotenvy; the
# defaults (nova_dev/nova_test) apply when LINEAR_ISSUE_IDENTIFIER is absent.
if [ -n "${LINEAR_ISSUE_IDENTIFIER:-}" ]; then
  slug=$(printf '%s' "$LINEAR_ISSUE_IDENTIFIER" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/_/g; s/^_+|_+$//g')
  if [ -n "$slug" ]; then
    cat > .env.local <<EOF
DEV_DB_NAME=nova_dev_${slug}
TEST_DB_NAME=nova_test_${slug}
EOF
    echo "Wrote .env.local with per-worktree database suffix: ${slug}"
  fi
fi

# --- Database (reachability) -------------------------------------------------
#
# PostgreSQL is provided by the host image (cluster running, postgres/postgres on
# localhost over scram). We don't provision it here — we just assert it's
# reachable over TCP (the path the app uses) and fail loudly if not, before
# spending time on dependencies. The per-worktree database itself is created by
# mix ecto.setup below.
if ! PGPASSWORD=postgres psql -h localhost -U postgres -d postgres -tc 'select 1' >/dev/null 2>&1; then
  echo "Error: cannot reach PostgreSQL as postgres/postgres at localhost:5432." >&2
  echo "       The self-hosted host image is expected to provide it." >&2
  exit 1
fi

# --- Application dependencies ------------------------------------------------

"${MIX[@]}" local.hex --force
"${MIX[@]}" local.rebar --force

# Authenticate the private ezsuite Hex repo required by some dependencies.
if [ -n "${EZSUITE_AUTH_KEY:-}" ]; then
  "${MIX[@]}" hex.repo add ezsuite https://ezsuite.dev/repo \
    --fetch-public-key SHA256:5WqcbEXE2PRHFpPrlJeaCCS1mAokfq6Bf/rdKzukVQ4 \
    --auth-key "$EZSUITE_AUTH_KEY"
else
  echo "Warning: EZSUITE_AUTH_KEY is not set; private dependency fetches may fail." >&2
fi

# --- Dependency cache --------------------------------------------------------
#
# Cyrus runs setup in a fresh worktree per issue, but $HOME is shared across
# worktrees on the host, so mise runtimes, ~/.hex and ~/.npm are already reused.
# The per-worktree deps/, _build/ and assets/node_modules are not — we cache them
# here, keyed by lockfile + pinned runtime versions.
#
# We COPY (not symlink) into the worktree so each keeps a private, mutable copy:
# Cyrus may run several worktrees at once, and the agent recompiles / adds deps.
# Cache entries are immutable per content hash and published atomically. Targets
# GNU coreutils (sha256sum, cp -a, mv -T), matching the Debian host image.
CACHE_ROOT="${CYRUS_CACHE_DIR:-$HOME/.cyrus/cache}/appointments-app"

hash_of() { { cat "$@" 2>/dev/null || true; } | sha256sum | cut -c1-16; }
ELIXIR_KEY="elixir-$(hash_of mix.lock .tool-versions)"
NODE_KEY="node-$(hash_of assets/package-lock.json)"

cache_restore() { # <entry> <dest>: stage to a temp dir, then swap in; 1 on miss
  local src="$CACHE_ROOT/$1" tmp="$2.cyrus-tmp.$$"
  [ -d "$src" ] || return 1
  # Copy into a sibling temp first so an interrupted/failed copy (5-minute
  # timeout, ENOSPC) never leaves a partial deps/_build in place — the original
  # stays untouched until the atomic swap.
  rm -rf "$tmp"
  if cp -a "$src" "$tmp"; then
    rm -rf "$2"
    mv -T "$tmp" "$2"
  else
    rm -rf "$tmp"
    return 1
  fi
}

cache_save() { # <entry> <src>: publish once, atomically; no-op if present
  [ -d "$2" ] || return 0
  [ -d "$CACHE_ROOT/$1" ] && return 0
  mkdir -p "$CACHE_ROOT"
  local tmp="$CACHE_ROOT/.tmp-$1-$$"
  rm -rf "$tmp"
  cp -a "$2" "$tmp" && mv -T "$tmp" "$CACHE_ROOT/$1" 2>/dev/null || rm -rf "$tmp"
  return 0
}

# Restore compiled deps/_build as a warm start. mix recompiles whatever the
# branch changed (freshly checked-out sources always out-date cached artifacts,
# so this never under-compiles).
cache_restore "deps-$ELIXIR_KEY" deps || true
cache_restore "build-$ELIXIR_KEY" _build || true

"${MIX[@]}" deps.get
"${MIX[@]}" esbuild.install --if-missing
"${MIX[@]}" compile

# Frontend deps: a cache hit is already a clean install for this lockfile, so
# skip the destructive `npm ci` on a hit.
if cache_restore "$NODE_KEY" assets/node_modules; then
  echo "Using cached assets/node_modules ($NODE_KEY)"
else
  "${NPM[@]}" --prefix assets ci --prefer-offline
  cache_save "$NODE_KEY" assets/node_modules || true
fi

# Frontend assets aren't needed for backend work, so a build failure here must
# not abort setup. Warn instead of exiting.
"${MIX[@]}" assets.build \
  || echo "Warning: assets.build failed; frontend assets may be stale." >&2

# Publish the Elixir caches for the next worktree (no-op if already present).
cache_save "deps-$ELIXIR_KEY" deps || true
cache_save "build-$ELIXIR_KEY" _build || true

# --- Database schema ---------------------------------------------------------
#
# Create and migrate the per-worktree database. ecto.setup runs here because it
# needs the compiled deps.
"${MIX[@]}" ecto.setup

echo "cyrus-setup.sh: setup complete."
