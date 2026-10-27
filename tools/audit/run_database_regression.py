#!/usr/bin/env python3
"""Replay repo migrations and invariants in a new local, socket-only cluster.

Never connects to an existing database or accepts a database URL. Child processes
get no inherited PG/service credentials. Data/logs are retained for diagnosis;
only the exact cluster created by this run is stopped in finally.
"""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile

# No invariant failure is currently accepted. The historical agent-reel
# headroom exception was removed only after all270 passed on fresh and replayed
# schemas with the compact <=500-byte answer and unchanged700 combined cap.
# Keep classification generic so any future explicit exception must still be
# named, visible and rejected if it becomes stale.
KEPT_RED: set[str] = set()

# Exact size of the tests/invariants.sql inventory. A suite that prints fewer
# rows is rejected even when its footer agrees with itself, so this number has
# to move in the same change that adds or removes an assertion (+19 for the 0047
# lifecycle-notification section — the outbox posture, the lead and publish
# triggers, dedupe, preferences and mute, claim/mark/sweep, the two-connection
# SKIP LOCKED race and the scheduled tick's idempotency; +13 for the 0048
# brokerage section — bulk invites, the seat ledger, brokerage_overview and the
# org-scoped compliance_audit; 234 since the 0046 commercial-telemetry section —
# activation stamp, org_is_real, cancelled_at, admin_cohorts/admin_churn; 213 for
# the 0044 plan-rework / industry-trial section; 198 before that).
#
# The 0047/0048 branches totalled 266. Apple chronology and listing facts
# registration added four assertions; the limited-trial video policy adds one
# more, bringing the inventory to 271.
# The kept-red exception is identified by its exact name, not its row number.
INVARIANT_COUNT = 271

# These tests are transactional and rolled back. Require their exact completion
# markers on both freshly migrated and historically replayed schemas; merely
# hashing/registering an SQL file does not prove its receipts or cost fences.
REFLECTION_FIXTURES = (
    ("video_erase.sql", "PASS video erase SQL: 51 assertions", 51),
    ("video_erase_direct_bria.sql", "PASS direct Bria SQL: 40 assertions", 40),
    ("member_portfolios.sql", "PASS: member portfolio SQL assertions; all fixtures rolled back.", 23),
    # Build 58: Recently deleted (30-day restore window) and republish in place.
    ("build58_db_controls.sql", '{"suite": "build58_db_controls", "assertions": 52}', 52),
    ("property_address_lookup.sql", '"assertions": 25', 25),
)

# These already-shipped transactional Studio migrations intentionally create
# their tables/policies once. Apply every listed file on BOTH fresh database paths, but
# do not manufacture a second CREATE as an idempotency requirement. Keep this
# list exact: an unknown/new migration still receives the historical replay rule.
SINGLE_APPLICATION_MIGRATIONS = frozenset({
    "20260914161954_studio_cross_device_workspace.sql",
    "20260914164554_studio_documents_named_accounts.sql",
    "20260914170849_studio_generated_quality_gate.sql",
    "20260914173513_studio_edit_output_disclosure.sql",
    "20260914174519_studio_voice_history_cleanup.sql",
    "20260914175636_studio_account_cleanup_schedule.sql",
    "20260914180739_studio_voice_storage_reservations.sql",
    "20260914185000_studio_gallery_controls.sql",
    "20260924232058_studio_named_projects.sql",
    "20260924232510_studio_project_media.sql",
    "20260924232803_studio_property_music.sql",
    # Launch ceiling mode (2026-10-08): exact-anchor rewrites of live function
    # bodies (pg_temp.rp_patch) refuse a second application by design.
    "20261008201736_launch_ceiling_mode.sql",
    "20261008220411_launch_blockers.sql",
    "20261008235218_launch_round2.sql",
    "20261009005727_launch_settlement_identity.sql",
    # Superseded function overlay: focused drivers preserve its historical
    # replay proof and verify it refuses the later reviewed device functions.
    "20261010030225_reaudit_library_session_settlement.sql",
    # The accepted-photo publication migration replaces a guarded presenter
    # dependency and adds photo_publication once; its exact second application
    # must refuse, while each fresh database still applies it once.
    "20261020212328_accepted_photo_publication_host_compatible.sql",
    # These subsequent source/Photo Motion/aerial changes either create an
    # object once or compare-and-swap an exact predecessor body. Each succeeds
    # on both fresh database paths and refuses its own second application.
    "20261020212445_private_video_source_prepare.sql",
    "20261021161119_property_video_source_read_recovery.sql",
    "20261021165424_property_video_terminal_temporal_resume_guard.sql",
    "20261021173551_property_video_prompt_revision_registry.sql",
    "20261021212436_property_video_immutable_temporal_hold_resume.sql",
    "20261021222704_property_video_explicit_photo_motion.sql",
    "20261022003118_property_video_photo_motion_v2_twelve_percent.sql",
    "20261022223052_aerial_opening_durable_generation_20261022.sql",
    "20261022223138_aerial_opening_photo_motion_composition_20261022.sql",
    "20261022223141_photo_motion_prospective_modeled_server_cost_20261022.sql",
    "20261022223142_photo_motion_preserve_exact_producer_history_20261022.sql",
    "20261023013450_aerial_opening_pro_1080_prospective.sql",
    "20261023170504_aerial_raw_source_duration_precision_20261023.sql",
    "20261023173659_aerial_measured_output_terminal_failure_20261023.sql",
    "20261023173725_aerial_omni_reference_profile_functions_20261023.sql",
    "20261023191327_studio_internal_aerial_media_purpose_20261023.sql",
    "20261023200943_photo_motion_registered_publication_profile_20261023.sql",
    "20261023202520_photo_publication_internal_scope_validation_20261023.sql",
    "20261024000646_aerial_original_legacy_byte_verification_20261024.sql",
    # Intro policy has compare-and-swap guards for its live function/catalog
    # anchors; the focused policy driver proves a second application refuses.
    "20261026165813_limit_intro_trial_creative_spend.sql",
    "20261026175227_public_property_address_lookup.sql",
    "20261027040000_property_address_reservations.sql",
    # The new credit tables/columns and the Team seat table are intentionally
    # installed once. Their exact bytes and second-application refusals are
    # pinned below, while every other credit migration must replay.
    "20261027161201_verified_monthly_credit_period.sql",
    "20261027161203_declutter_assessment_budget.sql",
    "20261027171200_credit_intent_immutable_amount.sql",
    "20261027173000_dormant_combined_credit_budget.sql",
    "20261027180000_team_paid_seat_variants.sql",
    # The dormant aerial tariff and fair-charge journal add immutable columns
    # and tables and replace exact predecessor functions only once.
    "20261027183000_credit_aerial_opening.sql",
    "20261027184000_aerial_fair_charge.sql",
})

