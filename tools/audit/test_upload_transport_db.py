#!/usr/bin/env python3
"""Actual, owned socket-only PostgreSQL tests; no existing DB URL accepted."""
import concurrent.futures
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(tempfile.mkdtemp(prefix="rendprop-upload-pg-", dir="/tmp"))
HOMEBREW_PG = "/opt/homebrew/opt/postgresql@17/bin"

def postgres_bin():
    """One PostgreSQL distribution from the caller's PATH (PG16 in CI, PG17 on
    the Mac); the Homebrew @17 keg stays the fallback. All three binaries must
    come from the same directory so a stray psql never pairs with another
    server's initdb."""
    for candidate in [*(Path(p).parent for p in [shutil.which("initdb")] if p), Path(HOMEBREW_PG)]:
        if all((candidate / name).is_file() for name in ("initdb", "pg_ctl", "psql")):
            return candidate
    raise RuntimeError("No PostgreSQL distribution with initdb/pg_ctl/psql on PATH or at " + HOMEBREW_PG)

PG = str(postgres_bin()) + "/"
ENV = {"PATH": PG.rstrip("/") + ":/usr/bin:/bin", "LC_ALL": "C", "TZ": "UTC"}
DATA, SOCKET = OUT / "cluster", OUT / "socket"
RECEIPT = {"accepted": False, "network": "Unix socket only", "commands": [], "evidence": str(OUT), "postgres": PG}

