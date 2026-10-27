#!/usr/bin/env python3
"""Prove credit purchase, refund, downgrade and hold invariants in local PostgreSQL."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from tools.audit.run_database_regression import partition_fresh_migrations

SQL = ROOT / "services/supabase"
TOOLS = {name: shutil.which(name) or str(Path("/opt/homebrew/opt/postgresql@17/bin") / name)
         for name in ("initdb", "pg_ctl", "createdb", "psql")}
ENV = {"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LC_ALL": "C",
       "PGOPTIONS": "-c statement_timeout=60000 -c lock_timeout=15000"}


def run(label, args):
    result = subprocess.run([str(x) for x in args], cwd=ROOT, env=ENV,
                            text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=240)
    if result.returncode:
        raise AssertionError(f"{label} failed:\n{result.stdout[-6000:]}")
    return result.stdout


with tempfile.TemporaryDirectory(prefix="rendprop-credit-pg-", dir=str(ROOT.parent)) as data, \
     tempfile.TemporaryDirectory(prefix="rc-", dir="/tmp") as socket:
    # The database cluster is disposable and never uses the hosted Supabase DB.
    run("initdb", [TOOLS["initdb"], "-D", data, "-U", "postgres", "-A", "trust",
                   "--no-locale", "--encoding=UTF8"])
    started = False
    try:
        run("start", [TOOLS["pg_ctl"], "-D", data, "-l", Path(data) / "postgres.log",
                      "-w", "-o", f"-k {socket} -p 55986 -c listen_addresses='' -c shared_buffers=16MB",
                      "start"])
        started = True
        connection = ["-h", socket, "-p", "55986", "-U", "postgres"]
        run("createdb", [TOOLS["createdb"], *connection, "credit_wallet_test"])
        psql = [TOOLS["psql"], "-X", "--no-password", *connection,
                "-d", "credit_wallet_test", "-v", "ON_ERROR_STOP=1"]
        run("bootstrap", [*psql, "-q", "-f", SQL / "tests/ci-bootstrap.sql"])
        migrations, _ = partition_fresh_migrations(sorted((SQL / "migrations").glob("*.sql")))
        for migration in migrations:
            run("migration " + migration.name, [*psql, "-q", "-1", "-f", migration])
        output = run("wallet fixture", [*psql, "-Atq", "-f", SQL / "tests/credit_wallet.sql"])
        results = [json.loads(line) for line in output.splitlines()
                   if line.startswith("{") and '"assertions"' in line]
        assert len(results) == 1 and results[0]["passed"] is True, output
        photo_output = run("photo credit fixture", [*psql, "-Atq", "-f", SQL / "tests/credit_photo_spend.sql"])
        photo_results = [json.loads(line) for line in photo_output.splitlines()
                         if line.startswith("{") and '"assertions"' in line]
        assert len(photo_results) == 1 and photo_results[0]["passed"] is True, photo_output
        trial_output = run("trial activation readiness fixture", [*psql, "-Atq", "-f", SQL / "tests/trial_activation_readiness.sql"])
        trial_results = [json.loads(line) for line in trial_output.splitlines()
                         if line.startswith("{") and '"assertions"' in line]
        assert len(trial_results) == 1 and trial_results[0]["passed"] is True, trial_output
        combined_output = run("combined credit budget fixture", [*psql, "-Atq", "-f", SQL / "tests/credit_combined_budget.sql"])
        combined_results = [json.loads(line) for line in combined_output.splitlines()
                            if line.startswith("{") and '"assertions"' in line]
        assert len(combined_results) == 1 and combined_results[0]["passed"] is True, combined_output
        motion_output = run("dormant Photo Motion credit quote fixture",
                            [*psql, "-Atq", "-f", SQL / "tests/credit_photo_motion_quote_gate.sql"])
        motion_results = [json.loads(line) for line in motion_output.splitlines()
                          if line.startswith("{") and '"assertions"' in line]
        assert len(motion_results) == 1 and motion_results[0]["passed"] is True, motion_output
        motion_admit_output = run("prospective Photo Motion credit admission fixture",
                                  [*psql, "-Atq", "-f", SQL / "tests/credit_photo_motion_admission.sql"])
        motion_admit_results = [json.loads(line) for line in motion_admit_output.splitlines()
                                if line.startswith("{") and '"assertions"' in line]
        assert len(motion_admit_results) == 1 and motion_admit_results[0]["passed"] is True, motion_admit_output
        sandbox_output = run("signed Sandbox intro fixture", [*psql, "-Atq", "-f", SQL / "tests/sandbox_intro_trial.sql"])
        sandbox_results = [json.loads(line) for line in sandbox_output.splitlines()
                          if line.startswith("{") and '"assertions"' in line]
        assert len(sandbox_results) == 1 and sandbox_results[0]["passed"] is True, sandbox_output
        stage_output = run("stage credit fixture", [*psql, "-Atq", "-f", SQL / "tests/credit_photo_stage.sql"])
        stage_results = [json.loads(line) for line in stage_output.splitlines()
                         if line.startswith("{") and '"assertions"' in line]
        assert len(stage_results) == 1 and stage_results[0]["passed"] is True, stage_output
        recovery_output = run("photo credit recovery fixture", [*psql, "-Atq", "-f", SQL / "tests/credit_hold_recovery.sql"])
        recovery_results = [json.loads(line) for line in recovery_output.splitlines()
                            if line.startswith("{") and '"assertions"' in line]
        assert len(recovery_results) == 1 and recovery_results[0]["passed"] is True, recovery_output
        team_output = run("Team paid seat variant fixture", [*psql, "-Atq", "-f", SQL / "tests/team_paid_seat_variants.sql"])
        team_results = [json.loads(line) for line in team_output.splitlines()
                         if line.startswith("{") and '"assertions"' in line]
        assert len(team_results) == 1 and team_results[0]["passed"] is True, team_output
        # Race a signed Team5 -> Team3 snapshot against issuance of its last
        # available invite. Both wait behind the same org row lock. Whichever
        # wins, no newcomer can accept after the reduced paid term is current.
        run("Team downgrade race seed", [*psql, "-Atq", "-f", SQL / "tests/team_downgrade_race_seed.sql"])
        race_org = "5aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        locker = subprocess.Popen([*psql, "-Atq"], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  text=True, env=ENV, cwd=ROOT)
        try:
            locker.stdin.write(f"begin; select id from public.orgs where id='{race_org}' for update;\n\\echo LOCKED\n")
            locker.stdin.flush()
            assert locker.stdout.readline().strip() == race_org
            assert locker.stdout.readline().strip() == "LOCKED"
            def call_race(sql):
                return subprocess.run([*psql, "-Atq", "-c", sql], cwd=ROOT, env=ENV,
                                      text=True, stdout=subprocess.PIPE,
                                      stderr=subprocess.STDOUT, timeout=30)
            downgrade_sql = f"""begin;
              update public.orgs set apple_product_id='com.rendprop.app.team.monthly'
                where id='{race_org}';
              update public.apple_subscriptions set product_id='com.rendprop.app.team.monthly',
                last_transaction_id='race-team-three',transaction_purchased_at=now(),
                transaction_signed_at=now() where original_transaction_id='race-team-chain';
              commit;"""
            invite_sql = f"""begin;set role service_role;
              select public.create_org_invite('51111111-1111-4111-8111-111111111111',
                '{race_org}','race-new@example.invalid','agent',repeat('f',64));
              commit;"""
            with ThreadPoolExecutor(max_workers=2) as workers:
                pending = [workers.submit(call_race, sql) for sql in (downgrade_sql, invite_sql)]
                deadline = time.monotonic() + 8
                while True:
                    waiting = run("Team downgrade lock overlap", [*psql, "-Atq", "-c",
                      "select count(*) from pg_stat_activity where datname='credit_wallet_test' "
                      "and wait_event_type='Lock' and pid<>pg_backend_pid()"])
                    if int(waiting.strip()) >= 2: break
                    assert time.monotonic() < deadline, "Both Team seat mutations must overlap behind the org lock"
                    time.sleep(.03)
                locker.stdin.write("commit;\n"); locker.stdin.flush()
                locker.stdin.close(); locker.wait(timeout=10)
                downgrade, invitation = [future.result() for future in pending]
            assert downgrade.returncode == 0, downgrade.stdout
            if invitation.returncode != 0:
                assert "RP402:" in invitation.stdout, invitation.stdout
            status = run("Team downgrade race result", [*psql, "-Atq", "-c", f"""
              select public.org_seats_allowed('{race_org}')=3;
              select count(*)=4 from public.memberships where org_id='{race_org}';
              select count(*)=1 from public.team_seat_status('{race_org}') where not seat_active;
              select count(*)<=1 from public.org_invites where org_id='{race_org}'
                and accepted_at is null and revoked_at is null;
            """])
            assert [line.strip() for line in status.splitlines() if line.strip()] == ["t"] * 4, status
            if invitation.returncode == 0:
                accepted = call_race("set role service_role;select public.accept_org_invite("
                  "'51111111-1111-4111-8111-111111111115',repeat('f',64));")
                assert accepted.returncode != 0 and "RP402:" in accepted.stdout, accepted.stdout
        finally:
            if locker.poll() is None: locker.kill(); locker.wait()
        aerial_output = run("dormant aerial credit fixture", [*psql, "-Atq", "-f", SQL / "tests/credit_aerial_opening.sql"])
        aerial_results = [json.loads(line) for line in aerial_output.splitlines()
                          if line.startswith("{") and '"assertions"' in line]
        assert len(aerial_results) == 1 and aerial_results[0]["passed"] is True, aerial_output
        # Two real database sessions race the same operation key. The durable
        # aerial advisory fence must return one job and one wallet allocation.
        concurrent_op = "a0777777-7777-4777-8777-777777777777"
        seed = json.loads(run("read synthetic aerial seed", [*psql, "-Atq", "-c",
            "select jsonb_build_object('manifest',manifest,'quote',quote,'consent',consent) "
            "from public.property_video_aerial_openings "
            "where operation_id='a0444444-4444-4444-8444-444444444444';"]).strip())
        def json_sql(value):
            return "'" + json.dumps(value, separators=(",", ":")).replace("'", "''") + "'::jsonb"
        race_sql = f"""begin; set role service_role; select pg_sleep(0.1);
          with source as (
            select jsonb_set({json_sql(seed['manifest'])},'{{operation_id}}',
              to_jsonb('{concurrent_op}'::uuid)) as new_manifest
          )
          select (public.property_video_aerial_admit_credit(
            'a0111111-1111-4111-8111-111111111111',new_manifest,
            jsonb_set({json_sql(seed['quote'])},'{{manifest_sha256}}',
              to_jsonb(encode(sha256(convert_to(new_manifest::text,'UTF8')),'hex'))),
            {json_sql(seed['consent'])},'Production','aerial-opening-v1')).id from source;
          commit;"""
        with ThreadPoolExecutor(max_workers=2) as workers:
            raced = list(workers.map(lambda _: run("concurrent aerial admit", [*psql, "-Atq", "-c", race_sql]), range(2)))
        ids = [[line for line in output.splitlines() if line.strip().count("-") == 4][-1].strip()
               for output in raced]
        assert ids[0] == ids[1], f"Concurrent aerial job identities differ: {ids}"
        race_check = run("concurrent aerial wallet check", [*psql, "-Atq", "-c", f"""
          select count(*)=1 and min(state)='reserved' from public.credit_holds
            where request_key='aerial-opening:{concurrent_op}';
          select count(*)=1 from public.property_video_aerial_openings where operation_id='{concurrent_op}';
          set role service_role;
          select (public.credit_wallet_state('a0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Production')->>'total_available')::integer=80;
        """])
        assert [line.strip() for line in race_check.splitlines() if line.strip()] == ["t", "t", "t"], race_check
        downgrade_output = run("paid-to-Free aerial credit recovery", [*psql, "-Atq", "-f", SQL / "tests/credit_aerial_downgrade.sql"])
        downgrade_results = [json.loads(line) for line in downgrade_output.splitlines()
                             if line.startswith("{") and '"assertions"' in line]
        assert len(downgrade_results) == 1 and downgrade_results[0]["passed"] is True, downgrade_output
        uncertain_output = run("cancel and late KIE acceptance", [*psql, "-Atq", "-f", SQL / "tests/credit_aerial_uncertain.sql"])
        uncertain_results = [json.loads(line) for line in uncertain_output.splitlines()
                             if line.startswith("{") and '"assertions"' in line]
        assert len(uncertain_results) == 1 and uncertain_results[0]["passed"] is True, uncertain_output
        fair_output = run("aerial fair-charge negative controls", [*psql, "-Atq", "-f", SQL / "tests/credit_aerial_fair_charge.sql"])
        fair_results = [json.loads(line) for line in fair_output.splitlines()
                        if line.startswith("{") and '"assertions"' in line]
        assert len(fair_results) == 1 and fair_results[0]["passed"] is True, fair_output
        print(json.dumps({"passed": True,
                          "assertions": results[0]["assertions"] + photo_results[0]["assertions"]
                          + trial_results[0]["assertions"] + combined_results[0]["assertions"]
                          + sandbox_results[0]["assertions"] + stage_results[0]["assertions"]
                          + recovery_results[0]["assertions"]
                          + aerial_results[0]["assertions"]
                          + team_results[0]["assertions"] + downgrade_results[0]["assertions"]
                          + uncertain_results[0]["assertions"]
                          + fair_results[0]["assertions"]
                          + motion_results[0]["assertions"]
                          + motion_admit_results[0]["assertions"],
                          "migrations": len(migrations), "scope": "disposable PostgreSQL"}))
    finally:
        if started:
            run("stop", [TOOLS["pg_ctl"], "-D", data, "-m", "immediate", "-w", "stop"])