# These six applied files are compare-and-swap adoptions of an exact live job,
# producer configuration, or reviewed function metadata. Their guards must
# reject an empty database. A fresh-schema replay includes their source hashes
# but cannot honestly manufacture the historical live rows they required.
# Pin names AND bytes: any edit or newly missing file requires an explicit
# review of this classification before the disposable/CI replay can proceed.
LIVE_STATE_ONLY_MIGRATIONS = {
    "20261023044520_photo_motion_bfb1_fixed_recovery_controller.sql": "127ff57bfac508e47d32bda54719bbb69e261136d6d8f96a85c83da020622b25",
    "20261023141755_photo_motion_c74_terminal_reconciliation_controller.sql": "aa95bcc947c7aa60367f0e15bf7b883c2b101676d415808529237b944c132ef4",
    "20261023144319_photo_motion_a1bb_empty_queue_terminal_cleanup_controller.sql": "a58465b97a5f36f82ff951591f1af4563be40008c5d39a396fa861e2a2458bd0",
    "20261023173823_aerial_omni_reference_prospective_route_20261023.sql": "9f63c1faeae5cbf8bc81a19dfcba7336132e634f9afd99fcfa889db8bf5c1fef",
    "20261023185845_photo_motion_cf7_concurrent_scheduler_history_20261023.sql": "13456ba634895717892380a556f51b734e394df1381d43cbd51c0dd065494c9a",
    "20261023215829_studio_current_reviewed_photo_motion_kit_20261023.sql": "f93481224aa3a93331a20e028097507e263650064c514380a414a65d7801d0e0",
}

