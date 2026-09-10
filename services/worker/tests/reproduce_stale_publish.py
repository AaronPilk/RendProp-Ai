# WH-03 regression entrypoint. The original unfenced helper was removed; merely
# observing AttributeError is NOT a passing test. Run the actual replacement
# helper + process suite. SQL fencing is separately checked by the guarded
# services/supabase/tests/worker_publish_transaction.sql fixture.
import unittest
from test_worker_publish import WorkerPublishTests

suite = unittest.defaultTestLoader.loadTestsFromTestCase(WorkerPublishTests)
result = unittest.TextTestRunner(verbosity=2).run(suite)
if result.testsRun != 14 or result.skipped or not result.wasSuccessful():
    raise SystemExit(1)
