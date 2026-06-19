#!/usr/bin/env bash
# Entrypoint for the Cyrus host. Starts a local Postgres whose data dir lives on
# the persistent volume, then drops privileges and execs the Cyrus agent in the
# foreground (Fly restarts the machine if it exits).
set -euo pipefail

CYRUS_HOME=/home/cyrus
STATE_DIR="${CYRUS_HOME}/.cyrus"          # Fly volume mount point
export PGDATA="${STATE_DIR}/pgdata"

# The volume mounts root-owned on first boot. Hand the top-level state dir to the
# cyrus user (its config, repos, worktrees, and mise cache live here), but give
# Postgres its own pgdata subdir — initdb runs as the postgres user and can't
# write into a cyrus-owned directory. Chown only these two roots (NOT -R), so an
# already-initialized pgdata keeps its postgres ownership across reboots.
mkdir -p "${STATE_DIR}"
chown cyrus:cyrus "${STATE_DIR}"

# Initialize the cluster once. The bootstrap superuser is `postgres`, and we set
# its password to `postgres` to match what app dev configs expect.
if [ ! -s "${PGDATA}/PG_VERSION" ]; then
  echo "==> Initializing PostgreSQL cluster at ${PGDATA}"
  mkdir -p "${PGDATA}"
  chown postgres:postgres "${PGDATA}"
  chmod 700 "${PGDATA}"
  PWFILE="$(mktemp)"
  echo "postgres" > "${PWFILE}"
  chown postgres:postgres "${PWFILE}"
  gosu postgres /usr/lib/postgresql/*/bin/initdb \
    --username=postgres --auth-local=trust --auth-host=scram-sha-256 \
    --pwfile="${PWFILE}" -D "${PGDATA}"
  rm -f "${PWFILE}"
  echo "listen_addresses = 'localhost'" >> "${PGDATA}/postgresql.conf"
fi

echo "==> Starting PostgreSQL"
gosu postgres /usr/lib/postgresql/*/bin/pg_ctl -D "${PGDATA}" \
  -o "-c listen_addresses=localhost -p 5432" -w start

echo "==> Starting Cyrus agent as cyrus user"
cd "${CYRUS_HOME}"
# Pin HOME so git (and anything $HOME-based) resolves to /home/cyrus, where the
# baked .gitconfig and the volume-backed .cyrus state both live.
exec gosu cyrus env HOME="${CYRUS_HOME}" bash -lc 'exec cyrus'