# Each of these source migrations has been applied successfully once in a
# disposable PG17 database in production order. A second application at its
# historical schema point deliberately refuses: a guarded predecessor has
# changed, or a one-time object already exists. Pin the exact source bytes and
# first refusal so an edited migration cannot silently inherit this exception.
# These remain schema migrations on BOTH fresh databases, unlike the separate
# six live-state adoptions above. Unknown migrations still replay twice.
GUARDED_ONE_SHOT_MIGRATIONS = {
    "20261020212328_accepted_photo_publication_host_compatible.sql": ("c49716cb9efe6f07f6e31c2f77e4ba2bc10fba246ae568352932e58c3810e442", "Review changed photo publication dependency: public.studio_presenter_media_access_inner(uuid)"),
    "20261020212445_private_video_source_prepare.sql": ("96739271ae3034a252f7fc6649fc29bc68977f831dfda3e87aa540ccb0eac523", "Review private video-source schema/dependency installation"),
    "20261021161119_property_video_source_read_recovery.sql": ("110d525ee26a2c6576d0f487d4fc9dc97ba2e561cadd16df559031ea90bd6cc8", "relation \"property_video_source_read_retired_keys\" already exists"),
    "20261021165424_property_video_terminal_temporal_resume_guard.sql": ("61e4a3c3f70df3e4ed398e996664b60dfd76b2e473b70a01e69342509d634d6a", "Review existing terminal-temporal resume guard objects"),
    "20261021173551_property_video_prompt_revision_registry.sql": ("fc8175e46460ac620887cbc22bcb2b7a671abe0949f149ef7676c8d4a101c60a", "Review changed predecessor: property_video_quality_freeze()"),
    "20261021212436_property_video_immutable_temporal_hold_resume.sql": ("d9c4ee8d5797447947bf73fdd0fc886680b089aebc6b0b203e156e0f419ccd3e", "Review changed immutable temporal hold authority"),
    "20261021222704_property_video_explicit_photo_motion.sql": ("689eae838d5d3dc3e2ba60ce44c9d9faf13cc8335e34f41e3f7fbb8facc146f0", "Review changed Photo Motion predecessor: property_video_quality_freeze()"),
    "20261022003118_property_video_photo_motion_v2_twelve_percent.sql": ("ebae035f84cf0cee07ed544689f5f84ae4924cc025496e5acbca522f5db3d8da", "Photo motion V2 predecessor changed: property_video_job_admit_photo_motion(uuid,jsonb)"),
    "20261022223052_aerial_opening_durable_generation_20261022.sql": ("84450cef2d7b47dbed0d24784e2608f006c686dc44fcc2b2d879c558f7b77875", "relation \"property_video_aerial_openings\" already exists"),
    "20261022223138_aerial_opening_photo_motion_composition_20261022.sql": ("1fb1e1b76b575490fdbcd0cdb60eb27944342503a1e4fb63e97a582e34fd9531", "Aerial composition predecessor changed: public.property_video_photo_motion_profile(jsonb)"),
    "20261022223141_photo_motion_prospective_modeled_server_cost_20261022.sql": ("a9a8de7b1dcf725c4f53f4200445c4d0edaf6eb4dfa92c030307956ce3bb34b9", "Review changed Photo Motion cost predecessor: public.property_video_job_finish_photo_motion(uuid,uuid,jsonb)"),
    "20261022223142_photo_motion_preserve_exact_producer_history_20261022.sql": ("33b6bb190e42daa889cb03da069d1e79786281cebe2da7277be31e41fa02017f", "Producer history predecessor changed: public.property_video_photo_motion_saved_identity_before_opening_20261022(text,jsonb)"),
    "20261023013450_aerial_opening_pro_1080_prospective.sql": ("2717dd842aba0fecf4785fb02762a3126945961b2aee728fe459e1db60b12533", "RP409: Aerial Pro predecessor changed: public.property_video_aerial_policy()"),
    "20261023170504_aerial_raw_source_duration_precision_20261023.sql": ("e43f8eb9ae32841dbca1230fa6f0932309bc73da3951b9c003d883af6fa9cc0f", "Aerial precision predecessor changed; no replacement applied"),
    "20261023173659_aerial_measured_output_terminal_failure_20261023.sql": ("7ca377fd1e82ba53fbd3f9b39362aa814f5e86ae6813263b1bfbcf076d4b0fa8", "Aerial terminal-output predecessor changed"),
    "20261023173725_aerial_omni_reference_profile_functions_20261023.sql": ("64381f7fa417fc2c3f8707cb4dace0bb38b6d8553672b7be5bd6be76c28ef781", "RP409: Aerial reference predecessor changed: public.property_video_aerial_policy()"),
    "20261023191327_studio_internal_aerial_media_purpose_20261023.sql": ("5653255c71cfc69474e4b6b8e56c8820802ada536fccc1b2361cc127660ef185", "Review changed public.assert_recorded_render_source(uuid,uuid) before applying aerial media purpose"),
    "20261023200943_photo_motion_registered_publication_profile_20261023.sql": ("704b78181199d9c59f4ca29ef8dfd98de993978f836e74ef2be94e82fa0ac453", "Review changed registered background-video delivery authority"),
    "20261023202520_photo_publication_internal_scope_validation_20261023.sql": ("696d0e233ca1a4e2398f6c5d1c408b3f2c1161b754feeef773a9648546a6498b", "Review changed photo publication internal authority: photo_publication_source"),
    "20261024000646_aerial_original_legacy_byte_verification_20261024.sql": ("86b4afcee317adbc088498a85f5297c9be25acc41afe44df4f1a1ed9cdf106a6", "Original verification predecessor changed: property_video_aerial_original"),
    "20261026175227_public_property_address_lookup.sql": ("aa1eedd3dbfc5452f7a461eea7f4c56292d34ab796caa1bc79069bb2fe3aa0da", "function \"property_address_descriptor\" already exists with same argument types"),
    "20261027040000_property_address_reservations.sql": ("4c2d1c76272d821831c2a2e61d1ef3948a7e636b51c542e1930ed72565eda3f6", "relation \"property_address_reservations\" already exists"),
    "20261027161201_verified_monthly_credit_period.sql": ("49e7a2fc222969143aa5c38a1752dfd1499bd0fcf832b594c2638796e87bd822", "relation \"credit_monthly_events\" already exists"),
    "20261027161203_declutter_assessment_budget.sql": ("38bc1202b111f6ea7b4fd7368ebd476b835abb5c67a6cf18c3ada64522589f5e", "relation \"photo_declutter_assessment_admissions\" already exists"),
    "20261027171200_credit_intent_immutable_amount.sql": ("b8d0ad6a132af98d45e3b9d90034c41ae5b70608b2e2a05e06a1bd197bd47a8e", "column \"credits\" of relation \"credit_purchase_intents\" already exists"),
    "20261027173000_dormant_combined_credit_budget.sql": ("b9846c5a5544344915709fda8cf541dd08531dbf8a0633d00500daa55e34d843", "column \"price_milliunits\" of relation \"credit_monthly_events\" already exists"),
    "20261027180000_team_paid_seat_variants.sql": ("9a54cb1f857e81064e513d517c2e75d9a136e346d0b849cda58e7c25f7f27550", "relation \"team_paid_seat_variants\" already exists"),
    "20261027183000_credit_aerial_opening.sql": ("dbb0adb83dd45bf937fd194399e00f595f39b3778eaf48abddc96a557a8e4110", "column \"credit_hold_id\" of relation \"app_video_cost_reservations\" already exists"),
    "20261027184000_aerial_fair_charge.sql": ("f2499878ec4609dccc526128e6814d3909d041e0d8024d190909e665be9be273", "relation \"credit_aerial_failure_budget\" already exists"),
}


