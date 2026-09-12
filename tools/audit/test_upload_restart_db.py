#!/usr/bin/env python3
"""Actual 0042 against a fresh socket-only PG17, never an existing database."""
import concurrent.futures
import hashlib
import io
import json
import signal
import subprocess
import time
import unittest
import uuid

import test_upload_transport_db as db


class RestartDatabase(unittest.TestCase):
    setUp = db.UploadDatabase.setUp
    spec = db.UploadDatabase.spec
    reserve = db.UploadDatabase.reserve
    operation = db.UploadDatabase.operation
    stored = db.UploadDatabase.stored
    balances = db.UploadDatabase.balances

    def state(self, asset):
        return db.call("upload_restart_state", asset["id"], self.user)

    def restart(self, asset, key=None, expected=0):
        try:
            return db.call("restart_upload_asset", asset["id"], self.user, key or str(uuid.uuid4()), expected=expected)
        except RuntimeError as error:
            self.fail(f"Restart SQL did not return the expected durable receipt: {error}")

    def expire(self, asset):
        db.sql(f"update upload_reservations set expires_at=now()-interval '1 second' where asset_id='{asset['id']}';")

    def uncertain(self, asset):
        op = self.operation(asset)
        claim = str(uuid.uuid4())
        db.call("claim_upload_operation", op["id"], claim)
        db.call("finish_upload_operation", op["id"], claim, "uncertain")
        return op, claim

    def test_live_ticket_denies_restart_without_mutation(self):
        asset = self.reserve()
        self.assertFalse(self.state(asset)["restart_required"])
        self.assertIn("upload_restart_not_required", self.restart(asset, expected=3))
        self.assertEqual(self.balances(), [1, 8, 0])
        self.assertEqual(db.sql(f"select count(*) from capture_assets where listing_id='{self.listing}';"), "1")

    def test_expired_ticket_restarts_with_same_spec_and_new_key(self):
        asset = self.reserve(); self.expire(asset)
        self.assertEqual(self.state(asset)["restart_reason"], "expired")
        state = self.restart(asset); child = state["asset"]
        self.assertEqual(state["restart_generation"], 1)
        self.assertFalse(state["restart_required"])
        self.assertNotEqual(child["id"], asset["id"])
        self.assertNotEqual(child["storage_key"], asset["storage_key"])
        for key in ["listing_id", "bucket", "kind", "bytes", "content_type", "content_type_declared", "part_size", "parts_total"]:
            self.assertEqual(child[key], asset[key])
        self.assertEqual(self.balances(), [2, 8, 0])

    def test_uncertain_write_spend_and_cleanup_survive(self):
        asset = self.reserve(); op, _ = self.uncertain(asset)
        self.assertEqual(self.state(asset)["restart_reason"], "interrupted")
        child = self.restart(asset)["asset"]
        self.assertEqual(self.balances(), [2, 8, 4])
        self.assertEqual(db.sql(f"select state||':'||spent_bytes||':'||held_bytes from upload_reservations where asset_id='{asset['id']}';"), "cancelled:4:0")
        self.assertEqual(db.sql(f"select (cleanup_after>=write_deadline+interval '1 hour')::text from upload_operations where id='{op['id']}';"), "true")
        self.assertIn("RP503", db.call("claim_upload_operation", op["id"], str(uuid.uuid4()), expected=3))
        self.assertNotEqual(self.operation(child)["object_key"], op["object_key"])

    def test_active_dispatch_not_restarted_until_deadline(self):
        asset = self.reserve(); op = self.operation(asset)
        db.call("claim_upload_operation", op["id"], str(uuid.uuid4()))
        busy = self.state(asset)
        self.assertFalse(busy["restart_required"])
        self.assertTrue(1 <= busy["retry_after_seconds"] <= 900)
        self.assertIn("upload_restart_not_required", self.restart(asset, expected=3))
        db.sql(f"update upload_operations set write_deadline=now()-interval '1 second' where id='{op['id']}';")
        self.assertEqual(self.state(asset)["restart_reason"], "interrupted")
        self.assertEqual(self.restart(asset)["restart_generation"], 1)
        self.assertEqual(self.balances(), [2, 8, 4])

    def test_one_child_for_same_and_different_idempotency_keys(self):
        asset = self.reserve(); self.expire(asset); key = str(uuid.uuid4())
        child = self.restart(asset, key)["asset"]
        for intent in [key, str(uuid.uuid4()), key]:
            self.assertEqual(self.restart(asset, intent)["asset"]["id"], child["id"])
        self.assertEqual(self.balances(), [2, 8, 0])

    def test_parent_replay_returns_completed_or_expired_direct_child(self):
        asset = self.reserve(); self.expire(asset)
        child = self.restart(asset)["asset"]; self.expire(child)
        state = self.restart(asset)
        self.assertEqual(state["asset"]["id"], child["id"])
        self.assertEqual(state["restart_reason"], "expired")
        db.sql(f"update upload_reservations set expires_at=now()+interval '1 hour' where asset_id='{child['id']}';")
        self.stored(child); copy = self.stored(child, "copy")
        db.call("settle_upload_reservation", child["id"], True, copy["id"])
        state = self.restart(asset)
        self.assertTrue(state["asset"]["uploaded"])
        self.assertEqual(state["asset"]["id"], child["id"])
        self.assertEqual(self.balances(), [2, 0, 8])

    def test_four_total_attempts_exhaust_without_fifth_mutation(self):
        asset = self.reserve()
        for generation in range(1, 4):
            self.expire(asset); state = self.restart(asset)
            self.assertEqual(state["restart_generation"], generation)
            asset = state["asset"]
        self.expire(asset); before = self.balances()
        self.assertIn("upload_restart_exhausted", self.restart(asset, expected=3))
        self.assertEqual(self.balances(), before)
        self.assertEqual(db.sql(f"select count(*) from capture_assets where listing_id='{self.listing}';"), "4")
        self.assertEqual(db.sql(f"select state||':'||(replacement_asset_id is null) from upload_reservations where asset_id='{asset['id']}';"), "open:true")

    def test_budget_denial_rolls_back_old_cancellation_and_link(self):
        asset = self.reserve(); self.uncertain(asset)
        db.sql(f"update upload_budget_windows set spent_bytes=214748364796 where org_id='{self.org}';")
        before = self.balances()
        self.assertIn("RP429", self.restart(asset, expected=3))
        self.assertEqual(self.balances(), before)
        self.assertEqual(db.sql(f"select state||':'||(replacement_asset_id is null) from upload_reservations where asset_id='{asset['id']}';"), "open:true")
        self.assertEqual(db.sql(f"select upload_aborted from capture_assets where id='{asset['id']}';"), "f")

    def test_ticket_cap_denial_does_not_cancel_original(self):
        asset = self.reserve(); self.expire(asset)
        db.sql(f"update upload_budget_windows set tickets=2000 where org_id='{self.org}';")
        self.assertIn("RP429", self.restart(asset, expected=3))
        self.assertEqual(self.balances(), [2000, 8, 0])
        self.assertEqual(db.sql(f"select state from upload_reservations where asset_id='{asset['id']}';"), "open")

    def test_original_day_release_current_day_charge(self):
        asset = self.reserve(); self.uncertain(asset)
        db.sql(f"update upload_budget_windows set day=current_date-1 where org_id='{self.org}'; "
               f"update upload_reservations set day=current_date-1 where asset_id='{asset['id']}';")
        self.restart(asset)
        self.assertEqual(db.sql(f"select string_agg(tickets||':'||held_bytes||':'||spent_bytes,',' order by day) from upload_budget_windows where org_id='{self.org}';"), "1:0:4,1:8:0")

    def test_completed_original_returns_receipt_no_charge(self):
        asset = self.reserve(); self.stored(asset); copy = self.stored(asset, "copy")
        db.call("settle_upload_reservation", asset["id"], True, copy["id"])
        result = self.restart(asset)
        self.assertTrue(result["asset"]["uploaded"])
        self.assertEqual(result["asset"]["id"], asset["id"])
        self.assertEqual(self.balances(), [1, 0, 8])

    def test_cancelled_original_can_be_explicitly_restarted(self):
        asset = self.reserve(); db.call("settle_upload_reservation", asset["id"], False)
        self.assertEqual(self.state(asset)["restart_reason"], "cancelled")
        self.assertEqual(self.restart(asset)["restart_generation"], 1)
        self.assertEqual(self.balances(), [2, 8, 0])

    def test_cross_tenant_marketing_deleted_actor_and_public_denied(self):
        asset = self.reserve(); self.expire(asset); stranger = str(uuid.uuid4())
        self.assertIn("RP403", db.call("restart_upload_asset", asset["id"], stranger, str(uuid.uuid4()), expected=3))
        db.sql(f"update memberships set role='marketing' where user_id='{self.user}';")
        self.assertIn("RP403", self.restart(asset, expected=3))
        db.sql(f"update memberships set role='owner' where user_id='{self.user}'; "
               f"insert into deletion_requests(user_id,email,status) values('{self.user}','fixture@example.invalid','pending');")
        self.assertIn("RP403", self.restart(asset, expected=3))
        for role in ["anon", "authenticated"]:
            self.assertIn("permission denied", db.sql(f"set role {role}; select restart_upload_asset('{asset['id']}','{self.user}','{uuid.uuid4()}');", expected=3))
            self.assertIn("permission denied", db.sql(f"set role {role}; select upload_restart_state('{asset['id']}','{self.user}');", expected=3))
        self.assertEqual(self.balances(), [1, 8, 0])

    def test_original_photo_role_and_multipart_shape_preserved(self):
        for role in ["original", "gallery"]:
            spec = self.spec(); spec.update(kind="photo", bucket="renders", content_type="image/jpeg",
                storage_key=f"renders/{self.org}/{self.listing}/{role}-{spec['id']}.jpg")
            asset = self.reserve(spec); self.expire(asset); child = self.restart(asset)["asset"]
            self.assertEqual(child["bucket"], "renders")
            self.assertIn(f"/{role}-{child['id']}.jpg", child["storage_key"])
        spec = self.spec(size=33554436); spec.update(part_size=33554432, parts_total=2)
        asset = self.reserve(spec); self.expire(asset); child = self.restart(asset)["asset"]
        self.assertEqual([child["part_size"], child["parts_total"], child["bytes"]], [33554432, 2, 33554436])

    def test_late_old_copy_cannot_publish_or_touch_child(self):
        asset = self.reserve(); self.stored(asset); op = self.operation(asset, "copy"); claim = str(uuid.uuid4())
        db.call("claim_upload_operation", op["id"], claim)
        db.sql(f"update upload_operations set write_deadline=now()-interval '1 second' where id='{op['id']}';")
        child = self.restart(asset)["asset"]
        db.call("finish_upload_operation", op["id"], claim, "stored", '"old-copy"')
        self.assertIn("RP409", db.call("settle_upload_reservation", asset["id"], True, op["id"], expected=3))
        self.assertEqual(self.balances(), [2, 8, 8])
        self.assertFalse(self.state(child)["asset"]["uploaded"])
        self.assertEqual(db.sql(f"select (cleanup_after is not null) from upload_operations where id='{op['id']}';"), "t")

    def test_migration_replay_preserves_chain_and_spent(self):
        asset = self.reserve(); self.uncertain(asset); child = self.restart(asset)["asset"]
        db.run("replay-0042", db.PSQL+["-1", "-f", str(db.ROOT/"services/supabase/migrations/0042_upload_explicit_restart.sql")])
        self.assertEqual(self.restart(asset)["asset"]["id"], child["id"])
        self.assertEqual(self.balances(), [2, 8, 4])

    def test_deletion_snapshots_old_and_child_before_retiring_rows(self):
        asset = self.reserve(); old, _ = self.uncertain(asset)
        child = self.restart(asset)["asset"]; new, _ = self.uncertain(child)
        result = db.call("prepare_account_deletion", self.user, "fixture-uploads", "fixture-renders")
        self.assertTrue(result["ok"])
        keys = {target["key"] for target in result["payload"]["r2"]}
        self.assertTrue({asset["storage_key"], child["storage_key"], old["object_key"], new["object_key"]}.issubset(keys))
        self.assertEqual(db.sql(f"select count(*) from upload_reservations where org_id='{self.org}';"), "0")
        self.assertEqual(db.sql(f"select count(*) from upload_operations where asset_id in ('{asset['id']}','{child['id']}');"), "0")
        self.assertIsNotNone(result["payload"]["storage_not_before"])
        self.assertFalse(result.get("cleanup_complete", False))

    def test_spatial_attach_rejects_cancelled_parent_accepts_completed_child(self):
        spec = self.spec(); spec.update(kind="photo",content_type="image/jpeg",
            storage_key=f"uploads/{self.org}/{self.listing}/{spec['id']}.jpg")
        asset = self.reserve(spec); self.expire(asset); child = self.restart(asset)["asset"]
        capture = str(uuid.uuid4()); manifest = {"status":"complete","session_id":capture,
            "frames":[f"frames/{i:06}.json" for i in range(20)]}
        job = db.call("spatial_create", self.user,self.listing,capture,str(uuid.uuid4()),"Room",manifest)
        frame = {"session_id":capture,"image":"images/000000.jpg","tracking_state":{"state":"normal"}}
        def attach(ticket):
            return [{"ticket_id":ticket["id"],"relative_path":"images/000000.jpg","frame":frame}]
        self.assertIn("RP409",db.call("spatial_attach_inputs",self.user,job["id"],attach(asset),expected=3))
        self.assertIn("RP409",db.call("spatial_attach_inputs",self.user,job["id"],attach(child),expected=3))
        self.stored(child); copy = self.stored(child,"copy")
        db.call("settle_upload_reservation",child["id"],True,copy["id"])
        self.assertEqual(db.call("spatial_attach_inputs",self.user,job["id"],attach(child))["status"],"uploading")
        self.assertEqual(db.sql(f"select ticket_id from spatial_inputs where job_id='{job['id']}';"),child["id"])

    def test_completion_locked_before_restart_wins_without_replacement(self):
        asset = self.reserve(); self.stored(asset); copy = self.stored(asset, "copy")
        blocker = subprocess.Popen(db.PSQL, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, env=db.ENV)
        waiting = None
        try:
            blocker.stdin.write(f"begin; set role service_role; select settle_upload_reservation('{asset['id']}',true,'{copy['id']}');\n")
            blocker.stdin.flush()
            self.assertTrue(json.loads(blocker.stdout.readline())["uploaded"])
            waiting = subprocess.Popen(db.PSQL, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       text=True, env=db.ENV)
            waiting.stdin.write(f"set application_name='complete-race-{self.listing}'; set role service_role; "
                                f"select restart_upload_asset('{asset['id']}','{self.user}','{uuid.uuid4()}');\n")
            waiting.stdin.flush()
            deadline = time.monotonic()+5
            while db.sql(f"select count(*) from pg_stat_activity where application_name='complete-race-{self.listing}' and wait_event_type='Lock';") != "1":
                if time.monotonic()>deadline: self.fail("Restart did not overlap the real completion lock")
                time.sleep(0.02)
            blocker.stdin.write("commit;\n"); blocker.stdin.flush()
            result = json.loads(waiting.stdout.readline())
            self.assertTrue(result["asset"]["uploaded"])
            self.assertEqual(result["asset"]["id"], asset["id"])
            self.assertEqual(self.balances(), [1, 0, 8])
        finally:
            for process in [p for p in [blocker,waiting] if p is not None]:
                if process.poll() is None:
                    process.stdin.close(); process.wait(timeout=5)
                self.assertEqual(process.returncode, 0)

    def test_observed_overlap_has_one_child_for_different_keys(self):
        asset = self.reserve(); self.expire(asset)
        # Hold the ACTUAL listing lock, observe both waiters in pg_stat_activity,
        # then release. This is overlapping SQL, not a sequential fake race.
        blocker = subprocess.Popen(db.PSQL, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, env=db.ENV)
        processes = []
        try:
            blocker.stdin.write(f"begin; select id from listings where id='{self.listing}' for update;\n"); blocker.stdin.flush()
            self.assertEqual(blocker.stdout.readline().strip(), self.listing)
            for index in range(2):
                process = subprocess.Popen(db.PSQL, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                           text=True, env=db.ENV)
                process.stdin.write(f"set application_name='restart-fixture-{self.listing}-{index}'; set role service_role; "
                                    f"select restart_upload_asset('{asset['id']}','{self.user}','{uuid.uuid4()}');\n")
                process.stdin.flush(); processes.append(process)
            deadline = time.monotonic()+5
            while True:
                waiting = db.sql(f"select count(*) from pg_stat_activity where application_name like 'restart-fixture-{self.listing}-%' and wait_event_type='Lock';")
                if waiting == "2": break
                if time.monotonic() > deadline: self.fail("Both restart calls were not observed waiting on the real lock")
                time.sleep(0.02)
            blocker.stdin.write("commit;\n"); blocker.stdin.flush()
            results = [json.loads(p.stdout.readline()) for p in processes]
            self.assertEqual(len({r["asset"]["id"] for r in results}), 1)
            self.assertEqual(self.balances(), [2, 8, 0])
        finally:
            for process in [blocker, *processes]:
                if process.poll() is None:
                    process.stdin.close(); process.wait(timeout=5)
                self.assertEqual(process.returncode, 0)


