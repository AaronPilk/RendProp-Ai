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


def require_contract(sql):
    assert 'ceiling > visible and ceiling <= 8000' in sql, 'reasoning headroom rule weakened'
    assert re.search(r"\('trial',\s*3,\s*60,\s*4,\s*2,\s*1,\s*1,\s*1200,\s*0\)", sql)
    assert re.search(r"\('free',\s*1,\s*5,\s*0,\s*0,\s*0,\s*1,\s*300,\s*0\)", sql)
    assert 'for v_n in 1..3 loop' in sql
    assert "'_inv-wrk-000004'" in sql
    assert "worker job #4 exceeds the trial cap (RP402)" in sql


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

    def test_old_trial_expectation_negative_control_is_rejected(self):
        mutant = re.sub(r"\('trial',\s*3,\s*60", "('trial', 1, 10", self.invariants, count=1)
        self.assertNotEqual(mutant, self.invariants)
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
