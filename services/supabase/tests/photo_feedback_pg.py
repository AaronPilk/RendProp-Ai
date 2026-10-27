#!/usr/bin/env python3
"""Disposable real-PG proof of the AI photo feedback loop
(migrations/20261017200000_photo_output_feedback.sql).

Owned socket-only cluster on port 55741. No network, no providers, no hosted
database, no inherited credentials. Proves, against the actual final schema:
first-apply boundary (no historical DML, no foreign object changed), the
fixture on fresh and replayed schemas, the existing photo/gallery publication
fixtures on the same cluster, compiled negative controls for every guard,
real concurrent offline resends, and the rollback returning the catalog to
the exact pre-migration boundary followed by a clean re-apply.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
from threading import Barrier
import argparse, datetime, hashlib, json, os, re, shutil, signal, subprocess, sys, tempfile, time

os.umask(0o077)
ROOT = Path(__file__).resolve().parents[3]
SQL = ROOT / "services/supabase"
parser = argparse.ArgumentParser()
parser.add_argument("--evidence-dir", type=Path, required=True)
OUT = parser.parse_args().evidence_dir.resolve()
OUT.mkdir(parents=True, exist_ok=False)
OUT.chmod(0o700)
PORT = "55741"
DB = "photo_feedback_proof"
EXPECTED_ASSERTIONS = 119
DEADLINE = time.monotonic() + 1500
EXTERNAL = Path("/Volumes/Rendprop Files")
MIG = SQL / "migrations/20261017200000_photo_output_feedback.sql"
FIX = SQL / "tests/photo_feedback.sql"
ROLLBACK = SQL / "tests/fixtures/photo_output_feedback_rollback.sql"
MIGRATIONS = sorted((SQL / "migrations").glob("*.sql"))
assert MIG in MIGRATIONS, "Photo feedback migration missing"
SCHEMA_MIGRATIONS = partition_fresh_migrations(MIGRATIONS)[0]
# Existing photo-quality/gallery publication fixtures that must keep passing
# on the same migrated cluster: (file, required database name, minimum count).
EXISTING = [
    ("studio_photo_history.sql", None, 1),
    ("photo_output.sql", None, 1),
    ("native_photo_family_selection.sql", "native_selection_proof", 44),
    ("studio_explicit_listing_gallery.sql", "studio_explicit_gallery_proof", 30),
    ("studio_gallery_source_copy.sql", "gallery_copy_proof", 35),
]
SOURCES = [*MIGRATIONS, SQL / "tests/ci-bootstrap.sql", FIX, ROLLBACK, *[SQL / "tests" / name for name, _, _ in EXISTING], Path(__file__).resolve()]
OWN_FUNCTIONS = ["photo_quality_set_recipe", "photo_feedback_resolve", "photo_feedback_attribution", "photo_feedback_submit", "photo_feedback_signal",
                 "photo_feedback_state", "photo_regression_case_mark", "photo_regression_cases_for_review", "photo_feedback_report"]
OWN_TABLES = ["photo_output_feedback", "photo_output_signals", "photo_regression_cases"]
OWN_CHECKS = ["photo_edit_evidence_recipe_revision_check", "photo_edit_evidence_prompt_sha256_check", "photo_edit_evidence_recipe_pair_check"]


def reserve():
    if sys.platform == "darwin":
        assert EXTERNAL.is_mount(), "External evidence volume must be mounted"
        assert OUT.is_relative_to(EXTERNAL), "Keep local database evidence on the external volume"
        assert shutil.disk_usage(Path.home()).free >= 3 * 1024**3, "Preserve internal 3 GiB reserve"
        assert shutil.disk_usage(EXTERNAL).free >= 8 * 1024**3, "Preserve external 8 GiB reserve"
    else:
        assert shutil.disk_usage(OUT).free >= 1024**3, "Preserve isolated evidence reserve"
    assert time.monotonic() < DEADLINE, "Whole proof deadline"


reserve()
ENV = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": "C", "TZ": "UTC", "PGOPTIONS": "-c statement_timeout=60000 -c lock_timeout=15000"}
pg_config = shutil.which("pg_config", path=ENV["PATH"])
if pg_config:
    bindir = subprocess.check_output([pg_config, "--bindir"], text=True, env=ENV, timeout=10).strip()
    assert Path(bindir).is_absolute() and Path(bindir).is_dir(), "PostgreSQL tool directory is required"
    ENV["PATH"] = bindir + os.pathsep + ENV["PATH"]
tool = lambda name: shutil.which(name, path=ENV["PATH"])
assert all(tool(name) for name in ["initdb", "pg_ctl", "createdb", "psql"]), "PostgreSQL tools must already be installed"
DATA = Path(tempfile.mkdtemp(prefix="photo-feedback-owned-pg-", dir=OUT))
SOCK = Path(tempfile.mkdtemp(prefix="photo-feedback-sock-", dir="/tmp"))
hashes = lambda: {str(f.relative_to(ROOT)): hashlib.sha256(f.read_bytes()).hexdigest() for f in SOURCES}
r = {"passed": False, "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(), "sourceHashes": hashes(), "migrationsApplied": len(SCHEMA_MIGRATIONS),
     "commands": [], "controls": [], "races": [], "existingFixtures": [], "networkCalls": 0, "providerCalls": 0,
     "runtime": {"platform": sys.platform, "python": sys.version, "postgresTools": {name: tool(name) for name in ["initdb", "pg_ctl", "createdb", "psql"]}, "port": PORT}}
started = False


def terminate(_signal, _frame):
    raise SystemExit("Stopped by outer resource/wall guard")


signal.signal(signal.SIGTERM, terminate)


def run(name, command, body=None, refuses=None, check=True):
    reserve()
    child = subprocess.Popen([str(x) for x in command], stdin=subprocess.PIPE, text=True, env=ENV, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        end = time.monotonic() + 300
        while True:
            try:
                output, _ = child.communicate(input=body, timeout=.5)
                break
            except subprocess.TimeoutExpired:
                body = None
                reserve()
                assert time.monotonic() < end, "Command deadline"
    except BaseException as failure:
        child.kill()
        try:
            output, _ = child.communicate(timeout=5)
        except subprocess.TimeoutExpired as drain:
            output = drain.output or ""
            if isinstance(output, bytes): output = output.decode("utf-8", "replace")
            for pipe in [child.stdin, child.stdout, child.stderr]:
                if pipe is not None: pipe.close()
            child.wait(timeout=5)
        f = OUT / (name + ".log")
        f.write_text(output)
        r["commands"].append({"name": name, "exit": child.returncode, "failure": type(failure).__name__, "logSHA256": hashlib.sha256(f.read_bytes()).hexdigest()})
        raise
    f = OUT / (name + ".log")
    f.write_text(output)
    r["commands"].append({"name": name, "exit": child.returncode, "logSHA256": hashlib.sha256(f.read_bytes()).hexdigest()})
    if check:
        assert (child.returncode and refuses in output) if refuses else child.returncode == 0, (name, output[-4000:])
    return output if check else (child.returncode, output)


def fixture_result(output, label):
    rows = [json.loads(line) for line in output.splitlines() if line.startswith('{') and '"assertions"' in line]
    assert len(rows) == 1 and rows[0]["passed"] is True, (label, rows)
    return rows[0]


CATALOG = """select jsonb_build_object(
 'functions',(select md5(string_agg(jsonb_build_array(p.oid::regprocedure::text,md5(p.prosrc),pg_get_userbyid(p.proowner),p.prosecdef,p.provolatile,p.proconfig,p.proacl::text)::text,E'\\n'order by p.oid::regprocedure::text))
   from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind in('f','p')and p.proname<>all(array[%(fns)s])),
 'constraints',(select md5(string_agg(conrelid::regclass::text||':'||conname||':'||pg_get_constraintdef(c.oid),E'\\n'order by conrelid::regclass::text,conname))
   from pg_constraint c join pg_class t on t.oid=c.conrelid where c.connamespace='public'::regnamespace and t.relname<>all(array[%(tables)s])and c.conname<>all(array[%(checks)s])),
 'columns',(select md5(string_agg(t.relname||'.'||a.attname||':'||format_type(a.atttypid,a.atttypmod)||':'||a.attnotnull::text||':'||a.atthasdef::text,E'\\n'order by t.relname,a.attnum))
   from pg_attribute a join pg_class t on t.oid=a.attrelid where t.relnamespace='public'::regnamespace and t.relkind='r'and a.attnum>0 and not a.attisdropped
   and t.relname<>all(array[%(tables)s])and not(t.relname='photo_edit_evidence'and a.attname in('recipe_revision','prompt_sha256'))),
 'relations',(select md5(string_agg(c.relname||':'||c.relkind::text||':'||c.relrowsecurity::text||':'||coalesce(c.relacl::text,''),E'\\n'order by c.relname))
   from pg_class c where c.relnamespace='public'::regnamespace and c.relname!~'^(photo_output_feedback|photo_output_signals|photo_regression_cases)'),
 'triggers',(select md5(string_agg(tgrelid::regclass::text||':'||tgname||':'||tgenabled::text,E'\\n'order by tgrelid::regclass::text,tgname))from pg_trigger where not tgisinternal),
 'policies',(select md5(string_agg(polrelid::regclass::text||':'||polname||':'||pg_get_expr(polqual,polrelid),E'\\n'order by polrelid::regclass::text,polname))from pg_policy),
 'config',(select md5(string_agg(to_jsonb(t)::text,E'\\n'order by key))from app_config t),
 'routes',(select md5(string_agg(to_jsonb(t)::text,E'\\n'order by id))from ai_routes t));""" % {
    "fns": ",".join("'%s'" % x for x in OWN_FUNCTIONS), "tables": ",".join("'%s'" % x for x in OWN_TABLES), "checks": ",".join("'%s'" % x for x in OWN_CHECKS)}
OWN_ABSENT = """select to_regclass('public.photo_output_feedback')is null and to_regclass('public.photo_output_signals')is null and to_regclass('public.photo_regression_cases')is null
 and not exists(select 1 from pg_proc where pronamespace='public'::regnamespace and proname=any(array[%s]))
 and not exists(select 1 from pg_attribute where attrelid='public.photo_edit_evidence'::regclass and attname in('recipe_revision','prompt_sha256')and not attisdropped)
 and not exists(select 1 from pg_constraint where conname=any(array[%s]));""" % (",".join("'%s'" % x for x in OWN_FUNCTIONS), ",".join("'%s'" % x for x in OWN_CHECKS))
EVIDENCE = "select md5(coalesce(string_agg((to_jsonb(e)-'recipe_revision'-'prompt_sha256')::text,E'\\n'order by id),''))from photo_edit_evidence e;"
DATA_DIGEST = """select jsonb_build_object('ledger',(select md5(coalesce(string_agg(l::text,E'\\n'order by l.id),''))from cost_ledger l),
 'holds',(select md5(coalesce(string_agg(h::text,E'\\n'order by h.id),''))from serving_cost_reservations h),
 'provenance',(select md5(coalesce(string_agg(p::text,E'\\n'order by p.id),''))from media_provenance p),
 'operations',(select md5(coalesce(string_agg(s::text,E'\\n'order by s::text),''))from serving_operations s),
 'evidence',(select md5(coalesce(string_agg((to_jsonb(e)-'recipe_revision'-'prompt_sha256')::text,E'\\n'order by id),''))from photo_edit_evidence e));"""

try:
    run("initdb", [tool("initdb"), "-D", DATA, "-U", "postgres", "-A", "trust", "--no-locale", "--encoding=UTF8"])
    run("start", [tool("pg_ctl"), "-D", DATA, "-l", OUT / "postgres.log", "-w", "-o", f"-k {SOCK} -p {PORT} -c listen_addresses='' -c shared_buffers=16MB", "start"])
    started = True
    conn = ["-h", SOCK, "-p", PORT, "-U", "postgres"]
    run("createdb", [tool("createdb"), *conn, DB])
    psql = lambda db=DB: [tool("psql"), "-X", "--no-password", *conn, "-d", db, "-v", "ON_ERROR_STOP=1"]
    PSQL = psql()
    query = lambda name, text, refuses=None, db=DB: run(name, [*psql(db), "-Atq"], text, refuses)
    assert query("owned-cluster-identity", "select current_setting('data_directory'),current_setting('listen_addresses');").strip() == str(DATA) + "|"
    run("bootstrap", [*PSQL, "-q", "-f", SQL / "tests/ci-bootstrap.sql"])
    for migration in SCHEMA_MIGRATIONS:
        if migration == MIG:
            assert query("own-objects-absent", OWN_ABSENT).strip() == "t"
            # A pre-feature generation committed before the migration: it must
            # come out byte-identical with explicitly unknown recipe columns.
            query("boundary-seed-user", "insert into auth.users(id,email,is_anonymous)values('f8310000-0000-4000-8000-000000000001','photo-feedback-boundary@fixture.invalid',false);")
            org = query("boundary-org", "select org_id from memberships where user_id='f8310000-0000-4000-8000-000000000001'and role='owner'limit 1;").strip()
            query("boundary-seed", f"""begin;
