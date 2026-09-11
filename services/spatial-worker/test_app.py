"""Execute the disabled scheduler entry with a fake decorator, never Modal."""
import importlib.util
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


class AppTests(unittest.TestCase):
    def test_disabled_source_cannot_inherit_live_secret_or_allocate(self):
        image = Mock()
        image.pip_install.return_value = image
        image.add_local_file.return_value = image
        kwargs = {}
        def decorate(**values):
            kwargs.update(values)
            return lambda fn: fn
        app = SimpleNamespace(function=decorate)
        modal = SimpleNamespace(App=lambda _: app, Image=SimpleNamespace(from_registry=lambda _: image),
                                Period=lambda **kw: kw, Secret=Mock())
        spec = importlib.util.spec_from_file_location('disabled_fixture_app', Path(__file__).with_name('app.py'))
        module = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {'modal': modal}), patch.dict('os.environ', {'SPATIAL_WORKER_ENABLED': 'true'}), \
                patch('worker.ControlPlane') as control, patch('worker.run_one') as run:
            spec.loader.exec_module(module)
            self.assertEqual(module.process_next(), {'status': 'disabled'})
        self.assertFalse(module.DEPLOYMENT_ENABLED)
        self.assertEqual(kwargs['secrets'], [])
        self.assertIsNone(kwargs['schedule'])
        self.assertEqual(kwargs['max_containers'], 1)
        self.assertEqual(kwargs['retries'], 0)
        self.assertNotIn('gpu', kwargs)
        self.assertNotIn('ephemeral_disk', kwargs)
        modal.Secret.from_name.assert_not_called()
        control.assert_not_called()
        run.assert_not_called()


if __name__ == '__main__':
    unittest.main(verbosity=2)
