#!/usr/bin/env bash
# Runs the migrations and SQL tests against a throwaway local Postgres. No Docker or Supabase needed.
# Usage: supabase/tests/run.sh        (set PG_BIN if Postgres binaries are elsewhere)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
PG_BIN="${PG_BIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
PORT="${PGPORT_TEST:-54329}"

work="$(mktemp -d)"
as_pg=()
if [ "$(id -u)" = 0 ]; then
  chown postgres "$work"
  as_pg=(runuser -u postgres --)
fi

cleanup() {
  "${as_pg[@]}" "$PG_BIN/pg_ctl" -D "$work/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

"${as_pg[@]}" "$PG_BIN/initdb" -D "$work/data" -A trust --no-locale -E UTF8 >/dev/null
"${as_pg[@]}" "$PG_BIN/pg_ctl" -D "$work/data" -w -l "$work/log" \
  -o "-p $PORT -k $work -c listen_addresses=''" start >/dev/null

psql_run() { psql -h "$work" -p "$PORT" -U postgres -X -q -o /dev/null -v ON_ERROR_STOP=1 -d postgres "$@"; }

psql_run -f "$here/00_supabase_stub.sql"
for f in "$root"/migrations/*.sql; do
  echo "migrate $(basename "$f")"
  psql_run -f "$f"
done
psql_run -f "$here/01_helpers.sql"
# All test files share one session so they can build on each other's data.
args=()
for f in "$here"/test_*.sql; do args+=(-f "$f"); done
psql_run "${args[@]}" 2>&1 | sed -e 's/^psql:[^ ]* NOTICE:  //' -e 's/^NOTICE:  //'

echo "ALL TESTS PASSED"
