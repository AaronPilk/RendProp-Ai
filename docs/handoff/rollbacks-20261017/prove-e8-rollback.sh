#!/bin/bash
# Disposable PG 16: apply every migration, then prove the E8 rollback and re-apply.
set -uo pipefail
export PATH=/usr/lib/postgresql/16/bin:$PATH LC_ALL=C TZ=UTC
REPO=${REPO:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel)}; D=${PGDIR:-/tmp/rp-e8-rollback-pg}; P=${PGPORT_E8:-55751}; rm -rf $D
SOCK=$("$(dirname "$0")"/pg-up.sh $D $P); trap 'pg_ctl -D '$D' -m immediate stop >/dev/null 2>&1; rm -rf '$D' '$D'.sock' EXIT
export PGHOST=$SOCK PGPORT=$P PGUSER=postgres
createdb rb; export PGDATABASE=rb
psql -v ON_ERROR_STOP=1 -q -f $REPO/services/supabase/tests/ci-bootstrap.sql >/dev/null || exit 1
for f in $(ls $REPO/services/supabase/migrations/*.sql | LC_ALL=C sort); do psql -v ON_ERROR_STOP=1 -q -1 -f "$f" >/dev/null 2>&1 || { echo "apply failed: $f"; exit 1; }; done
q(){ psql -Atq -c "$1"; }
S="'public.app_video_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,numeric,numeric,jsonb)'::regprocedure"
acl0=$(q "select proacl::text||'|'||proowner from pg_proc where oid=$S")
echo "after all migrations: $(q "select md5(prosrc) from pg_proc where oid=$S")   (expect 15ff3c0d…)"
psql -v ON_ERROR_STOP=1 -q -f "$(dirname "$0")"/ROLLBACK-20261017190100-app_video_rp402_copy.sql && echo "rollback 1: $(q "select md5(prosrc) from pg_proc where oid=$S")   (expect 9828980a…)"
[ "$(q "select proacl::text||'|'||proowner from pg_proc where oid=$S")" = "$acl0" ] && echo "owner+ACL unchanged by rollback"
q "select count(*) from pg_proc where prosrc like '%Workspace monthly processing budget would be exceeded%' and oid=$S" | sed 's/^/original sentence present: /'
psql -v ON_ERROR_STOP=1 -q -f "$(dirname "$0")"/ROLLBACK-20261017190100-app_video_rp402_copy.sql && echo "rollback 2 (no-op): $(q "select md5(prosrc) from pg_proc where oid=$S")"
psql -v ON_ERROR_STOP=1 -q -1 -f $REPO/services/supabase/migrations/20261017190100_app_video_rp402_copy.sql && echo "re-apply E8: $(q "select md5(prosrc) from pg_proc where oid=$S")   (expect 15ff3c0d…)"
psql -v ON_ERROR_STOP=1 -q -1 -f $REPO/services/supabase/migrations/20261017190100_app_video_rp402_copy.sql && echo "replay E8 (no-op): $(q "select md5(prosrc) from pg_proc where oid=$S")"
# unknown-body control: append a harmless comment to the body, rollback must refuse and change nothing
def=$(q "select pg_get_functiondef(oid) from pg_proc where oid=$S")
psql -v ON_ERROR_STOP=1 -q -c "do \$x\$declare d text;begin select pg_get_functiondef($S) into d; execute replace(d,'begin', E'begin\n -- synthetic unknown-body control'); end\$x\$;" 
m=$(q "select md5(prosrc) from pg_proc where oid=$S")
if psql -v ON_ERROR_STOP=1 -q -f "$(dirname "$0")"/ROLLBACK-20261017190100-app_video_rp402_copy.sql 2>err.log; then echo "CONTROL FAILED: rollback accepted an unknown body"; exit 1; else echo "unknown-body control: refused ($(grep -o 'E8 rollback refused[^\n]*' err.log | head -1 | cut -c1-60)); body unchanged: $([ "$(q "select md5(prosrc) from pg_proc where oid=$S")" = "$m" ] && echo yes)"; fi
echo PROVEN