insert into listings(id,org_id,agent_id,address)values('f8310000-0000-4000-8000-000000000011','{org}','f8310000-0000-4000-8000-000000000001','Synthetic pre-feature property');
update app_config set value=jsonb_set(value,'{{enabled}}','true')where key='photo_quality';
set local role service_role;
select serving_operation_begin('f8310000-0000-4000-8000-000000000001','{org}','photo-fb:boundary','photo_edit',repeat('d',64));
select photo_quality_begin('f8310000-0000-4000-8000-000000000001','{org}','photo-fb:boundary','f8310000-0000-4000-8000-000000000011','declutter',null,null,
 '{{"sha256":"{'a' * 64}","bytes":60000,"mime":"image/jpeg","width":1024,"height":768}}'::jsonb,'[]'::jsonb);
commit;""")
            boundary = json.loads(query("before-own-boundary", CATALOG))
            evidence_before = query("boundary-evidence-before", EVIDENCE).strip()
        run("apply-" + migration.stem, [*PSQL, "-q", "-1", "-f", migration])
        if migration == MIG:
            assert json.loads(query("after-own-boundary", CATALOG)) == boundary, "Existing authority, config or routes changed"
            assert query("boundary-evidence-after", EVIDENCE).strip() == evidence_before, "Historical evidence changed"
            assert query("boundary-unknown-recipe", "select count(*)=1 and bool_and(recipe_revision is null and prompt_sha256 is null)from photo_edit_evidence;").strip() == "t"
            r["boundary"] = {"foreignCatalogUnchanged": True, "historicalEvidenceByteIdentical": True, "historicalRecipeUnknown": True}
    print("Fresh migration chain applied:", len(SCHEMA_MIGRATIONS), flush=True)
    final_boundary = json.loads(query("final-schema-foreign-catalog", CATALOG))
    for stage in ["fresh", "replay"]:
        if stage == "replay":
            run("replay-own", [*PSQL, "-q", "-1", "-f", MIG])
            assert json.loads(query("after-replay-boundary", CATALOG)) == final_boundary
        result = fixture_result(run(stage + "-fixture", [*PSQL, "-Atq", "-f", FIX]), stage)
        assert result["assertions"] == EXPECTED_ASSERTIONS, (stage, result)
        r[stage] = result
        print(stage, result, flush=True)
    # Existing photo-quality / gallery publication fixtures on this same cluster.
    for name, db, minimum in EXISTING:
        target = db or DB
        if db:
            run("template-" + db, [tool("createdb"), *conn, "-T", DB, db])
        out = run("existing-" + Path(name).stem, [*psql(target), "-Atq", "-f", SQL / "tests" / name])
        rows = [json.loads(line) for line in out.splitlines() if line.startswith('{') and '"assertions"' in line]
        assert len(rows) == 1 and rows[0]["passed"] is True and rows[0]["assertions"] >= minimum, (name, rows)
        r["existingFixtures"].append({"fixture": name, "database": target, "assertions": rows[0]["assertions"], "passed": True})
        print("existing", name, rows[0]["assertions"], flush=True)
    # Compiled negative controls: remove one actual guard at a time; the same
    # independent fixture must fail on the intended assertion; then restore.
    sig = {"resolve": "public.photo_feedback_resolve(uuid,uuid,uuid)", "submit": "public.photo_feedback_submit(uuid,uuid,uuid,text,text,integer,text,text[],text,text)",
           "recipe": "public.photo_quality_set_recipe(uuid,uuid,text,text)", "attribution": "public.photo_feedback_attribution(uuid,uuid)",
           "signal": "public.photo_feedback_signal(uuid,uuid,uuid,text,text,text,text)", "case": "public.photo_regression_case_mark(uuid,uuid,uuid,text,text,boolean,boolean)",
           "report": "public.photo_feedback_report(timestamptz,timestamptz)"}
    controls = [
        ("reader-write", "resolve", [("if c->>'can_write'is distinct from'true'then raise exception'RP403: A current editor of this library is required';end if;", "")], "a read-only member cannot record feedback"),
        ("selected-library", "resolve", [("or(p_selected<>m.org_id and p_selected is distinct from library)", "")], "wrong selected library is a 404"),
        ("accepted-only", "resolve", [("or e.state<>'accept'", "")], "an output awaiting its quality check is not rateable"),
        ("key-binding", "submit", [("if f.id is not null and f.provenance_id<>p_provenance then", "if false then")], "a feedback key is bound to one photo"),
        ("revision-conflict", "submit", [("if f.verdict<>p_verdict or f.reasons<>v_reasons or f.note is distinct from v_note then", "if false then")], "changed content needs a new revision"),
        ("exists-carries-verdict", "submit", [("'revision_count',f.revision_count,'verdict',f.verdict,'reasons',to_jsonb(f.reasons),'note',f.note);", "'revision_count',f.revision_count);")],
         "feedback_exists carries the stored verdict, reasons and note"),
        ("evidence-bytes", "submit", [("if e is not null and p_output_sha256 is not null and p_output_sha256 is distinct from e#>>'{output,sha256}'then", "if false then")], "bytes of the sibling version are refused"),
        ("recipe-before-dispatch", "recipe", [("if e.purpose<>'prospective'or e.output is not null or e.output_etag is not null or e.state not in('pending','input_ready')then", "if e.purpose<>'prospective'then")], "a recipe cannot be invented after the candidate exists"),
        ("historical-unknown", "attribution", [("'provider',e.generation_provider,", "'provider',coalesce(e.generation_provider,m.model_id),")], "historical output stays provenance-only with unknown provider, recipe and attempts"),
        ("signal-key", "signal", [("if g.provenance_id<>p_provenance or g.signal<>p_signal or g.detail is distinct from p_detail then", "if g.provenance_id<>p_provenance then")], "signal key cannot become another signal"),
        ("case-consent", "case", [("if not p_retain then raise exception'RP403: CONSENT Explicit permission to keep this photo for evaluation is required';end if;", "")], "retention needs explicit consent"),
        ("case-role", "case", [("if s->>'role'is null or s->>'role'not in('owner','admin')then", "if false then")], "an agent cannot keep an evaluation case"),
        ("settlement-once", "report", [("  union select a.id,a.evidence_id,l.id from att a join", "  union all select a.id,a.evidence_id,l.id from att a join"),
                                       ("  union select a.id,a.evidence_id,ev.qc_ledger_id from att a", "  union all select a.id,a.evidence_id,ev.qc_ledger_id from att a"),
                                       ("led as(select l.id,l.total_cents from public.cost_ledger l where l.id in(select ledger_id from lnk)),", "led as(select l.id,l.total_cents from lnk join public.cost_ledger l on l.id=lnk.ledger_id),")],
         "a settlement reached by binding, metadata and judge receipt is counted once"),
        ("rejected-no-liability", "report", [("open_att as(select a.* from att a where a.state<>'rejected'and not exists", "open_att as(select a.* from att a where not exists")], "uncertain and unsettled holds stay outstanding; historical output is unknown attribution"),
        ("contested-not-useful", "report", [("useful_out as(select evidence_id from rv where any_useful and not any_needs_work)", "useful_out as(select evidence_id from rv where any_useful)")], "explicit denominators: reviewable, reviewed, verdict rows and coverage are separate"),
        ("coverage-denominator", "report", [("round((select count(*)from rv)::numeric/count(*),4)end from ev where state='accept')", "round((select count(*)from rv)::numeric/count(*),4)end from ev)")], "explicit denominators: reviewable, reviewed, verdict rows and coverage are separate"),
        ("calibration-excluded", "report", [("where e.purpose='prospective'and e.created_at>=p_from", "where e.created_at>=p_from")], "generated counts every prospective generation by state and excludes calibration"),
    ]
    for label, key, edits, oracle in controls:
        original = query("read-" + label, f"select pg_get_functiondef('{sig[key]}'::regprocedure);")
        mutant = original
        for anchor, replacement in edits:
            assert mutant.count(anchor) == 1, (label, anchor)
            mutant = mutant.replace(anchor, replacement)
        query("compile-" + label, mutant)
        run("negative-" + label, [*PSQL, "-Atq", "-f", FIX], refuses=oracle)
        query("restore-" + label, original)
        r["controls"].append({"name": label, "compiledActualSQL": True, "oracle": oracle})
    for label, compile_sql, restore_sql, oracle in [
        ("direct-write-grant", "grant insert on public.photo_output_feedback to service_role;", "revoke insert on public.photo_output_feedback from service_role;", "service table writes revoked outside the RPCs"),
        ("rls-disabled", "alter table public.photo_output_signals disable row level security;", "alter table public.photo_output_signals enable row level security;", "feedback tables have RLS"),
        ("erasure-cascade", "alter table public.photo_output_feedback drop constraint photo_output_feedback_evidence_id_fkey,add constraint photo_output_feedback_evidence_id_fkey foreign key(evidence_id)references public.photo_edit_evidence(id);",
         "alter table public.photo_output_feedback drop constraint photo_output_feedback_evidence_id_fkey,add constraint photo_output_feedback_evidence_id_fkey foreign key(evidence_id)references public.photo_edit_evidence(id)on delete cascade;",
         "photo_output_feedback_evidence_id_fkey"),
    ]:
        query("compile-" + label, compile_sql)
        run("negative-" + label, [*PSQL, "-Atq", "-f", FIX], refuses=oracle)
        query("restore-" + label, restore_sql)
        r["controls"].append({"name": label, "compiledActualSQL": True, "oracle": oracle})
    # The own-replay guard now proves every control was restored exactly.
    run("replay-after-controls", [*PSQL, "-q", "-1", "-f", MIG])
    restored = fixture_result(run("restored-positive", [*PSQL, "-Atq", "-f", FIX]), "restored")
    assert restored["assertions"] == EXPECTED_ASSERTIONS
    for label, mutate, needle in [
        ("guard-foreign-helper", "create or replace function public.photo_regression_cases_for_review(p_recipe_revision text)returns jsonb language sql stable security definer set search_path='' as $$select '[]'::jsonb$$;", "Review changed photo feedback helper"),
        ("guard-foreign-relation", "alter table public.photo_output_signals add column extra text;", "Review changed photo feedback relation"),
        ("guard-foreign-evidence-check", "alter table public.photo_edit_evidence drop constraint photo_edit_evidence_recipe_pair_check;alter table public.photo_edit_evidence add constraint photo_edit_evidence_recipe_pair_check check(true);", "Review changed photo evidence recipe columns"),
    ]:
        # Each foreign object is refused by the replay guard inside a transaction that is rolled back.
        run("replay-refuses-" + label, [*PSQL, "-q"], "begin;\n" + mutate + "\n\\i " + str(MIG) + "\n", refuses=needle)
        r["controls"].append({"name": label, "replayGuardRefused": True, "oracle": needle})
    assert json.loads(query("after-guard-controls", CATALOG)) == final_boundary
    # Real concurrent offline resends against committed outputs.
    setup = FIX.read_text().split("-- BEGIN SETUP (reused verbatim by photo_feedback_pg.py for committed race fixtures)\n", 1)[1].split("-- END SETUP", 1)[0]
    setup = setup.replace("f8300000-", "f8320000-").replace("photo-feedback-", "photo-feedback-race-")
    query("race-setup", "begin;\n" + setup + """
