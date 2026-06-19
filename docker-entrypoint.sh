#!/usr/bin/env bash
# Entrypoint for the Cyrus host. Starts a local Postgres whose data dir lives on
# the persistent volume, then drops privileges and execs the Cyrus agent in the
# foreground (Fly restarts the machine if it exits).
set -euo pipefail

CYRUS_HOME=/home/cyrus
STATE_DIR="${CYRUS_HOME}/.cyrus"          # Fly volume mount point
export PGDATA="${STATE_DIR}/pgdata"

# The volume mounts as root-owned on first boot; hand it to the cyrus user.
mkdir -p "${STATE_DIR}"
chown -R cyrus:cyrus "${STATE_DIR}"

# Initialize the cluster once. The bootstrap superuser is `postgres`, and we set
# its password to `postgres` to match what app dev configs expect.
if [ ! -s "${PGDATA}/PG_VERSION" ]; then
  echo "==> Initializing PostgreSQL cluster at ${PGDATA}"
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
exec gosu cyrus bash -lc 'exec cyrus'
