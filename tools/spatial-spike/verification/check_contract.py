#!/usr/bin/env python3
"""Assert actual Swift JPEG/JSON -> Python binary export; synthetic only."""
import argparse
import hashlib
import json
from pathlib import Path
import struct


def fingerprint(root):
    digest = hashlib.sha256()
    for path in sorted(root.rglob('*')):
        if path.is_file():
            digest.update(str(path.relative_to(root)).encode())
            digest.update(b'\0')
            digest.update(path.read_bytes())
    return digest.hexdigest()


def verify(root, output):
    manifest = json.loads((root / 'manifest.json').read_text())
    report = json.loads((output / 'adapter-report.json').read_text())
    assert 'SYNTHETIC-NOT-A-ROOM' in manifest['device_model']
    assert report['frames'] == 20 and report['initial_points'] == 120
    assert report['point_observations'] == 2400
    assert report['visible_point_ids'] == 120
    assert abs(report['camera_radius_m'] - .095) < 1e-6
    assert report['gpu_training_performed'] is False
    assert report['reprojection_error_measured'] is False
    assert manifest['units'] == 'metres' and manifest['matrix_layout'] == 'row-major'
    frame_records = [json.loads((root / p).read_text()) for p in manifest['frames']]
    assert len(frame_records) == 20
    expected_ids = {str(2**64 - 1 - i) for i in range(120)}
    for frame in frame_records:
        assert {p['id'] for p in frame['raw_feature_points']} == expected_ids
        assert all(type(p['id']) is str for p in frame['raw_feature_points'])
        assert frame['tracking_state'] == {'state': 'normal', 'reason': None}
        assert frame['camera_to_world'][3] == [0, 0, 0, 1]
        image = frame['image']
        source_bytes = (root / image).read_bytes()
        assert (output / image).read_bytes() == source_bytes
        assert report['image_sha256'][Path(image).name] == hashlib.sha256(source_bytes).hexdigest()
    with (output / 'sparse/0/cameras.bin').open('rb') as stream:
        assert struct.unpack('<Q', stream.read(8))[0] == 20
        for index in range(1, 21):
            camera = struct.unpack('<IiQQ4d', stream.read(struct.calcsize('<IiQQ4d')))
            assert camera == (index, 1, 160, 120, 120.0, 120.0, 80.0, 60.0)
        assert stream.read() == b''
    with (output / 'sparse/0/images.bin').open('rb') as stream:
        assert struct.unpack('<Q', stream.read(8))[0] == 20
        for index, frame in enumerate(frame_records, 1):
            values = struct.unpack('<I4d3dI', stream.read(struct.calcsize('<I4d3dI')))
            image_id, qw, qx, qy, qz, tx, ty, tz, camera_id = values
            assert image_id == camera_id == index
            # Identity ARKit c2w rotation becomes CV's 180-degree X rotation.
            assert abs(qw) < 1e-9 and abs(abs(qx) - 1) < 1e-9 and abs(qy) < 1e-9 and abs(qz) < 1e-9
            assert abs(tx + frame['camera_to_world'][0][3]) < 1e-9 and ty == tz == 0
            name = bytearray()
            while (char := stream.read(1)) != b'\0':
                assert char, 'unterminated image name'
                name.extend(char)
            assert name.decode() == f'{index:06d}.jpg'
            assert struct.unpack('<Q', stream.read(8))[0] == 0, 'No invented 2D tracks'
        assert stream.read() == b''
    expected_positions = {tuple(p['position']) for p in frame_records[0]['raw_feature_points']}
    actual_positions = set()
    with (output / 'sparse/0/points3D.bin').open('rb') as stream:
        assert struct.unpack('<Q', stream.read(8))[0] == 120
        for index in range(1, 121):
            point = struct.unpack('<Q3d3BdQ', stream.read(struct.calcsize('<Q3d3BdQ')))
            assert point[0] == index and point[-1] == 0
            actual_positions.add(tuple(point[1:4]))
        assert stream.read() == b''
    assert actual_positions == expected_positions, 'World coordinates must not be flipped or rescaled'
    for name, digest in report['model_sha256'].items():
        assert hashlib.sha256((output / 'sparse/0' / name).read_bytes()).hexdigest() == digest
    print('PASS: actual Swift native JPEG/JSON -> Python binary dataset: 20 frames, 120 seeds, exact high UInt64 IDs, calibrated poses/intrinsics, unchanged world coordinates and JPEG bytes; SYNTHETIC ONLY')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('dataset', nargs='?', type=Path)
    parser.add_argument('--fingerprint', action='store_true')
    args = parser.parse_args()
    if args.fingerprint:
        print(fingerprint(args.capture))
    else:
        assert args.dataset is not None, 'dataset argument required'
        verify(args.capture, args.dataset)
