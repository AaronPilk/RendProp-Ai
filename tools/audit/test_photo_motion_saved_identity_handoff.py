#!/usr/bin/env python3
"""Exercise the recovered Photo motion -> aerial SQL handoff in owned Postgres.

The cluster uses a private Unix socket and is stopped even when a migration fails.
No configured Supabase database or inherited PostgreSQL connection is used.
"""

import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS = ROOT / "services/supabase/migrations"
AERIAL = "20261022223138_aerial_opening_photo_motion_composition_20261022.sql"
HISTORY = "20261022223142_photo_motion_preserve_exact_producer_history_20261022.sql"
PREDECESSOR_MD5 = "28867ce20c2e3d208c78083f4a232376"
HISTORY_MD5 = "c29019ad250ba607244137d0e2140719"
ADMISSION_MD5 = "208841bb1ad938ce350f523db1287e3b"
PUBLICATION_MD5 = "56b0bd247ea9461c5a71ce5a3cab46cf"


def run(argv, env, *, ok=True):
    result = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True, text=True, timeout=300)
    if (result.returncode == 0) != ok:
        raise AssertionError(f"{Path(argv[0]).name} exited {result.returncode}: {result.stderr[-3000:]}")
    return result


def psql(env, sql, *, database="rendprop", ok=True):
    return run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-d", database, "-c", sql], env, ok=ok)


def apply(env, path, *, database="rendprop", ok=True):
    return run(["psql", "-X", "-q", "-1", "-v", "ON_ERROR_STOP=1", "-d", database, "-f", str(path)], env, ok=ok)


def assert_handoff(env, body_md5, *, renamed):
    name = ("property_video_photo_motion_saved_identity_before_opening_20261022"
            if renamed else "property_video_photo_motion_saved_identity")
    psql(env, f"""
do $verify$begin
 if not exists(select 1 from pg_proc
   where oid=to_regprocedure('public.{name}(text,jsonb)')
     and md5(prosrc)='{body_md5}' and prosecdef and provolatile='s'
     and proconfig=ARRAY['search_path=""']::text[]
     and pg_get_userbyid(proowner)='postgres' and proacl::text='{{postgres=X/postgres}}')
 then raise exception 'Photo motion predecessor body or private authority changed';end if;
 if public.{name}('unsupported','{{}}'::jsonb)
    or public.{name}('photo-motion-v2-cfr24','{{}}'::jsonb)
 then raise exception 'Photo motion predecessor accepted an unsaved identity';end if;
end$verify$;
""")


def main():
    # Explicit Unix socket, no TCP listener, and no inherited connection setting.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("PG") and not key.startswith("SUPABASE") and key != "DATABASE_URL"}
    with tempfile.TemporaryDirectory(prefix="rp-pm-handoff-", dir="/tmp") as owned:
        location = Path(owned)
        data, socket = location / "data", location / "socket"
        socket.mkdir()
        env.update(PGHOST=str(socket), PGPORT="5432", PGUSER="postgres", PGDATABASE="rendprop")
        run(["initdb", "-D", str(data), "-U", "postgres", "-A", "trust", "--no-instructions"], env)
        started = False
        try:
            try:
                run(["pg_ctl", "-D", str(data), "-l", str(location / "postgres.log"), "-o",
                     f"-c listen_addresses= -k {socket} -p 5432", "-w", "start"], env)
            except AssertionError as error:
                raise AssertionError(f"{error}\n{(location / 'postgres.log').read_text()[-3000:]}") from error
            started = True
            run(["createdb", "-h", str(socket), "-U", "postgres", "rendprop"], env)
            apply(env, ROOT / "services/supabase/tests/ci-bootstrap.sql")
            paths = sorted(MIGRATIONS.glob("*.sql"), key=lambda path: path.name)
            for path in paths:
                if path.name == AERIAL:
                    psql(env, f"""
do $verify$begin
 if (select md5(prosrc) from pg_proc where oid=to_regprocedure('public.property_video_job_admit_photo_motion(uuid,jsonb)')) is distinct from '{ADMISSION_MD5}'
 or (select md5(prosrc) from pg_proc where oid=to_regprocedure('public.property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb)')) is distinct from '{PUBLICATION_MD5}'
 then raise exception 'Recovered Photo motion predecessor bodies changed';end if;
end$verify$;
""")
                    assert_handoff(env, PREDECESSOR_MD5, renamed=False)
                    # Every recovered predecessor must still fail closed if changed.
                    for index, (signature, replacement) in enumerate((
                        ("public.property_video_photo_motion_saved_identity(text,jsonb)",
                         "create or replace function public.property_video_photo_motion_saved_identity(p_profile text,p_identity jsonb) returns boolean language plpgsql stable security definer set search_path='' as $$begin return true;end$$"),
                        ("public.property_video_job_admit_photo_motion(uuid,jsonb)",
                         "create or replace function public.property_video_job_admit_photo_motion(p_actor uuid,p_manifest jsonb) returns jsonb language plpgsql security definer set search_path='' as $$begin return '{}'::jsonb;end$$"),
                        ("public.property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb)",
                         "create or replace function public.property_video_photo_motion_publication(p_actor uuid,p_listing uuid,p_asset uuid,p_poster uuid,p_manifest jsonb) returns boolean language plpgsql stable security definer set search_path='' as $$begin return true;end$$"),
                    )):
                        database = f"tampered_{index}"
                        run(["createdb", "-h", str(socket), "-U", "postgres", "--template=rendprop", database], env)
                        psql(env, replacement, database=database)
                        rejected = apply(env, path, database=database, ok=False)
                        if f"Aerial composition predecessor changed: {signature}" not in rejected.stderr:
                            raise AssertionError(f"Aerial guard did not identify {signature}: {rejected.stderr[-1500:]}")
                apply(env, path)
                if path.name == AERIAL:
                    assert_handoff(env, PREDECESSOR_MD5, renamed=True)
                if path.name == HISTORY:
                    assert_handoff(env, HISTORY_MD5, renamed=True)
                    break
            else:
                raise AssertionError("Photo motion historical handoff migrations were not found")
        finally:
            if started:
                run(["pg_ctl", "-D", str(data), "-m", "immediate", "-w", "stop"], env)
    print("PASS: fresh Photo motion/aerial handoff, historical identity and changed-predecessor refusal")


if __name__ == "__main__":
    main()