def partition_fresh_migrations(paths):
    paths = tuple(paths)
    names = [path.name for path in paths]
    require(len(names) == len(set(names)), "Duplicate migration filenames in fresh replay")
    missing = set(LIVE_STATE_ONLY_MIGRATIONS) - set(names)
    require(not missing, f"Classified live-state migrations missing: {sorted(missing)}")
    guarded_missing = set(GUARDED_ONE_SHOT_MIGRATIONS) - set(names)
    require(not guarded_missing, f"Guarded one-shot migrations missing: {sorted(guarded_missing)}")
    require(not set(GUARDED_ONE_SHOT_MIGRATIONS) & set(LIVE_STATE_ONLY_MIGRATIONS),
            "A migration cannot be both guarded one-shot and live-state only")
    require(set(GUARDED_ONE_SHOT_MIGRATIONS) <= SINGLE_APPLICATION_MIGRATIONS,
            "Guarded one-shot classification missing from single-application policy")
    schema, live_state = [], []
    for path in paths:
        guarded = GUARDED_ONE_SHOT_MIGRATIONS.get(path.name)
        if guarded is not None:
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            require(actual == guarded[0], f"Guarded one-shot migration changed: {path.name}")
        expected = LIVE_STATE_ONLY_MIGRATIONS.get(path.name)
        if expected is None:
            schema.append(path)
        else:
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            require(actual == expected, f"Classified live-state migration changed: {path.name}")
            live_state.append(path)
    return schema, live_state


def replayable_migration(name):
    return name not in SINGLE_APPLICATION_MIGRATIONS and name not in LIVE_STATE_ONLY_MIGRATIONS and (
        name.startswith(("0005b_", "0008b_")) or name >= "0009")


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def classify_failures(names, failed):
    """Split one invariant run's failures into the documented kept-red set and
    everything else. `stale` lists kept-red assertions that are present in the
    inventory but no longer fail."""
    kept = [name for name in failed if name in KEPT_RED]
    unexpected = [name for name in failed if name not in KEPT_RED]
    stale = sorted(name for name in KEPT_RED if name in names and name not in failed)
    return kept, unexpected, stale


def announce_kept_red(phase, names, kept):
    print("=" * 72, flush=True)
    print(f"KEPT-RED ({phase}): {len(kept)} assertion(s) failed and are accepted by owner decision", flush=True)
    for name in kept:
        print(f"  #{names.index(name) + 1} {name}", flush=True)
    print("  rationale: the assertion's own comment in services/supabase/tests/invariants.sql;", flush=True)
    print("  the exception list is KEPT_RED at the top of tools/audit/run_database_regression.py", flush=True)
    print("=" * 72, flush=True)


