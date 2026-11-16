import json
from pathlib import Path
import tempfile
import unittest

from npm_package_inventory import discover


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tracked = []

    def project(self, directory):
        package = {'name': directory.replace('/', '-'), 'devDependencies': {'tool': '1.2.3'}}
        lock = {'lockfileVersion': 3, 'packages': {'': package.copy()}}
        for name, data in [('package.json', package), ('package-lock.json', lock)]:
            path = self.root / directory / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(data))
            self.tracked.append(str(path.relative_to(self.root)))

    def test_new_project_is_included_without_workflow_edit(self):
        self.project('apps/studio')
        self.project('apps/new-client')
        self.assertEqual(discover(self.root, self.tracked), ['apps/new-client', 'apps/studio'])

    def test_untracked_lock_cannot_make_ci_look_reproducible(self):
        self.project('apps/studio')
        self.tracked.remove('apps/studio/package-lock.json')
        with self.assertRaisesRegex(ValueError, 'Missing tracked lockfile'):
            discover(self.root, self.tracked)

    def test_changed_dev_dependency_requires_matching_lock(self):
        self.project('apps/studio')
        path = self.root / 'apps/studio/package.json'
        data = json.loads(path.read_text())
        data['devDependencies']['tool'] = '2.0.0'
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, 'does not match devDependencies'):
            discover(self.root, self.tracked)

    def test_symlinked_manifest_is_refused(self):
        self.project('apps/studio')
        path = self.root / 'apps/studio/package.json'
        target = self.root / 'stored.json'
        path.rename(target)
        path.symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'regular files'):
            discover(self.root, self.tracked)

    def test_outside_repository_path_is_refused(self):
        with self.assertRaisesRegex(ValueError, 'inside the repository'):
            discover(self.root, ['../package.json'])


if __name__ == '__main__':
    unittest.main()