def main():
    started = False
    print("EVIDENCE:", db.OUT, flush=True)
    prior = {sig: signal.getsignal(sig) for sig in [signal.SIGTERM, signal.SIGHUP]}
    def interrupted(sig, frame): raise RuntimeError(f"Interrupted by {sig}")
    for sig in prior: signal.signal(sig, interrupted)
    try:
        db.SOCKET.mkdir(mode=0o700)
        db.run("initdb", [db.PG+"initdb", "-D", str(db.DATA), "-U", "postgres", "-A", "trust", "--no-locale", "--encoding=UTF8"])
        started = True
        db.run("start", [db.PG+"pg_ctl", "-D", str(db.DATA), "-l", str(db.OUT/"postgres.log"), "-w", "-t", "20", "-o",
                         f"-k {db.SOCKET} -p 55438 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=20", "start"])
        assert db.sql("select current_setting('data_directory')||':'||current_setting('listen_addresses');") == str(db.DATA)+":"
        db.ENV["PGOPTIONS"] = "-c statement_timeout=20000 -c lock_timeout=10000"
        sources = [db.ROOT/"services/supabase/tests/ci-bootstrap.sql", *sorted((db.ROOT/"services/supabase/migrations").glob("*.sql"))]
        db.RECEIPT["sourceHashes"] = {str(p.relative_to(db.ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
        for source in sources: db.run(source.stem, db.PSQL+["-1", "-f", str(source)])
        suite = unittest.TestSuite([unittest.defaultTestLoader.loadTestsFromTestCase(db.UploadDatabase),
                                   unittest.defaultTestLoader.loadTestsFromTestCase(RestartDatabase)])
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        db.RECEIPT.update(tests=result.testsRun, failed=len(result.failures)+len(result.errors), skipped=len(result.skipped))
        if not result.wasSuccessful() or result.skipped or result.testsRun != 40: raise RuntimeError("Restart database gate failed")
        source = sources[-1].read_text()
        assert sources[-1].name == "0042_upload_explicit_restart.sql"
        # Functions are replaced in the owned test cluster; migration/table DDL
        # is not replayed. Each mutation must cause its intended assertion fail.
        functions = source[source.index("create or replace function public.upload_restart_state"):]
        controls = [("one-child", "if r.replacement_asset_id is not null then", "if false then", "test_one_child_for_same_and_different_idempotency_keys"),
                    ("attempt-limit", "if r.restart_generation >= 3 then", "if false then", "test_four_total_attempts_exhaust_without_fifth_mutation")]
        db.RECEIPT["negativeControls"] = []
        for name, old, new, test in controls:
            assert functions.count(old) == 1
            db.run("mutate-"+name, db.PSQL, functions.replace(old, new))
            try:
                stream = io.StringIO(); broken = unittest.TextTestRunner(stream=stream, verbosity=2).run(RestartDatabase(test))
                (db.OUT/("negative-"+name+".log")).write_text(stream.getvalue())
                assert len(broken.failures) == 1 and not broken.errors and not broken.skipped, name
                db.RECEIPT["negativeControls"].append({"name":name,"assertionFailures":1,"test":test})
            finally: db.run("restore-"+name, db.PSQL, functions)
            fixed = unittest.TextTestRunner(verbosity=2).run(RestartDatabase(test))
            assert fixed.wasSuccessful() and fixed.testsRun == 1 and not fixed.skipped
        db.RECEIPT["accepted"] = True
    finally:
        try:
            if started: db.run("stop", [db.PG+"pg_ctl", "-D", str(db.DATA), "-m", "fast", "-w", "-t", "20", "stop"])
        except BaseException:
            db.RECEIPT["accepted"] = False
            raise
        finally:
            (db.OUT/"receipt.json").write_text(json.dumps(db.RECEIPT, indent=2)+"\n")
            for sig, handler in prior.items(): signal.signal(sig, handler)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