def invariant_rows(output, exit_code):
    # The independent inventory prevents a shortened table from becoming a
    # green suite merely because its printed footer matches the shorter count.
    rows = re.findall(r"^\s*(\d+) \| (.*?) \|\s*(t|f)?\s*\|", output, re.MULTILINE)
    require(len(rows) == INVARIANT_COUNT and [int(row[0]) for row in rows] == list(range(1, INVARIANT_COUNT + 1)),
            f"Missing/incomplete invariant inventory: expected {INVARIANT_COUNT} assertions")
    names = [name.strip() for _, name, _ in rows]
    require(len(set(names)) == len(names), "Duplicate invariant names")
    required = {
        "all three explicit Astra writing seats keep their 0030/0034 paid-plan gates",
        "no gpt-6-astra row is reachable on the free, trial or new Pro tier",
        "plan_entitlements match current paid/trial/free catalog for every metered feature",
        "org_entitlement on a fitness trial org is the single-location free week (0/5/0/0/0, 1 seat, 500¢)",
    }
    require(required.issubset(names), "Required paid-plan/entitlement gates absent")
    failed = [name.strip() for _, name, passed in rows if passed != "t"]
    require((not failed and exit_code == 0 and f"All {INVARIANT_COUNT} invariants passed." in output)
            or (failed and exit_code == 3 and f"INVARIANTS FAILED: {len(failed)} assertion(s)" in output),
            "Invariant exit/status disagrees with actual assertions")
    return names, failed


