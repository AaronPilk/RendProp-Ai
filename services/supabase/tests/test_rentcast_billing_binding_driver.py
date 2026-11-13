#!/usr/bin/env python3
"""Closed maintained-runner controls: no PostgreSQL, Deno, provider or network."""
import importlib.util
from pathlib import Path
import unittest

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('rentcast_billing_binding_pg',HERE/'rentcast_billing_binding_pg.py')
runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)

class PortableRunnerControls(unittest.TestCase):
    def test_import_and_help_have_no_execution(self):
        args=runner.parser().parse_args(['--evidence-dir','portable-evidence'])
        self.assertEqual(args.node_modules_dir,'none')
        self.assertEqual(args.evidence_dir,Path('portable-evidence'))
        self.assertIsNone(args.pg_bin)
        self.assertIsNone(args.deno_binary)
    def test_actual_runtime_closure_is_local_and_complete(self):
        sources=runner.runtime_sources()
        self.assertIn(runner.SQL/'functions/property/index.ts',sources)
        self.assertIn(runner.SQL/'functions/_shared/provider-attempt-receipt.ts',sources)
        self.assertTrue(all(f.is_relative_to(runner.SQL/'functions')for f in sources))
    def test_future_migrations_are_included_after_legacy_boundary(self):
        own=Path('20261017110114_freeze_property_attempt_liability.sql')
        earlier=Path('0001_init.sql');future=Path('20990101000000_future.sql')
        self.assertEqual(runner.migration_stages([earlier,own,future],own),([earlier],[future]))
        with self.assertRaises(AssertionError):runner.migration_stages([earlier,future],own)
        with self.assertRaises(AssertionError):runner.migration_stages([own,own],own)
    def test_current_inventory_refuses_missing_cases_or_failure(self):
        runner.require_summary('ok | 8 passed | 0 failed (1s)\n',8,0)
        for text in ['ok | 7 passed | 0 failed\n','FAILED | 7 passed | 1 failed\n','error: refused\n','ok | 8 passed | 0 failed\nFAILED | 0 passed | 1 failed\n']:
            with self.assertRaises(AssertionError):runner.require_summary(text,8,0)
    def test_negative_requires_both_actual_invariant_witnesses(self):
        w=('in-flight-hit-control receipt/ledger billing organization must match','in-flight-miss-control receipt/ledger billing organization must match')
        good='\n'.join(w)+'\nFAILED | 0 passed | 2 failed (1s)\n'
        runner.require_summary(good,0,2,w)
        for text in ['FAILED | 0 passed | 2 failed\n','\n'.join(w)+'\nerror: setup refused\n',good.replace(w[1],'unrelated failure')]:
            with self.assertRaises(AssertionError):runner.require_summary(text,0,2,w)

    def test_wrong_payer_control_refuses_setup_failure_even_when_title_matches(self):
        title='foreign frozen payer cannot be confirmed by ledger readback'
        witness='error: AssertionError: Values are not equal: '+title
        setup=title+' ... FAILED\nerror: SyntaxError: Unexpected token C\nFAILED | 0 passed | 1 failed\n'
        with self.assertRaises(AssertionError):runner.require_summary(setup,0,1,(witness,))
        runner.require_summary(witness+'\nFAILED | 0 passed | 1 failed\n',0,1,(witness,))

if __name__=='__main__':unittest.main()
