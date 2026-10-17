#!/usr/bin/env python3
"""Print the admin AI photo quality report from a clearly labeled SYNTHETIC
fixture dataset (tests/fixtures/photo_feedback_report_demo.sql).

Owned socket-only PostgreSQL cluster (port 55743) with every repo migration,
the shared synthetic helpers from tests/photo_feedback.sql and the demo
dataset. Zero provider calls, zero network, no hosted database. Writes, under
--out: report-30d.json and report-7d.json (exactly the body GET
/admin/photo-feedback returns), report-30d.txt (a readable rendering), receipt.json and logs/.
"""
from pathlib import Path
import argparse, datetime, hashlib, json, os, shutil, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[3]
SQL = ROOT / "services/supabase"
parser = argparse.ArgumentParser()
parser.add_argument("--out", type=Path, required=True)
OUT = parser.parse_args().out.resolve()
OUT.mkdir(parents=True, exist_ok=True)
PORT = "55743"
FIX = SQL / "tests/photo_feedback.sql"
DEMO = SQL / "tests/fixtures/photo_feedback_report_demo.sql"
MIGRATIONS = sorted((SQL / "migrations").glob("*.sql"))
ENV = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": "C", "TZ": "UTC", "PGOPTIONS": "-c statement_timeout=60000"}
pg_config = shutil.which("pg_config", path=ENV["PATH"])
if pg_config:
    ENV["PATH"] = subprocess.check_output([pg_config, "--bindir"], text=True, env=ENV).strip() + os.pathsep + ENV["PATH"]
tool = lambda name: shutil.which(name, path=ENV["PATH"])
assert all(tool(n) for n in ["initdb", "pg_ctl", "createdb", "psql"]), "PostgreSQL tools must already be installed"
LOGS = OUT / "logs"
LOGS.mkdir(exist_ok=True)
DATA = Path(tempfile.mkdtemp(prefix="photo-feedback-demo-pg-", dir=OUT))
SOCK = Path(tempfile.mkdtemp(prefix="photo-feedback-demo-sock-", dir="/tmp"))
receipt = {"passed": False, "synthetic": True, "providerCalls": 0, "networkCalls": 0, "migrations": len(MIGRATIONS),
           "sources": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [FIX, DEMO, Path(__file__).resolve()]}}
started = False


