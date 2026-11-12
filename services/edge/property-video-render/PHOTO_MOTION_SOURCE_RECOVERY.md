# Photo Motion renderer source parity

The active `container/photo_motion_profile.py` matches the retained production
renderer profile byte for byte (SHA-256
`9c4e21b2daa4b70a4725138a8ca21465e3eab433f094bd4f557e4f68b5ee83b9`).
The active renderer now dispatches Photo Motion and aerial-opening tasks to
that profile and the restored aerial modules. The older `photo_motion.py`
remains for historical compatibility; it is not the current 24 fps,
variable-duration, four-direction Photo Motion implementation.

`Dockerfile.photo-motion` is a candidate build definition using Pillow 13.0.0,
numpy 2.5.4, and pillow-heif 1.8.1. It copies the active `container/` tree.
The repository's newer `motion_qc.py` limits digest is retained. The candidate
therefore has its own source-context hash in
`PHOTO_MOTION_SOURCE_RECOVERY_MANIFEST.json` and has **not** been shown to have
the production image digest. The manifest lists every file copied into the
candidate image, plus the build definition and dependency lock.

Focused tests cover producer identity rejection, closed task validation,
12 percent motion in four directions, HEIC decoder refusal, a real short
clip, and an aerial opening followed by Photo Motion. Run them with a
temporary directory that has at least 3 GiB free, for example:

```sh
TMPDIR=/path/to/large/temp python3 -m unittest \
  tests.test_photo_motion_profile \
  tests.test_photo_motion_v2 \
  tests.test_aerial_processing \
  tests.test_aerial_opening_profile
```

This branch contains source and local tests only. It does not change the
active controller or Wrangler configuration. An image build, runtime proof,
immutable image digest, controller qualification, and producer identity update
are still required before deployment. The retained production evidence and
controller bundle remain outside this public repository.