set local role service_role;
create temp table rr as select pg_temp.generate('race1','declutter',null,'photo-recipe/2026-10-17.1','gemini','gemini-3.1-flash-image',0)p1,
 pg_temp.generate('race2','stage','modern','photo-recipe/2026-10-17.1','gemini','gemini-3.1-flash-image',0)p2;
grant select,update on rr to service_role;
select pg_temp.attempt(p1,'photo.declutter:0','succeeded',.0001),pg_temp.ledger(p1,'photo.declutter:0',.0004),pg_temp.attempt(p2,'photo.stage:0','succeeded',.0001),pg_temp.ledger(p2,'photo.stage:0',.0006)from rr;
update rr set p1=(pg_temp.judge(p1,pg_temp.verdict()))->'evidence',p2=(pg_temp.judge(p2,pg_temp.verdict()))->'evidence';
commit;""")
    ids = json.loads(query("race-ids", """select json_build_object('a','f8320000-0000-4000-8000-000000000001','e','f8320000-0000-4000-8000-000000000003',
 'o',(select org_id from listings where id='f8320000-0000-4000-8000-000000000011'),
 'p1',(select provenance_id from photo_edit_evidence where request_key='photo-fb:race1'and state='accept'),
 'p2',(select provenance_id from photo_edit_evidence where request_key='photo-fb:race2'and state='accept'));""").strip())
    assert all(ids.values()), ids

    def race(label, statements):
        barrier = Barrier(len(statements))

        def call(index):
            barrier.wait(timeout=20)
            return run(f"{label}-{index}", [*PSQL, "-Atq"], "set role service_role;" + statements[index], check=False)

        with ThreadPoolExecutor(max_workers=len(statements)) as pool:
            return list(pool.map(call, range(len(statements))))

    submit = lambda actor, prov, key, verdict="useful": f"select photo_feedback_submit('{actor}','{ids['o']}','{prov}',null,'{key}',1,'{verdict}','{{}}',null,'ios');"
    replies = race("race-same-body", [submit(ids["a"], ids["p1"], "k-race-same-01")] * 6)
    assert all(code == 0 for code, _ in replies), replies
    states = sorted(json.loads(next(l for l in out.splitlines() if l.startswith("{")))["state"] for _, out in replies)
    assert states == ["recorded"] + ["replayed"] * 5, states
    assert query("race-same-body-rows", f"select count(*)from photo_output_feedback where provenance_id='{ids['p1']}'and actor_id='{ids['a']}';").strip() == "1"
    r["races"].append({"name": "duplicate-offline-submissions", "concurrentSessions": 6, "rows": 1, "states": states})
    replies = race("race-new-keys", [submit(ids["a"], ids["p2"], f"k-race-dup-0{i}") for i in range(6)])
    assert all(code == 0 for code, _ in replies), replies
    bodies = [json.loads(next(l for l in out.splitlines() if l.startswith("{"))) for _, out in replies]
    winners = [b for b in bodies if b["state"] == "recorded"]
    winner_key = query("race-new-keys-winner", f"select client_key from photo_output_feedback where provenance_id='{ids['p2']}'and actor_id='{ids['a']}';").strip()
    assert len(winners) == 1 and all(b["state"] == "conflict" and b["code"] == "feedback_exists" and b["client_key"] == winner_key for b in bodies if b["state"] != "recorded"), bodies
    r["races"].append({"name": "competing-keys-one-output", "concurrentSessions": 6, "rows": 1, "conflictsAdoptWinnerKey": 5})
    replies = race("race-key-moves", [submit(ids["e"], ids["p1"] if i % 2 == 0 else ids["p2"], "k-race-move-01") for i in range(6)])
    bound = query("race-key-moves-row", "select provenance_id from photo_output_feedback where client_key='k-race-move-01';").strip().splitlines()
    assert len(bound) == 1, bound
    for i, (code, out) in enumerate(replies):
        same = (ids["p1"] if i % 2 == 0 else ids["p2"]) == bound[0]
        assert (code == 0) if same else (code != 0 and "FEEDBACK_KEY_CONFLICT" in out), (i, code, out[-500:])
    r["races"].append({"name": "one-key-two-outputs", "concurrentSessions": 6, "boundOutputs": 1, "otherOutputRefused": 3})
    signal_sql = f"select photo_feedback_signal('{ids['a']}','{ids['o']}','{ids['p1']}','s-race-same-01','export','download','ios');"
    replies = race("race-signal", [signal_sql] * 6)
    assert all(code == 0 for code, _ in replies) and query("race-signal-rows", "select count(*)from photo_output_signals where client_key='s-race-same-01';").strip() == "1"
    r["races"].append({"name": "duplicate-signals", "concurrentSessions": 6, "rows": 1})
    # Rollback: refuses to discard observations or a foreign helper unless
    # confirmed; then preserves all foreign final-schema objects.
    run("rollback-refuses-observations", [*PSQL, "-q", "-f", ROLLBACK], refuses="Rollback would discard")
    original = query("read-rollback-foreign", "select pg_get_functiondef('public.photo_feedback_state(uuid,uuid,uuid)'::regprocedure);")
    query("compile-rollback-foreign", original.replace("select*into c from public.photo_regression_cases where provenance_id=p_provenance;", "select*into c from public.photo_regression_cases where provenance_id=p_provenance and true;", 1))
    run("rollback-refuses-foreign-helper", [*PSQL, "-q"], "set rendprop.photo_feedback_rollback='discard-observations';\n\\i " + str(ROLLBACK) + "\n", refuses="Rollback refuses a changed photo feedback helper")
    query("restore-rollback-foreign", original)
    data_before = json.loads(query("rollback-data-before", DATA_DIGEST))
    run("rollback-confirmed", [*PSQL, "-q"], "set rendprop.photo_feedback_rollback='discard-observations';\n\\i " + str(ROLLBACK) + "\n")
    assert query("rollback-own-absent", OWN_ABSENT).strip() == "t"
    after_rollback = json.loads(query("rollback-catalog", CATALOG))
    for key in ["functions", "constraints", "columns", "relations", "triggers", "policies"]:
        assert after_rollback[key] == final_boundary[key], ("rollback catalog", key)
    assert json.loads(query("rollback-data-after", DATA_DIGEST)) == data_before, "Rollback touched evidence, provenance, operations, holds or ledger"
    r["rollback"] = {"refusedWithObservations": True, "refusedForeignHelper": True, "foreignCatalogEqualsFinalSchema": True, "authorityDataUnchanged": True}
    run("reapply-after-rollback", [*PSQL, "-q", "-1", "-f", MIG])
    again = fixture_result(run("fixture-after-reapply", [*PSQL, "-Atq", "-f", FIX]), "reapplied")
    assert again["assertions"] == EXPECTED_ASSERTIONS
    r["reapplied"] = again
    assert hashes() == r["sourceHashes"], "Consumed source changed during proof"
    r["passed"] = True
    print(json.dumps({"passed": True, "fresh": r["fresh"]["assertions"], "replay": r["replay"]["assertions"], "existingFixtures": len(r["existingFixtures"]),
                      "compiledControls": len(r["controls"]), "races": len(r["races"]), "rollback": r["rollback"], "reapplied": again["assertions"],
                      "migrations": len(SCHEMA_MIGRATIONS)}), flush=True)
finally:
    cleanup_error = None
    if started or (DATA / "postmaster.pid").exists():
        try:
            stop = subprocess.run([tool("pg_ctl"), "-D", str(DATA), "-m", "immediate", "-w", "stop"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=ENV, timeout=30)
            (OUT / "stop.log").write_text(stop.stdout)
            r["ownedClusterStopped"] = stop.returncode == 0
            if stop.returncode: cleanup_error = "Owned PostgreSQL cleanup failed"
        except BaseException as error:
            r["ownedClusterStopped"] = False
            cleanup_error = "Owned PostgreSQL cleanup failed: " + type(error).__name__
    if cleanup_error: r["passed"] = False
    r["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    (OUT / "receipt.json").write_text(json.dumps(r, indent=2) + "\n")
    if r.get("ownedClusterStopped") or not started and not (DATA / "postmaster.pid").exists():
        shutil.rmtree(DATA)
        shutil.rmtree(SOCK, ignore_errors=True)
    if cleanup_error: raise RuntimeError(cleanup_error)