def run(name, cmd, body=None):
    p = subprocess.run([str(c) for c in cmd], input=body, text=True, env=ENV, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
    (LOGS / (name + ".log")).write_text(p.stdout)
    assert p.returncode == 0, (name, p.stdout[-3000:])
    return p.stdout


def pct(value):
    return "n/a (nothing to divide by)" if value is None else f"{float(value) * 100:.1f}%"


def cents(value):
    return "n/a" if value is None else f"{float(value):.4f}c"


def render(body):
    g, x, h, s, c, rc = body["generated"], body["explicit"], body["historical"], body["signals"], body["cost"], body["regression_cases"]
    lines = ["AI PHOTO QUALITY REPORT - SYNTHETIC DEMONSTRATION DATA (no customer data, no provider calls)",
             f"Window {body['window']}: {body['from']} to {body['to']}  (generated {body['generated_at']})",
             f"Data range: generations {body['data_range']['first_generated_at']} .. {body['data_range']['last_generated_at']}; "
             f"verdicts {body['data_range']['first_feedback_at']} .. {body['data_range']['last_feedback_at']}", "", "BASIS: " + body["basis"], "",
             f"Generated: {g['outputs']} (accepted {g['accepted']}, refused {g['refused']}, held {g['held']}, pending {g['pending']}; "
             f"calibration re-checks excluded: {g['excluded_calibration_checks']})",
             f"Reviewable (delivered) outputs: {x['reviewable_outputs']}; explicitly reviewed: {x['reviewed_outputs']} "
             f"(coverage {pct(x['coverage'])}); unreviewed: {x['unreviewed_outputs']} (not rejections)",
             f"Explicit verdicts: {x['feedback_rows']} from {x['reviewers']} reviewers -> Useful {x['useful']}, Needs work {x['needs_work']}; "
             f"useful rate {pct(x['useful_rate'])} among explicit verdicts only",
             f"Explicitly useful outputs: {x['explicitly_useful_outputs']}; contested (Useful and Needs work): {x['contested_outputs']}; revised verdicts: {x['revised_rows']}",
             f"Historical outputs (attribution unknown, excluded from every rate): {h['outputs']} with {h['feedback_rows']} verdicts "
             f"(Useful {h['useful']}, Needs work {h['needs_work']})", "",
             f"Signals (distinct outputs; never quality judgments): accuracy ack {s['accuracy_ack']}, manual selection {s['manual_selection']}, "
             f"automatic selection {s['automatic_selection']}, export {s['export']}, publication {s['publication']}; "
             f"signalled but not reviewed: {s['outputs_with_signal_and_no_feedback']}", "", "Needs-work reasons (most common first):"]
    for r in body["reasons"]:
        lines.append(f"  [{r['group']:8}] {r['reason']:40} {r['feedback_rows']:3} verdict{'' if r['feedback_rows'] == 1 else 's'} on {r['outputs']} output{'' if r['outputs'] == 1 else 's'}")
    ft = body["fidelity_vs_taste"]
    lines.append(f"  Needs-work verdicts {ft['needs_work_rows']}: with a property-fidelity reason {ft['with_fidelity_reason']}, "
                 f"taste only {ft['taste_only']}, other only {ft['other_only']}, taste and fidelity {ft['taste_and_fidelity']}")
    for title, key in [("By edit", "by_edit"), ("By provider/model", "by_provider_model"), ("By recipe revision", "by_recipe_revision")]:
        lines += ["", f"{title} (n = explicitly reviewed outputs; * = fewer than 30, too small to read as a rate):",
                  f"  {'key':42} {'gen':>4} {'deliv':>5} {'n':>3} {'useful':>6} {'needs':>5} {'rate':>7} {'attempts':>8} {'recorded':>12}"]
        for cell in body[key]:
            rate = "-" if cell["useful_rate"] is None else f"{float(cell['useful_rate']) * 100:.0f}%"
            lines.append(f"  {cell['key']:42} {cell['generated']:>4} {cell['reviewable']:>5} {cell['reviewed']:>3}{'*' if cell['small_sample'] else ' '}"
                         f"{cell['useful']:>5} {cell['needs_work']:>5} {rate:>7} {cell['attempts']:>8} {cents(cell['recorded_cents']):>12}")
    lines += ["", "Cost (internal modeled estimates, never supplier invoices):",
              f"  Attempts {c['attributable_attempts']} (succeeded {c['succeeded_attempts']}, rejected before work {c['failed_or_rejected_attempts']}, "
              f"uncertain after dispatch {c['uncertain_attempts']}, in flight {c['open_attempts']}; paid quality checks {c['judge_attempts']}; "
              f"outputs with retried steps {c['retried_outputs']})",
              f"  Recorded: {cents(c['recorded_cents'])} over {c['recorded_ledger_rows']} ledger rows; outstanding holds: {cents(c['outstanding_hold_cents'])} "
              f"on {c['unsettled_attempts']} attempts; unknown attribution outputs: {c['unknown_attribution_outputs']}",
              f"  Behind explicitly reviewed outputs: {c['reviewed_attempts']} attempts, {cents(c['reviewed_recorded_cents'])} recorded, "
              f"{cents(c['reviewed_outstanding_hold_cents'])} outstanding",
              f"  Per explicitly useful output ({c['explicitly_useful_outputs']}): {c['attempts_per_useful']} attempts, {cents(c['recorded_cents_per_useful'])} recorded, "
              f"{cents(c['outstanding_hold_cents_per_useful'])} outstanding; all window spend per useful (upper bound): {cents(c['window_recorded_cents_per_useful'])}",
              "  " + c["basis"], "",
              f"Regression cases (consented, all time): active {rc['active']}, withdrawn {rc['withdrawn']}; "
              f"by defect {[(d['key'], d['n']) for d in rc['by_defect']]}; by recipe {[(d['key'], d['n']) for d in rc['by_recipe_revision']]}", "",
              "SAMPLE NOTE: " + body["sample_note"]]
    return "\n".join(lines) + "\n"


try:
    run("initdb", [tool("initdb"), "-D", DATA, "-U", "postgres", "-A", "trust", "--no-locale", "--encoding=UTF8"])
    run("start", [tool("pg_ctl"), "-D", DATA, "-l", LOGS / "postgres.log", "-w", "-o", f"-k {SOCK} -p {PORT} -c listen_addresses='' -c shared_buffers=16MB", "start"])
    started = True
    conn = ["-h", SOCK, "-p", PORT, "-U", "postgres"]
    run("createdb", [tool("createdb"), *conn, "photo_feedback_demo"])
    PSQL = [tool("psql"), "-X", "--no-password", *conn, "-d", "photo_feedback_demo", "-v", "ON_ERROR_STOP=1"]
    run("bootstrap", [*PSQL, "-q", "-f", SQL / "tests/ci-bootstrap.sql"])
    for m in MIGRATIONS:
        run("apply-" + m.stem, [*PSQL, "-q", "-1", "-f", m])
    setup = FIX.read_text().split("-- BEGIN SETUP (reused verbatim by photo_feedback_pg.py for committed race fixtures)\n", 1)[1].split("-- END SETUP", 1)[0]
    setup = setup.replace("f8300000-", "f8600000-").replace("photo-feedback-", "photo-feedback-demo-")
    run("load-synthetic-demo", [*PSQL, "-q"], "begin;\n" + setup + "\n" + DEMO.read_text() + "\ncommit;\n")
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    for window, days in [("30d", 30), ("7d", 7)]:
        frm = now - datetime.timedelta(days=days)
        raw = run("report-" + window, [*PSQL, "-Atq"], f"set role service_role;select photo_feedback_report('{frm.isoformat()}','{now.isoformat()}');")
        report = json.loads(raw.strip().splitlines()[-1])
        # Exactly what GET /admin/photo-feedback returns (admin/photo-feedback.ts).
        body = {"generated_at": now.isoformat().replace("+00:00", ".000Z"), "window": window, **report}
        (OUT / f"report-{window}.json").write_text(json.dumps(body, indent=2) + "\n")
        if window == "30d":
            text = render(body)
            (OUT / "report-30d.txt").write_text(text)
            print(text)
            receipt["headline"] = {"generated": body["generated"]["outputs"], "reviewed": body["explicit"]["reviewed_outputs"], "coverage": body["explicit"]["coverage"],
                                   "useful_rate": body["explicit"]["useful_rate"], "recorded_cents_per_useful": body["cost"]["recorded_cents_per_useful"]}
    receipt["passed"] = True
finally:
    if started:
        subprocess.run([tool("pg_ctl"), "-D", str(DATA), "-m", "immediate", "-w", "stop"], env=ENV, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
    shutil.rmtree(DATA, ignore_errors=True)
    shutil.rmtree(SOCK, ignore_errors=True)
    receipt["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    (OUT / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
