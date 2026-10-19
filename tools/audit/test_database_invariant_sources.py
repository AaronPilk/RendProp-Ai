"""Source-wiring checks only: no database, sockets, credentials or SQL execution.

The actual SQL acceptance belongs to run_database_regression.py. These checks
catch dropped assertion registration and weakened contracts before that run.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
TESTS = ROOT / 'services/supabase/tests'
LABELS = (
    'all three explicit Astra writing seats keep their 0030/0034 paid-plan gates',
    'no gpt-6-astra row is reachable on the free or trial tier',
)


def require_registered(sql):
    # Labels contain no SQL-escaped apostrophe. Match the registration and
    # SELECT together: finding both somewhere in the file proves nothing.
    for label in LABELS:
        assert re.search(r"insert\s+into\s+_inv\(name,\s*pass,\s*note\)\s+select\s+'"
                         + re.escape(label) + r"'", sql, re.I), label


# The independent literal expectation matrix of the current catalog assertion.
# The per-plan contracts below are
# checked INSIDE this block only: the 0044 fixture repeats some of the same
# tuples further down the file, and a matrix edit must be caught even when a
# fixture literal still carries the old value.
MATRIX = re.compile(r"from \(values \('trial',.*?as x\(plan, renders, edits, reels, aerials, topaz, seats, cogs, price\)",
                    re.S)


def plan_matrix(sql):
    found = MATRIX.search(sql)
    assert found, 'plan expectation matrix missing'
    return found.group(0)


def require_contract(sql):
    assert 'ceiling > visible and ceiling <= 8000' in sql, 'reasoning headroom rule weakened'
    assert "when 'copy.agent_reel' then 500" in sql, 'agent-reel visible contract drifted'
    matrix = plan_matrix(sql)
    assert re.search(r"\('trial',\s*3,\s*20,\s*20,\s*2,\s*1,\s*1,\s*1500,\s*0\)", matrix)
    assert re.search(r"\('free',\s*1,\s*5,\s*0,\s*0,\s*0,\s*1,\s*300,\s*0\)", matrix)
    assert 'for v_n in 1..3 loop' in sql
    assert "'_inv-wrk-000004'" in sql
    assert "worker job #4 exceeds the trial cap (RP402)" in sql
    # 0044 retained tour/edit sizes and prices; the reviewed 20261014200302
    # migration changes shot allowances and ceilings for multi-photo videos.
    # The one-tour single-location trial override still applies. The matrix must keep stating
    # these literally — deriving them from the table would test nothing.
    assert re.search(r"\('starter',\s*4,\s*100,\s*30,\s*2,\s*0,\s*1,\s*2032,\s*4900\)", matrix), 'starter rework'
    assert re.search(r"\('solo',\s*4,\s*100,\s*30,\s*2,\s*0,\s*1,\s*2032,\s*4900\)", matrix), 'solo alias'
    assert re.search(r"\('pro',\s*10,\s*200,\s*60,\s*4,\s*0,\s*1,\s*4157,\s*9900\)", matrix), 'pro rework'
    assert re.search(r"\('team',\s*25,\s*400,\s*150,\s*8,\s*2,\s*2,\s*10532,\s*24900\)", matrix), 'team rework'
    assert re.search(r"\('trial',\s*1,\s*20,\s*20,\s*1,\s*1,\s*null::integer,\s*1500\)", sql), 'single-location trial override'
    assert "'_inv-fit-000002'" in sql
    assert "worker job #2 exceeds the single-location trial cap (RP402, 1 of 1)" in sql
    assert "log_job_cost enforces the current single-location trial ceiling (1500¢)" in sql
    assert "monthly AI spend ceiling reached for the trial plan (0¢ of 1500¢)" in sql


class DatabaseInvariantSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.invariants = (TESTS / 'invariants.sql').read_text()
        cls.gates = (TESTS / 'invariant_astra_paid_gates.sql').read_text()
        cls.negative = (TESTS / 'negative_astra_paid_gates.sql').read_text()

    def test_both_paid_gates_are_registered(self):
        require_registered(self.gates)

    def test_bare_select_negative_control_is_rejected(self):
        for label in LABELS:
            with self.subTest(label=label):
                mutant = self.gates.replace("insert into _inv(name, pass, note)\nselect '" + label,
                                            "select '" + label, 1)
                self.assertNotEqual(mutant, self.gates)
                with self.assertRaises(AssertionError):
                    require_registered(mutant)

    def test_current_trial_and_headroom_contracts_remain(self):
        require_contract(self.invariants)

    def test_weakened_headroom_negative_control_is_rejected(self):
        mutant = self.invariants.replace('ceiling > visible', 'ceiling >= visible', 1)
        self.assertNotEqual(mutant, self.invariants)
        with self.assertRaises(AssertionError):
            require_contract(mutant)

    def test_agent_reel_actual_contract_is_bound_to_sql(self):
        module = (ROOT / 'services/supabase/functions/ai-copy/agentreel.ts').read_text()
        handler = (ROOT / 'services/supabase/functions/ai-copy/index.ts').read_text()
        self.assertRegex(module, r'export const MAX_AGENT_REEL_TOKENS = 500;')
        self.assertRegex(module, r'export const MAX_AGENT_REEL_RESPONSE_BYTES = 500;')
        self.assertRegex(module, r'export const MAX_AGENT_REEL_CAPTION_BYTES = 240;')
        self.assertIn('new TextEncoder().encode(raw).byteLength > MAX_AGENT_REEL_RESPONSE_BYTES', module)
        self.assertIn('JSON.parse(raw)', module)
        self.assertIn('MAX_AGENT_REEL_TOKENS,', handler)
        self.assertEqual(handler.count('MAX_AGENT_REEL_TOKENS'), 3,
                         'one imported contract must feed both quote and adapter')
        self.assertNotRegex(handler, r'const MAX_AGENT_REEL_TOKENS\s*=')

    def test_stale_agent_reel_visible_expectation_is_rejected(self):
        mutant = self.invariants.replace("when 'copy.agent_reel' then 500",
                                          "when 'copy.agent_reel' then 700", 1)
        self.assertNotEqual(mutant, self.invariants)
        with self.assertRaises(AssertionError):
            require_contract(mutant)

    def test_old_trial_expectation_negative_control_is_rejected(self):
        mutant = re.sub(r"\('trial',\s*3,\s*20", "('trial', 1, 10", self.invariants, count=1)
        self.assertNotEqual(mutant, self.invariants)
        with self.assertRaises(AssertionError):
            require_contract(mutant)

    def test_pre_0044_paid_expectation_negative_control_is_rejected(self):
        # The 2026-09-01 sizes (8/150/8, 25/300/20, 80/600/40, 3 seats) must not
        # be able to come back into the expectation matrix unnoticed.
        for old, new in ((r"\('starter',\s*4,\s*100,\s*30", "('starter', 8, 150, 8"),
                         (r"\('pro',\s*10,\s*200,\s*60", "('pro', 25, 300, 20"),
                         (r"\('team',\s*25,\s*400,\s*150,\s*8,\s*2,\s*2", "('team', 80, 600, 40, 15, 2, 3")):
            with self.subTest(plan=new):
                mutant = re.sub(old, new, self.invariants, count=1)
                self.assertNotEqual(mutant, self.invariants)
                with self.assertRaises(AssertionError):
                    require_contract(mutant)

    def test_single_location_trial_override_negative_control_is_rejected(self):
        mutant = re.sub(r"\('trial',\s*1,\s*20,\s*20,\s*1,\s*1,\s*null::integer,\s*1500\)",
                        "('trial', 3, 60, 4, 2, 1, null::integer, 1200)", self.invariants, count=1)
        self.assertNotEqual(mutant, self.invariants)
        with self.assertRaises(AssertionError):
            require_contract(mutant)

    def test_pre_recipe_allowances_are_rejected(self):
        # A second historical boundary: the previous 0044-era matrix must not
        # replace current shot/ceiling contracts while retaining tour/edit sizes.
        for current, previous in (
            (r"\('trial',\s*3,\s*20,\s*20,\s*2,\s*1,\s*1,\s*1500,\s*0\)",
             "('trial', 3, 60, 4, 2, 1, 1, 1200, 0)"),
            (r"\('starter',\s*4,\s*100,\s*30,\s*2,\s*0,\s*1,\s*2032,\s*4900\)",
             "('starter', 4, 100, 6, 2, 0, 1, 1200, 4900)"),
            (r"\('solo',\s*4,\s*100,\s*30,\s*2,\s*0,\s*1,\s*2032,\s*4900\)",
             "('solo', 4, 100, 6, 2, 0, 1, 1200, 4900)"),
            (r"\('pro',\s*10,\s*200,\s*60,\s*4,\s*0,\s*1,\s*4157,\s*9900\)",
             "('pro', 10, 200, 12, 4, 0, 1, 2400, 9900)"),
            (r"\('team',\s*25,\s*400,\s*150,\s*8,\s*2,\s*2,\s*10532,\s*24900\)",
             "('team', 25, 400, 25, 8, 2, 2, 6000, 24900)"),
        ):
            with self.subTest(previous=previous):
                mutant, count = re.subn(current, previous, self.invariants, count=1)
                self.assertEqual(count, 1, 'the actual matrix row must be mutated')
                with self.assertRaises(AssertionError):
                    require_contract(mutant)

    def test_positive_and_negative_sql_use_the_same_gate_source(self):
        include = '\\ir invariant_astra_paid_gates.sql'
        self.assertEqual(self.invariants.count(include), 1)
        self.assertEqual(self.negative.count(include), 3)
        self.assertIn("current_database() <> 'rendprop_audit'", self.negative)
        self.assertIn("current_setting('listen_addresses') <> ''", self.negative)
        self.assertIn("^/tmp/rendprop-db-audit-[^/]+/cluster$", self.negative)
        self.assertIn("set min_plan = 'free'", self.negative)
        self.assertIn("set min_plan = 'pro', position = 17", self.negative)
        self.assertIn('rollback;', self.negative)
        self.assertEqual(self.negative.count("if changed <> 1"), 2)

    def test_paid_gate_cannot_substitute_three_arbitrary_rows(self):
        self.assertIn('count(*) = 3', self.gates)
        for task, plan in [('copy.shotlist', 'starter'), ('copy.reel_script', 'starter'),
                           ('copy.agent_reel', 'pro')]:
            self.assertRegex(self.gates,
                re.escape(f"where task = '{task}' and position = 1 and provider = 'openai'")
                + r"\s+and " + re.escape(f"min_plan = '{plan}') = 1"))


if __name__ == '__main__':
    unittest.main(verbosity=2)
