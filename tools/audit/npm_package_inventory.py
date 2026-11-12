#!/usr/bin/env python3
"""Discover tracked npm projects so new packages cannot silently evade CI audit."""
import argparse
import json
from pathlib import Path
import subprocess


def discover(root: Path, tracked: list[str]) -> list[str]:
    paths = set(tracked)
    manifests = sorted(p for p in paths if Path(p).name == 'package.json')
    if not manifests:
        raise ValueError('No tracked npm package manifests found')
    directories = []
    for manifest in manifests:
        relative = Path(manifest)
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Package path must stay inside the repository')
        lock = relative.with_name('package-lock.json').as_posix()
        if lock not in paths:
            raise ValueError(f'Missing tracked lockfile: {manifest}')
        for name in (manifest, lock):
            file = root / name
            if file.is_symlink() or not file.is_file():
                raise ValueError(f'Package inputs must be regular files: {name}')
            if not isinstance(json.loads(file.read_text()), dict):
                raise ValueError(f'Package input must be a JSON object: {name}')
        package = json.loads((root / manifest).read_text())
        locked = json.loads((root / lock).read_text())
        if locked.get('lockfileVersion') not in (2, 3):
            raise ValueError(f'Unsupported lockfile version: {lock}')
        locked_root = locked.get('packages', {}).get('')
        if not isinstance(locked_root, dict):
            raise ValueError(f'Missing locked root package: {lock}')
        for field in ('dependencies', 'devDependencies', 'optionalDependencies'):
            if package.get(field, {}) != locked_root.get(field, {}):
                raise ValueError(f'Lockfile does not match {field}: {manifest}')
        directories.append(relative.parent.as_posix())
    return directories


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--github-output', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    tracked = subprocess.check_output(
        ['git', 'ls-files', '--cached', '-z'], cwd=root
    ).decode().split('\0')
    directories = discover(root, [p for p in tracked if p])
    value = json.dumps(directories)
    if args.github_output:
        with args.github_output.open('a') as output:
            output.write('directories=' + value + '\n')
    print(value)


if __name__ == '__main__':
    main()