def run(name, args, source=None, expected=0):
    result = subprocess.run(args, input=source, text=True, env=ENV, cwd=ROOT,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    (OUT / (name + ".log")).write_text(result.stdout)
    RECEIPT["commands"].append({"name": name, "exit": result.returncode})
    if result.returncode != expected:
        raise RuntimeError(f"{name}: exit {result.returncode}, expected {expected}; see {OUT}/{name}.log")
    return result.stdout.strip()

PSQL = [PG+"psql", "-X", "--no-password", "-h", str(SOCKET), "-p", "55438", "-U", "postgres",
        "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-qAt"]

def sql(source, expected=0):
    # UUID log names avoid races between concurrent connections.
    return run(str(uuid.uuid4()), PSQL, source, expected)

def call(name, *args, expected=0):
    values = ["null" if v is None else str(v).lower() if isinstance(v, bool) else
              "'" + (json.dumps(v) if isinstance(v, (dict, list)) else str(v)).replace("'", "''") + "'" for v in args]
    value = sql("set role service_role; select public."+name+"("+",".join(values)+");", expected)
    return json.loads(value) if expected == 0 and value.startswith(("{", "[")) else value

class UploadDatabase(unittest.TestCase):
    def setUp(self):
        self.user, self.listing = str(uuid.uuid4()), str(uuid.uuid4())
        self.org = sql(f"insert into auth.users(id,email) values ('{self.user}','fixture@example.invalid'); "
                       f"select org_id from memberships where user_id='{self.user}' and role='owner';")
        sql(f"insert into listings(id,org_id,agent_id,address) values ('{self.listing}','{self.org}','{self.user}','Synthetic');")

    def spec(self, idem=None, size=4):
        asset = str(uuid.uuid4())
        return {"id": asset, "listing_id": self.listing, "kind": "video", "bucket": "uploads",
                "storage_key": f"uploads/{self.org}/{self.listing}/{asset}.mov", "bytes": size,
                "content_type": "video/quicktime", "content_type_declared": True,
                "sha256": None, "part_size": None, "parts_total": None, "idem_key": idem}

    def reserve(self, spec=None):
        return call("reserve_upload_assets", self.user, [spec or self.spec()])[0]

    def operation(self, asset, kind="single"):
        return call("plan_upload_operation", asset["id"], kind, 0)

    def stored(self, asset, kind="single"):
        op = self.operation(asset, kind); claim = str(uuid.uuid4())
        call("claim_upload_operation", op["id"], claim)
        return call("finish_upload_operation", op["id"], claim, "stored", '"fixture"', None)

    def balances(self):
        return json.loads(sql(f"select json_build_array(tickets,held_bytes,spent_bytes) from upload_budget_windows where org_id='{self.org}';"))

    def test_concurrent_idempotency_reserves_once(self):
        specs = [self.spec("stable-fixture") for _ in range(8)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            rows = list(pool.map(self.reserve, specs))
        self.assertEqual(len({r["id"] for r in rows}), 1)
        self.assertEqual(sum(not r["replayed"] for r in rows), 1)
        self.assertEqual(self.balances(), [1, 8, 0])

    def test_concurrent_claim_dispatches_once(self):
        asset = self.reserve(); op = self.operation(asset)
        def claim(_):
            return sql(f"set role service_role; select claim_upload_operation('{op['id']}','{uuid.uuid4()}');", expected=0)
        # Start simultaneous claims, count real server failures without hiding them.
        commands = ["set role service_role; select claim_upload_operation('"+op["id"]+"','"+str(uuid.uuid4())+"');" for _ in range(8)]
        def direct(command):
            p = subprocess.run(PSQL, input=command, text=True, env=ENV, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
            return p.returncode, p.stdout
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(direct, commands))
        self.assertEqual(sum(code == 0 for code, _ in results), 1)
        self.assertTrue(all(code == 0 or code == 3 and "RP503" in out for code, out in results))
        self.assertEqual(self.balances(), [1, 4, 4])

    def test_cancel_is_single_settlement_after_uncertain_write(self):
        asset = self.reserve(); op = self.operation(asset); claim = str(uuid.uuid4())
        call("claim_upload_operation", op["id"], claim)
        call("finish_upload_operation", op["id"], claim, "uncertain", None, None)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            rows = list(pool.map(lambda _: call("settle_upload_reservation", asset["id"], False), range(8)))
        self.assertTrue(all(row["upload_aborted"] for row in rows))
        self.assertEqual(self.balances(), [1, 0, 4])
        self.assertIn("RP503", call("claim_upload_operation", op["id"], str(uuid.uuid4()), expected=3))

    def test_batch_failure_rolls_back_all_rows_and_budget(self):
        good, bad = self.spec(), self.spec(size=0)
        call("reserve_upload_assets", self.user, [good, bad], expected=3)
        self.assertEqual(sql(f"select count(*) from capture_assets where listing_id='{self.listing}';"), "0")
        self.assertEqual(sql(f"select count(*) from upload_budget_windows where org_id='{self.org}';"), "0")

    def test_complete_retains_winner_and_releases_no_spent_bytes(self):
        asset = self.reserve(); self.stored(asset); copy = self.stored(asset, "copy")
        winner = call("settle_upload_reservation", asset["id"], True, copy["id"])
        self.assertEqual(winner["storage_key"], copy["object_key"])
        self.assertEqual(self.balances(), [1, 0, 8])
        self.assertTrue(call("settle_upload_reservation", asset["id"], True, copy["id"])["uploaded"])
        self.assertIn("RP409", call("settle_upload_reservation", asset["id"], False, expected=3))
        self.assertIn("RP409", call("claim_upload_cleanup", copy["id"], str(uuid.uuid4()), expected=3))

    def test_cancel_fences_late_copy_receipt(self):
        asset = self.reserve(); self.stored(asset); op = self.operation(asset, "copy"); claim = str(uuid.uuid4())
        call("claim_upload_operation", op["id"], claim)
        call("settle_upload_reservation", asset["id"], False)
        call("finish_upload_operation", op["id"], claim, "stored", '"fixture"', None)
        self.assertIn("RP409", call("settle_upload_reservation", asset["id"], True, op["id"], expected=3))
        self.assertEqual(self.balances(), [1, 0, 8])

    def test_cleanup_failure_stays_journaled_then_success_stops_retry(self):
        asset = self.reserve(); op = self.stored(asset); call("settle_upload_reservation", asset["id"], False)
        for success in [False, True]:
            sql(f"update upload_operations set cleanup_after=now()-interval '1 second' where id='{op['id']}';")
            claim = str(uuid.uuid4()); call("claim_upload_cleanup", op["id"], claim)
            call("finish_upload_cleanup", op["id"], claim, success)
        self.assertEqual(sql(f"select state||':'||cleanup_attempts||':'||(cleanup_after is null) from upload_operations where id='{op['id']}';"), "deleted:2:true")
        self.assertEqual(self.balances(), [1, 0, 4])

    def test_role_revocation_prevents_new_dispatch(self):
        asset = self.reserve(); op = self.operation(asset)
        sql(f"update memberships set role='marketing' where user_id='{self.user}';")
        self.assertIn("RP403", call("claim_upload_operation", op["id"], str(uuid.uuid4()), expected=3))
        self.assertEqual(self.balances(), [1, 8, 0])

    def test_anon_and_authenticated_have_no_authority(self):
        for role in ["anon", "authenticated"]:
            self.assertIn("permission denied", sql(f"set role {role}; select * from upload_reservations;", expected=3))
            self.assertIn("permission denied", sql(f"set role {role}; select reserve_upload_assets('{self.user}','[]');", expected=3))

    def test_competing_reservations_cannot_exceed_physical_cap(self):
        sql(f"insert into upload_budget_windows(org_id,day,spent_bytes) values('{self.org}',current_date,214748364788);")
        def reserve(spec):
            source=f"set role service_role; select reserve_upload_assets('{self.user}','{json.dumps([spec])}');"
            p=subprocess.run(PSQL,input=source,text=True,env=ENV,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=10)
            return p.returncode,p.stdout
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(reserve,[self.spec(),self.spec()]))
        self.assertEqual(sorted(code for code,_ in results),[0,3])
        self.assertTrue(all(code==0 or "RP429" in out for code,out in results))
        self.assertEqual(self.balances(),[1,8,214748364788])

    def test_cancel_releases_original_day_not_new_window(self):
        asset=self.reserve()
        sql(f"update upload_budget_windows set day=current_date-1 where org_id='{self.org}'; "
            f"update upload_reservations set day=current_date-1 where asset_id='{asset['id']}'; "
            f"insert into upload_budget_windows(org_id,day,spent_bytes) values('{self.org}',current_date,7);")
        call("settle_upload_reservation",asset["id"],False)
        self.assertEqual(sql(f"select string_agg(held_bytes||':'||spent_bytes,',' order by day) from upload_budget_windows where org_id='{self.org}';"),"0:0,0:7")

    def test_recovery_acknowledges_only_existing_dispatch_without_spend(self):
        asset=self.reserve();op=self.operation(asset);claim=str(uuid.uuid4())
        self.assertIn("RP409",call("recover_upload_operation",op["id"],'"fixture"',expected=3))
        call("claim_upload_operation",op["id"],claim)
        call("finish_upload_operation",op["id"],claim,"uncertain")
        for _ in range(2): self.assertEqual(call("recover_upload_operation",op["id"],'"fixture"')["state"],"stored")
        replay=call("claim_upload_operation",op["id"],str(uuid.uuid4()))
        self.assertFalse(replay["dispatch"]);self.assertEqual(self.balances(),[1,4,4])
        self.assertIn("RP409",call("recover_upload_operation",op["id"],'"different"',expected=3))

    def test_recovery_cannot_resurrect_cancelled_dispatch(self):
        asset=self.reserve();op=self.operation(asset)
        call("claim_upload_operation",op["id"],str(uuid.uuid4()));call("settle_upload_reservation",asset["id"],False)
        self.assertIn("RP409",call("recover_upload_operation",op["id"],'"fixture"',expected=3))
        self.assertEqual(self.balances(),[1,0,4])

    def test_deleted_asset_keeps_cleanup_identity_and_releases_only_held(self):
        asset=self.reserve();op=self.stored(asset)
        sql(f"delete from capture_assets where id='{asset['id']}';")
        self.assertIn(asset["id"],call("upload_maintenance_batch")["expire"])
        call("expire_upload_reservation",asset["id"])
        self.assertEqual(self.balances(),[1,0,4])
        sql(f"update upload_operations set cleanup_after=now()-interval '1 second' where id='{op['id']}';")
        recovered=call("claim_upload_cleanup",op["id"],str(uuid.uuid4()))
        self.assertEqual(recovered["object_key"],op["object_key"])

    def test_expiry_release_replays_once(self):
        asset=self.reserve()
        self.assertIn("RP409",call("expire_upload_reservation",asset["id"],expected=3))
        sql(f"update upload_reservations set expires_at=now()-interval '1 second' where asset_id='{asset['id']}';")
        call("expire_upload_reservation",asset["id"]);call("expire_upload_reservation",asset["id"])
        self.assertEqual(self.balances(),[1,0,0])

    def test_idempotency_binds_role_size_not_late_advisory_digest(self):
        spec=self.spec("stable-fixture");asset=self.reserve(spec)
        retry={**self.spec("stable-fixture"),"sha256":"a"*64}
        self.assertEqual(self.reserve(retry)["id"],asset["id"])
        retry["bytes"]=5
        self.assertIn("RP409",call("reserve_upload_assets",self.user,[retry],expected=3))
        self.assertEqual(self.balances(),[1,8,0])

    def test_malformed_sizes_and_media_cannot_reserve(self):
        for bad in [0,-1,4.1,"4",None,67108865]:
            self.assertTrue(call("reserve_upload_assets",self.user,[self.spec(size=bad)],expected=3))
        spec=self.spec();spec["content_type"]="text/html"
        self.assertIn("RP400",call("reserve_upload_assets",self.user,[spec],expected=3))
        self.assertEqual(sql(f"select count(*) from capture_assets where listing_id='{self.listing}';"),"0")

    def test_concurrent_complete_cancel_has_one_terminal_winner(self):
        asset=self.reserve();self.stored(asset);op=self.stored(asset,"copy")
        def settle(complete):
            source=f"set role service_role; select settle_upload_reservation('{asset['id']}',{str(complete).lower()},'{op['id']}');"
            p=subprocess.run(PSQL,input=source,text=True,env=ENV,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=10)
            return complete,p.returncode,p.stdout
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: results=list(pool.map(settle,[True,False]))
        self.assertEqual(sorted(code for _,code,_ in results),[0,3])
        self.assertTrue(all(code==0 or "RP409" in out for _,code,out in results))
        winner=next(complete for complete,code,_ in results if code==0)
        self.assertEqual(sql(f"select uploaded||':'||upload_aborted from capture_assets where id='{asset['id']}';"),
                         "true:false" if winner else "false:true")
        self.assertEqual(self.balances(),[1,0,8])

    def test_legacy_cancel_records_unknown_spend_and_known_session(self):
        spec=self.spec()
        sql(f"insert into capture_assets(id,listing_id,kind,bucket,storage_key,bytes,content_type,upload_id,part_size,parts_total) values "
            f"('{spec['id']}','{self.listing}','video','uploads','{spec['storage_key']}',4,'video/quicktime','fixture-old-session',4,1);")
        for _ in range(2): self.assertTrue(call("cancel_legacy_upload",spec["id"],self.user)["upload_aborted"])
        self.assertEqual(sql(f"select spec->>'legacy_physical_bytes' from upload_reservations where asset_id='{spec['id']}';"),"unknown")
        self.assertEqual(sql(f"select upload_id from upload_operations where asset_id='{spec['id']}';"),"fixture-old-session")
        self.assertEqual(self.balances(),[0,0,0]) # explicitly unknown legacy bytes, not a refund of any v2 spend

    def test_multipart_exact_receipts_publish_in_place_without_copy_budget(self):
        spec=self.spec(size=33554436);spec.update(part_size=33554432,parts_total=2)
        asset=self.reserve(spec);op=self.operation(asset,"init");claim=str(uuid.uuid4())
        call("claim_upload_operation",op["id"],claim)
        call("finish_upload_operation",op["id"],claim,"stored","multipart-initialized","fixture-session")
        parts=[]
        for number,size in [(1,33554432),(2,4)]:
            op=call("plan_upload_operation",asset["id"],"part",number);self.assertEqual(op["bytes"],size)
            claim=str(uuid.uuid4());call("claim_upload_operation",op["id"],claim)
            etag=f'"fixture-{number}"';call("finish_upload_operation",op["id"],claim,"stored",etag)
            parts.append({"number":number,"etag":etag})
        sql(f"update capture_assets set completion_parts='{json.dumps(parts)}' where id='{asset['id']}';")
        op=self.stored(asset,"assemble");winner=call("settle_upload_reservation",asset["id"],True,op["id"])
        self.assertTrue(winner["uploaded"]);self.assertEqual(winner["storage_key"],spec["storage_key"])
        self.assertEqual(self.balances(),[1,0,33554436])
        self.assertEqual(sql(f"select count(*) from upload_operations where asset_id='{asset['id']}' and state<>'retained';"),"0")

    # ── 0042: a cut transfer is re-plannable on the same ticket ──────────────
    def reservation(self, asset):
        return sql(f"select held_bytes||':'||spent_bytes from upload_reservations where asset_id='{asset['id']}';")

    def rejected(self, asset, kind="single", part=0):
        op=call("plan_upload_operation",asset["id"],kind,part);claim=str(uuid.uuid4())
        call("claim_upload_operation",op["id"],claim)
        return call("finish_upload_operation",op["id"],claim,"rejected",None,None)

    def test_rejected_transfer_replans_in_place_and_spends_its_bytes_once(self):
        asset=self.reserve();op=self.rejected(asset)
        self.assertEqual([op["state"],op["attempt"]],["rejected",1])
        self.assertEqual(self.balances(),[1,4,4]) # the verdict itself refunds nothing
        again=self.operation(asset)
        # Same row and key, one more attempt, receipt and window cleared. The
        # old claim stays: cleanup reads it as "a write was authorized here".
        self.assertEqual([again["id"],again["object_key"],again["state"],again["attempt"],again["claim"],again["etag"],again["write_deadline"]],
                         [op["id"],op["object_key"],"planned",2,op["claim"],None,None])
        self.assertEqual(self.balances(),[1,8,0]);self.assertEqual(self.reservation(asset),"8:0")
        self.assertEqual(self.operation(asset)["attempt"],2) # re-planning is not repeated for a planned row
        claim=str(uuid.uuid4());self.assertTrue(call("claim_upload_operation",op["id"],claim)["dispatch"])
        self.assertEqual(self.balances(),[1,4,4]);self.assertEqual(self.reservation(asset),"4:4")
        call("finish_upload_operation",op["id"],claim,"stored",'"fixture"')
        self.assertEqual(self.operation(asset)["state"],"stored");self.assertEqual(self.balances(),[1,4,4])
        self.assertEqual(sql(f"select count(*) from upload_operations where asset_id='{asset['id']}' and kind='single';"),"1")

    def test_attempt_cap_keeps_rejected_until_cancellation(self):
        asset=self.reserve()
        for attempt in range(1,5):
            self.assertEqual(self.rejected(asset)["attempt"],attempt)
            self.assertEqual([self.operation(asset)["state"],self.operation(asset)["attempt"]],["planned",attempt+1])
        op=self.rejected(asset);self.assertEqual(op["attempt"],5)
        final=self.operation(asset)
        self.assertEqual([final["state"],final["attempt"],final.get("attempts_exhausted")],["rejected",5,True])
        self.assertIn("RP503",call("claim_upload_operation",op["id"],str(uuid.uuid4()),expected=3))
        self.assertEqual(self.balances(),[1,4,4]) # the fifth dispatch stays charged
        self.assertTrue(call("settle_upload_reservation",asset["id"],False)["upload_aborted"])
        self.assertEqual(self.balances(),[1,0,4])
        self.assertIn("RP409",call("plan_upload_operation",asset["id"],"single",0,expected=3))

    def test_absent_uncertain_transfer_retires_then_replans(self):
        asset=self.reserve();op=self.operation(asset);claim=str(uuid.uuid4())
        call("claim_upload_operation",op["id"],claim)
        self.assertEqual(call("finish_upload_operation",op["id"],claim,"uncertain",None,None)["state"],"uncertain")
        self.assertEqual(sql(f"select write_deadline<=clock_timestamp() from upload_operations where id='{op['id']}';"),"t")
        retired=call("recover_upload_operation",op["id"],None)
        self.assertEqual([retired["state"],retired["etag"],retired["claim"]],["rejected",None,claim])
        self.assertEqual(call("recover_upload_operation",op["id"],None)["state"],"rejected")
        self.assertEqual(self.balances(),[1,4,4])
        again=self.operation(asset);self.assertEqual([again["state"],again["attempt"]],["planned",2])
        self.assertEqual(self.balances(),[1,8,0])
        # A present receipt still wins over a later absence claim.
        claim=str(uuid.uuid4());call("claim_upload_operation",op["id"],claim)
        call("finish_upload_operation",op["id"],claim,"stored",'"fixture"')
        self.assertIn("RP409",call("recover_upload_operation",op["id"],None,expected=3))
        self.assertEqual(self.operation(asset)["state"],"stored")

    def test_silent_dispatch_is_not_retired_before_its_write_deadline(self):
        asset=self.reserve();op=self.operation(asset);claim=str(uuid.uuid4())
        call("claim_upload_operation",op["id"],claim)
        self.assertEqual(call("recover_upload_operation",op["id"],None)["state"],"dispatching")
        self.assertEqual(self.operation(asset)["state"],"dispatching")
        self.assertEqual(self.balances(),[1,4,4])
        sql(f"update upload_operations set write_deadline=clock_timestamp()-interval '1 second' where id='{op['id']}';")
        self.assertEqual(call("recover_upload_operation",op["id"],None)["state"],"rejected")
        self.assertEqual([self.operation(asset)["state"],self.operation(asset)["attempt"]],["planned",2])
        self.assertEqual(self.balances(),[1,8,0])

    def test_rejected_promotion_copy_is_never_replanned(self):
        asset=self.reserve();self.stored(asset);op=self.rejected(asset,"copy")
        again=self.operation(asset,"copy")
        self.assertEqual([again["id"],again["state"],again["attempt"]],[op["id"],"rejected",1])
        self.assertNotIn("attempts_exhausted",again)
        self.assertIn("RP409",call("recover_upload_operation",op["id"],None,expected=3))
        self.assertIn("RP503",call("claim_upload_operation",op["id"],str(uuid.uuid4()),expected=3))
        self.assertEqual(self.balances(),[1,0,8])

    def test_concurrent_replan_and_claim_keep_single_dispatch(self):
        asset=self.reserve();op=self.rejected(asset)
        commands=[f"set role service_role; select plan_upload_operation('{asset['id']}','single',0); "
                  f"select claim_upload_operation('{op['id']}','{uuid.uuid4()}');" for _ in range(8)]
        def direct(command):
            p=subprocess.run(PSQL,input=command,text=True,env=ENV,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=10)
            return p.returncode,p.stdout
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results=list(pool.map(direct,commands))
        self.assertEqual(sum(code==0 for code,_ in results),1)
        self.assertTrue(all(code==0 or code==3 and "RP503" in out for code,out in results))
        winner=self.operation(asset)
        self.assertEqual([winner["state"],winner["attempt"]],["dispatching",2])
        self.assertEqual(self.balances(),[1,4,4]);self.assertEqual(self.reservation(asset),"4:4")

def main():
    if shutil.disk_usage(OUT).free < 1024**3: raise RuntimeError("Need 1 GiB disk headroom")
    SOCKET.mkdir(mode=0o700)
    prior = {sig: signal.getsignal(sig) for sig in [signal.SIGTERM, signal.SIGHUP]}
    def interrupted(sig, frame): raise RuntimeError(f"Interrupted by {sig}")
    for sig in prior: signal.signal(sig, interrupted)
    started = False
    print("EVIDENCE:", OUT, flush=True)
    try:
        run("initdb", [PG+"initdb", "-D", str(DATA), "-U", "postgres", "-A", "trust", "--no-locale", "--encoding=UTF8"])
        started = True  # Stop even if startup returned an ambiguous failure.
        run("start", [PG+"pg_ctl", "-D", str(DATA), "-l", str(OUT/"postgres.log"), "-w", "-t", "20", "-o",
                      f"-k {SOCKET} -p 55438 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=20", "start"])
        if sql("select current_setting('data_directory')||':'||current_setting('listen_addresses');") != str(DATA)+":":
            raise RuntimeError("Owned cluster identity mismatch")
        ENV["PGOPTIONS"] = "-c statement_timeout=20000 -c lock_timeout=10000"
        sources = [ROOT/"services/supabase/tests/ci-bootstrap.sql", *sorted((ROOT/"services/supabase/migrations").glob("*.sql"))]
        RECEIPT["sourceHashes"] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
        for source in sources: run(source.stem, PSQL+["-1", "-f", str(source)])
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(UploadDatabase))
        RECEIPT.update(tests=result.testsRun, failed=len(result.failures)+len(result.errors), skipped=len(result.skipped))
        if not result.wasSuccessful() or result.skipped or result.testsRun != 26: raise RuntimeError("Database regression gate failed")
        # 0042 replaces three 0037 functions with the same signatures. Replaying
        # 0037 (mutated or restored) therefore reverts them, so every restore
        # re-applies 0042 on top; the stack under test is always 0037 + 0042.
        budget=ROOT/"services/supabase/migrations/0037_upload_transport_budget.sql"
        recovery=ROOT/"services/supabase/migrations/0042_upload_operation_recovery.sql"
        mutants=[("dispatch", budget, "or op.state <> 'planned'", "or false /* deliberate missing dispatch fence */",
                  "test_concurrent_claim_dispatches_once"),
                 ("spent-refund", budget, "set held_bytes=held_bytes-r.held_bytes where org_id=r.org_id and day=r.day;",
                  "set held_bytes=held_bytes-r.held_bytes,spent_bytes=greatest(0,spent_bytes-r.spent_bytes) where org_id=r.org_id and day=r.day;",
                  "test_cancel_is_single_settlement_after_uncertain_write"),
                 ("replan-release", recovery, "update public.upload_reservations set held_bytes=held_bytes+op.bytes, spent_bytes=spent_bytes-op.bytes where asset_id=a.id;",
                  "/* deliberate: re-plan keeps the rejected claim's bytes spent */",
                  "test_rejected_transfer_replans_in_place_and_spends_its_bytes_once"),
                 ("attempt-cap", recovery, "if op.attempt >= 5 then return", "if false then return",
                  "test_attempt_cap_keeps_rejected_until_cancellation")]
        RECEIPT["negativeControls"]=[]
        for name,migration,old,new,test in mutants:
            source=migration.read_text()
            if old not in source: raise RuntimeError("Negative mutation anchor missing: "+name)
            run("mutate-"+name,PSQL,source.replace(old,new))
            try:
                output=io.StringIO();broken=unittest.TextTestRunner(stream=output,verbosity=2).run(UploadDatabase(test))
                (OUT/("negative-"+name+".log")).write_text(output.getvalue())
                if len(broken.failures)!=1 or broken.errors or broken.skipped:
                    raise RuntimeError("Mutation was not caught by its intended assertion: "+name)
                RECEIPT["negativeControls"].append({"name":name,"migration":migration.name,"assertionFailures":1,"test":test})
            finally:
                run("restore-"+name,PSQL,source)
                run("restack-0042-"+name,PSQL,recovery.read_text())
            restored=unittest.TextTestRunner(verbosity=2).run(UploadDatabase(test))
            if not restored.wasSuccessful(): raise RuntimeError("Restored source still failed")
        RECEIPT["restoredTests"]=len(mutants)
        RECEIPT["accepted"] = True
    finally:
        try:
            if started: run("stop", [PG+"pg_ctl", "-D", str(DATA), "-m", "fast", "-w", "-t", "20", "stop"])
        except BaseException:
            RECEIPT["accepted"] = False
            raise
        finally:
            (OUT/"receipt.json").write_text(json.dumps(RECEIPT, indent=2)+"\n")
            for sig, handler in prior.items(): signal.signal(sig, handler)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