def main():
    root = Path(__file__).resolve().parents[2]
    require(not subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True).strip(),
            "Checkpoint a clean source tree before database verification")
    environment = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": "C", "TZ": "UTC"}
    bins = {name: shutil.which(name) for name in ("initdb", "pg_ctl", "psql", "createdb")}
    require(all(bins.values()), "Use an already installed PostgreSQL distribution")
    evidence_parent = Path(os.environ.get("RENDP_AUDIT_EVIDENCE_DIR", "/tmp"))
    evidence_parent.mkdir(parents=True, exist_ok=True)
    require(shutil.disk_usage(evidence_parent).free >= 1024**3,
            "Less than 1 GiB available on the evidence filesystem")
    if evidence_parent.resolve() == Path("/tmp").resolve():
        out = Path(tempfile.mkdtemp(prefix="rendprop-db-audit-", dir="/tmp"))
    else:
        # The negative SQL fixtures intentionally require this owned /tmp
        # pathname. Keep it as a short symlink while all cluster bytes and
        # evidence live on the external volume.
        external = Path(tempfile.mkdtemp(prefix="rendprop-db-audit-", dir=evidence_parent))
        out = Path(tempfile.mkdtemp(prefix="rendprop-db-audit-", dir="/tmp"))
        out.rmdir()
        out.symlink_to(external, target_is_directory=True)
    data, sockets = out / "cluster", out / "socket"
    sockets.mkdir(mode=0o700)
    receipt = {"sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
               "startedAt": datetime.now(timezone.utc).isoformat(), "evidence": str(out), "commands": [],
               "network": "Unix socket only; listen_addresses empty", "accepted": False,
               "limits": ["Plain local Postgres, not hosted Supabase", "Minimal synthetic auth schema",
                          "No actual JWT verification or HTTP Data API", "No deployed cron verification"]}
    sqlroot = root / "services/supabase"
    migrations = sorted((sqlroot / "migrations").glob("*.sql"))
    schema_migrations, live_state_migrations = partition_fresh_migrations(migrations)
    sources = migrations + list(sorted((sqlroot / "tests").glob("*.sql"))) + [Path(__file__).resolve()]
    receipt["sourceHashes"] = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    receipt["liveStateOnlyMigrations"] = [str(p.relative_to(root)) for p in live_state_migrations]
    print("EVIDENCE:", out, flush=True)

    def run(name, command, expected=0, input_text=None):
        timed_out = False
        try:
            result = subprocess.run(command, env=environment, cwd=root, input=input_text, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
            output, code = result.stdout, result.returncode
        except subprocess.TimeoutExpired as error:
            output = error.stdout or ""
            if isinstance(output, bytes):
                output = output.decode("utf-8", errors="replace")
            code, timed_out = None, True
        log = out / (name + ".log")
        log.write_text(output)
        receipt["commands"].append({"name": name, "command": command, "exit": code, "timedOut": timed_out,
                                    "log": str(log), "logSHA256": hashlib.sha256(log.read_bytes()).hexdigest()})
        require(not timed_out, f"{name} timed out; partial output retained in {log}")
        allowed = expected if isinstance(expected, tuple) else (expected,)
        require(code in allowed, f"{name} exited {code}, expected {expected}; see {log}")
        print(name + ": exit=" + str(code), flush=True)
        return output

    connection = ["-h", str(sockets), "-p", "55439", "-U", "postgres"]
    psql = [bins["psql"], "-X", "--no-password", *connection, "-d", "rendprop_audit",
            "-v", "ON_ERROR_STOP=1"]
    audit_psql = psql
    started = False
    prior_handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGHUP)}
    def interrupted(signum, _frame):
        raise RuntimeError(f"Audit interrupted by signal {signum}")
    for sig in prior_handlers:
        signal.signal(sig, interrupted)
    try:
        run("version", [bins["psql"], "--version"])
        run("initdb", [bins["initdb"], "-D", str(data), "-U", "postgres", "-A", "trust",
                       "--no-locale", "--encoding=UTF8"])
        run("start", [bins["pg_ctl"], "-D", str(data), "-l", str(out / "postgres.log"), "-w", "-t", "30",
                      "-o", f"-k {sockets} -p 55439 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=20", "start"])
        started = True
        run("createdb", [bins["createdb"], "--no-password", *connection, "rendprop_audit"])
        identity = run("identity", psql + ["-Atc", "select current_setting('data_directory'),current_setting('listen_addresses'),current_database();"])
        require(identity.strip() == f"{data}||rendprop_audit", "Cluster identity/network mismatch")
        environment["PGOPTIONS"] = "-c statement_timeout=30000 -c lock_timeout=5000"
        run("bootstrap", psql + ["-q", "-f", str(sqlroot / "tests/ci-bootstrap.sql")])
        # Recreate the live ledger order in a separate database: the index
        # writer grant shipped before this forward-dated reservation migration.
        # The focused fixture proves old bare links, duplicate publication,
        # new unclaimed links, and deletion tombstones without production data.
        run("createdb-address-cutover", [bins["createdb"], "--no-password", *connection,
                                      "rendprop_address_cutover"])
        address_psql = [bins["psql"], "-X", "--no-password", *connection,
                        "-d", "rendprop_address_cutover", "-v", "ON_ERROR_STOP=1"]
        run("address-cutover-setup", address_psql + ["-q", "-f",
            str(sqlroot / "tests/property_address_reservations_setup.sql")])
        for filename in ("20261026175227_public_property_address_lookup.sql",
                         "20261027032646_property_address_index_writer_execute.sql",
                         "20261027040000_property_address_reservations.sql"):
            run("address-cutover-apply-" + filename.removesuffix(".sql"),
                address_psql + ["-q", "-f", str(sqlroot / "migrations" / filename)])
        address_assert = run("address-cutover-assert", address_psql + ["-f",
            str(sqlroot / "tests/property_address_reservations_assert.sql")])
        require("address reservation database checks passed" in address_assert,
                "Address cutover fixture did not complete")
        receipt["addressCutoverFixture"] = {"passed": True, "database": "rendprop_address_cutover",
            "liveLedgerOrder": True, "syntheticOnly": True,
            "checks": ["claimed bare", "new unique fenced", "duplicate address",
                       "address correction", "withdrawal", "deletion tombstone", "ACL"]}
        for migration in schema_migrations:
            run("apply-" + migration.stem, psql + ["-q", "-1", "-f", str(migration)])
        counts = []
        receipt["invariantRuns"] = []
        receipt["reflectionFixtures"] = []
        for phase in ("initial", "replayed"):
            if phase == "replayed":
                # Reapply each historical version where it actually existed.
                # Replaying0050 against0051's replacement overload is not a
                # supported production migration order; do not rewrite history
                # merely to make that artificial state accept old SQL.
                run("createdb-replay", [bins["createdb"], "--no-password", *connection, "rendprop_replay"])
                psql = [bins["psql"], "-X", "--no-password", *connection, "-d", "rendprop_replay",
                        "-v", "ON_ERROR_STOP=1"]
                run("bootstrap-replay", psql + ["-q", "-f", str(sqlroot / "tests/ci-bootstrap.sql")])
                replay = []
                guarded_refusals = []
                for migration in schema_migrations:
                    run("historical-" + migration.stem, psql + ["-q", "-1", "-f", str(migration)])
                    if migration.name in GUARDED_ONE_SHOT_MIGRATIONS:
                        expected_refusal = GUARDED_ONE_SHOT_MIGRATIONS[migration.name][1]
                        rejected = run("reject-" + migration.stem,
                                       psql + ["-q", "-1", "-f", str(migration)], expected=3)
                        require(expected_refusal in rejected,
                                f"{migration.name} refused for a reason other than its pinned first refusal")
                        guarded_refusals.append(migration.name)
                    elif replayable_migration(migration.name):
                        run("replay-" + migration.stem, psql + ["-q", "-1", "-f", str(migration)])
                        replay.append(migration)
                receipt["replayedMigrations"] = len(replay)
                receipt["guardedOneShotRefusals"] = guarded_refusals
                receipt["singleApplicationMigrations"] = sorted(SINGLE_APPLICATION_MIGRATIONS)
                receipt["replayMode"] = "second clean database; each replayable migration twice at its historical schema point"
            for filename, marker, assertion_count in REFLECTION_FIXTURES:
                fixture = sqlroot / "tests" / filename
                require(fixture in sources, "Required reflection fixture missing from source receipt")
                reflection = run("reflection-" + phase + "-" + fixture.stem,
                                 psql + ["-f", str(fixture)])
                require(marker in reflection, f"{filename} did not complete its {assertion_count} assertions")
                receipt["reflectionFixtures"].append({"phase": phase, "fixture": filename,
                    "assertions": assertion_count, "rolledBack": True,
                    "database": psql[psql.index("-d") + 1]})
            output = run("invariants-" + phase, psql + ["-f", str(sqlroot / "tests/invariants.sql")], expected=(0, 3))
            # Preserve a genuine red suite, but still test migration replay.
            # A SQL/load error is not a completed red suite and aborts here.
            exit_code = receipt["commands"][-1]["exit"]
            names, failed_names = invariant_rows(output, exit_code)
            if receipt["invariantRuns"]:
                require(names == receipt["invariantRuns"][0]["names"], "Assertion identities changed on replay")
            kept, unexpected, stale = classify_failures(names, failed_names)
            if kept:
                announce_kept_red(phase, names, kept)
            receipt["invariantRuns"].append({"phase": phase, "count": len(names), "names": names, "failed": failed_names,
                                             "keptRedFailures": kept, "unexpectedFailures": unexpected,
                                             "staleKeptRed": stale})
            counts.append(len(names))
        require(counts[0] == counts[1], "Invariant count changed on replay")
        # Destructive negative fixtures deliberately accept only the original
        # owned audit database. Restore that connection after replay inventory
        # checks; do not weaken the fixtures' independent database-name guard.
        psql = audit_psql
        paid = run("negative-paid-gates", psql + ["-f", str(sqlroot / "tests/negative_astra_paid_gates.sql")])
        require("PASS: exact paid-plan predicates registered 6 expected outcomes across baseline and 2 negative fixtures; all mutations rolled back." in paid,
                "Paid gate negative fixture did not complete")
        receipt["paidGateNegativeControl"] = {"outcomes": 6, "fixtures": 2, "rolledBack": True}
        # The HTTP/Python mocks cannot prove a Postgres publication fence. Run
        # the real transaction/trigger fixtures, then deliberately remove each
        # relevant guard in THIS owned disposable database. A missing guard
        # must fail for the intended invariant, not merely a syntax/ACL error.
        publication_specs = [
            ("worker", "worker_publish_transaction.sql", "0035_worker_publish_transaction.sql",
             "WORKER_PUBLISH_TRANSACTION_PASS_22", "stale A accepted", 22),
            ("uploads", "negative_upload_publication.sql", "0036_upload_publication_immutability.sql",
             "PASS: 19 upload publication trigger checks; all synthetic mutations rolled back.",
             "Missing publication rejection: completed: uploaded = false", 19),
        ]
        receipt["publicationFixtures"] = []
        for name, fixture, migration_name, marker, failure, count in publication_specs:
            script = sqlroot / "tests" / fixture
            migration = sqlroot / "migrations" / migration_name
            require(script in sources and migration in sources, "Required publication sources missing from receipt")
            output = run("publication-" + name, psql + ["-f", str(script)])
            require(marker in output, f"{name} publication fixture did not finish")
            if name == "worker":
                mutant = migration.read_text()
                for guard in ("or v_job.worker_id is distinct from p_worker",
                              "or v_job.attempts is distinct from p_attempt"):
                    require(mutant.count(guard) == 1, "Worker mutation no longer matches one exact ownership guard")
                    mutant = mutant.replace(guard, "or false /* deliberate isolated ownership mutant */")
                run("mutate-publication-worker", psql, input_text=mutant)
            else:
                run("mutate-publication-uploads", psql + ["-c",
                    "alter table public.capture_assets disable trigger trg_capture_asset_publication;"])
            broken = run("negative-publication-" + name, psql + ["-f", str(script)], expected=3)
            require(failure in broken, f"{name} negative fixture failed for an unexpected reason")
            run("restore-publication-" + name, psql + ["-q", "-1", "-f", str(migration)])
            restored = run("restored-publication-" + name, psql + ["-f", str(script)])
            require(marker in restored, f"{name} publication fixture failed after restoring the source migration")
            receipt["publicationFixtures"].append({"name": name, "checksPerRun": count,
                "runs": 2, "negativeControlDetected": True, "sourceRestored": True})
            if name == "worker":
                guards = [
                    ("video", [("and a.kind = 'video' and a.uploaded", "and a.uploaded")],
                     "photo capture accepted as raw video"),
                    ("scalars", [(line, "") for line in (
                        "     or jsonb_typeof(p_render->'duration_s') is distinct from 'number'\n",
                        "     or jsonb_typeof(p_render->'speed_factor') is distinct from 'number'\n",
                        "     or round(v_duration, 2) is distinct from v_duration\n",
                        "     or round(v_speed, 2) is distinct from v_speed\n")],
                     "noncanonical scalar accepted:"),
                ]
                receipt["workerInputNegativeControls"] = []
                for guard_name, replacements, reason in guards:
                    mutant = migration.read_text()
                    for old, new in replacements:
                        require(mutant.count(old) == 1, f"{guard_name} mutation no longer matches exactly")
                        mutant = mutant.replace(old, new)
                    mutant += f"\n-- deliberate isolated worker-{guard_name} mutant\n"
                    run("mutate-worker-" + guard_name, psql, input_text=mutant)
                    broken = run("negative-worker-" + guard_name, psql + ["-f", str(script)], expected=3)
                    require(reason in broken, f"{guard_name} negative failed for the wrong reason")
                    run("restore-worker-" + guard_name, psql + ["-q", "-1", "-f", str(migration)])
                    restored = run("restored-worker-" + guard_name, psql + ["-f", str(script)])
                    require(marker in restored, f"{guard_name} restored fixture did not finish")
                    receipt["publicationFixtures"][-1]["runs"] += 1
                    receipt["workerInputNegativeControls"].append({"guard": guard_name,
                        "detected": True, "sourceRestored": True})
        # Break actual entitlement data in this synthetic database. A gate that
        # only prints results must not pass when the published contract is false.
        run("mutate-negative", psql + ["-c", "update public.plan_entitlements set seats=999 where plan='team';"])
        failed = run("negative-invariants", psql + ["-f", str(sqlroot / "tests/invariants.sql")], expected=3)
        require("INVARIANTS FAILED:" in failed, "Negative control failed for the wrong reason")
        require(re.search(r"plan_entitlements match[^\n]*\| f\s+\|[^\n]*team", failed),
                "Negative control did not detect the deliberately corrupted team entitlement")
        require(all(hashlib.sha256(p.read_bytes()).hexdigest() == receipt["sourceHashes"][str(p.relative_to(root))]
                    for p in sources), "SQL sources changed during run")
        # Only the documented kept-red set may be red. Anything else failing,
        # or a kept-red entry that has quietly started passing, is a real
        # result the receipt must not paper over.
        stale_kept_red = sorted({name for phase in receipt["invariantRuns"] for name in phase["staleKeptRed"]})
        receipt.update({"accepted": all(not phase["unexpectedFailures"] for phase in receipt["invariantRuns"])
                                    and not stale_kept_red,
                        "keptRed": sorted(KEPT_RED),
                        "keptRedFailures": sorted({name for phase in receipt["invariantRuns"] for name in phase["keptRedFailures"]}),
                        "staleKeptRed": stale_kept_red,
                        "appliedMigrations": len(schema_migrations),
                        "reviewedMigrations": len(migrations), "invariantsEachRun": counts[0],
                        "negativeControl": "Actual team entitlement corrupted; real invariant gate exited 3"})
    except BaseException as error:
        receipt.update({"accepted": False, "failure": f"{type(error).__name__}: {error}"})
        raise
    finally:
        try:
            if started or (data / "postmaster.pid").exists():
                run("stop", [bins["pg_ctl"], "-D", str(data), "-w", "-t", "30", "-m", "fast", "stop"])
            receipt["clusterStopped"] = not (data / "postmaster.pid").exists()
            require(receipt["clusterStopped"], "Owned cluster still has a PID file after stop")
        except BaseException as error:
            receipt.update({"accepted": False, "cleanupFailure": f"{type(error).__name__}: {error}"})
            raise
        finally:
            for sig, handler in prior_handlers.items():
                signal.signal(sig, handler)
            receipt["finishedAt"] = datetime.now(timezone.utc).isoformat()
            (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    if receipt.get("staleKeptRed"):
        require(False, "Kept-red assertions now pass; remove them from KEPT_RED in the same change: "
                       + ", ".join(receipt["staleKeptRed"]))
    unexpected = sorted({name for phase in receipt["invariantRuns"] for name in phase["unexpectedFailures"]})
    require(receipt["accepted"], "Database assertions remain red outside the documented kept-red set ("
                                 + ", ".join(unexpected) + f"); full replay/negative evidence: {out / 'receipt.json'}")
    kept = receipt["keptRedFailures"]
    print("PASS: migrations, replay, actual invariants and negative control;", out / "receipt.json", flush=True)
    if kept:
        print(f"PASS WITH {len(kept)} KEPT-RED ASSERTION(S) still failing by owner decision: " + "; ".join(kept), flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("FAIL:", type(error).__name__, str(error), flush=True)
        sys.exit(1)
