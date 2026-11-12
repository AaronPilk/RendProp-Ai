#!/bin/bash
# Disposable PG cluster for migration proofs. Usage: pg-up.sh <datadir> <port>
set -euo pipefail
export PATH=/usr/lib/postgresql/16/bin:$PATH LC_ALL=C TZ=UTC
DATA="$1"; PORT="$2"; SOCK="$DATA.sock"
mkdir -p "$SOCK"
initdb -D "$DATA" -U postgres -A trust --no-locale --encoding=UTF8 >"$DATA.initdb.log" 2>&1
pg_ctl -D "$DATA" -l "$DATA.postgres.log" -w -o "-k $SOCK -p $PORT -c listen_addresses='' -c shared_buffers=16MB" start >"$DATA.start.log" 2>&1
echo "$SOCK"
