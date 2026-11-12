#!/usr/bin/env python3
"""Closed hosted-audible driver controls: no browser, Git, network or subprocess."""
from __future__ import annotations

from copy import deepcopy
import hashlib
from io import BytesIO
from pathlib import Path
import runpy
import tarfile
import tempfile
import unittest


API = runpy.run_path(str(Path(__file__).with_name("hosted_audible.py")),
                     run_name="closed_controls")
TREE = "b68f9bb6b4ffb438935e12e684c7b1a989d1ad592afef166ad1ef1d1792ebe64"
CASES = API["CASES"]


def valid_receipt() -> dict:
    packets = [{"timestamp": i / 30, "duration": 1 / 30, "bytes": 100,
                "sequenceNumber": i} for i in range(90)]
    positive = lambda name: {
        "name": name, "result": {"ok": True},
        "webCodecs": {"requested": 90, "encoded": deepcopy(packets),
                      "finalized": True, "failed": False,
                      "audio": {"frames": 144000, "blocks": 141,
                                "channels": 2, "sampleRate": 48000,
                                "maxQueueDepth": 2}},
    }
    first = positive(CASES[0])
    first["pcmTrace"] = {"audioStateAfterClose": "closed", "ownedTracksAfterClose": 0}
    first["probes"] = {"decodedFrames": 90, "duration": 3.028,
                       "avDurationGap": .02, "pixels": {"whip": True},
                       "pcm": {"onset": .51}}
    second = positive(CASES[1])
    second.update(injected=True, outerAudioState="closed",
                  pcm={"audioStateAfterClose": "closed", "ownedTracksAfterClose": 0},
                  pcmProbe={"onset": .51})
    refused = []
    for name in CASES[2:]:
        refused.append({"name": name, "result": {"ok": False},
                        "webCodecs": {"finalized": False, "failed": True},
                        "outerAudioState": "closed", "injected": True,
                        "pcm": {"audioStateAfterClose": "closed",
                                "ownedTracksAfterClose": 0}})
    return {"status": "prototype-case-passed", "partialSuite": True,
            "runtimeProfile": "hosted-exact", "externalRequests": [], "errors": [],
            "sourceHashesBefore": {"test": "pinned"},
            "sourceHashesAfter": {"test": "pinned"},
            "dependencyTreeBefore": TREE, "dependencyTreeAfter": TREE,
            "checks": ["actual PCM", "actual encoded frames", "late promise"],
            "cases": [first, second, *refused]}


class ClosedControls(unittest.TestCase):
    def check_rejects(self, edit, label: str) -> None:
        receipt = valid_receipt()
        edit(receipt)
        with self.subTest(label=label), self.assertRaises(RuntimeError):
            API["check_receipt"](receipt, {"test": "pinned"})

    def test_accepts_only_complete_two_positive_eight_refusal_receipt(self):
        receipt = valid_receipt()
        API["check_receipt"](receipt, {"test": "pinned"})
        self.assertEqual(len(receipt["cases"]), 10)
        self.assertEqual([row["name"] for row in receipt["cases"]], CASES)
        self.check_rejects(lambda r: r["cases"].pop(), "missing refusal")
        self.check_rejects(lambda r: r["cases"].reverse(), "wrong case order")
        self.check_rejects(lambda r: r["cases"][0]["result"].update(ok=False), "positive failed")
        self.check_rejects(lambda r: r["cases"][4]["result"].update(ok=True), "refusal accepted")
        self.check_rejects(lambda r: r["cases"][4].update(injected=False), "fault not injected")
        self.check_rejects(lambda r: r["cases"][1].update(injected=False), "late promise not injected")

    def test_source_dependency_profile_and_isolation_fail_closed(self):
        self.check_rejects(lambda r: r.update(partialSuite=False), "full-suite claim")
        self.check_rejects(lambda r: r.update(runtimeProfile="local-observation"), "local profile")
        self.check_rejects(lambda r: r.update(sourceHashesAfter={"test": "changed"}), "source drift")
        self.check_rejects(lambda r: r.update(sourceHashesBefore={"test": "other"}), "expected source mismatch")
        self.check_rejects(lambda r: r.update(dependencyTreeAfter="changed"), "dependency drift")
        self.check_rejects(lambda r: r.update(externalRequests=["outside"]), "external request")
        self.check_rejects(lambda r: r.update(errors=["page error"]), "page error")
        self.check_rejects(lambda r: r.update(status="failed"), "failed receipt")
        self.assertEqual(API["VERSIONS"], {
            "node": "v24.22.2", "browser": "Google Chrome for Testing 153.0.8010.12",
            "ffmpeg": "ffmpeg version 9.0.2 Copyright (c) 2000-2026 the FFmpeg developers",
            "ffprobe": "ffprobe version 9.0.2 Copyright (c) 2007-2026 the FFmpeg developers"})

    def test_positive_media_pts_pcm_and_cleanup_requirements(self):
        self.check_rejects(lambda r: r["cases"][0]["webCodecs"].update(requested=89), "requested frame count")
        self.check_rejects(lambda r: r["cases"][0]["webCodecs"]["encoded"].pop(), "encoded frame count")
        self.check_rejects(lambda r: r["cases"][0]["webCodecs"]["encoded"][8].update(timestamp=.5), "PTS gap")
        self.check_rejects(lambda r: r["cases"][0]["webCodecs"]["audio"].update(frames=143999), "PCM frames")
        self.check_rejects(lambda r: r["cases"][0]["webCodecs"]["audio"].update(maxQueueDepth=9), "credits")
        self.check_rejects(lambda r: r["cases"][0]["pcmTrace"].update(audioStateAfterClose="running"), "audio context")
        self.check_rejects(lambda r: r["cases"][1].update(outerAudioState="running"), "late positive context")
        self.check_rejects(lambda r: r["cases"][0]["probes"].update(decodedFrames=89), "decoded frames")
        self.check_rejects(lambda r: r["cases"][0]["probes"].update(avDurationGap=.08), "A/V duration")
        self.check_rejects(lambda r: r.update(checks=[]), "media oracle completion")

    def test_refusal_must_not_finalize_and_must_cleanup(self):
        self.check_rejects(lambda r: r["cases"][2]["webCodecs"].update(finalized=True), "refused finalized")
        self.check_rejects(lambda r: r["cases"][2]["webCodecs"].update(failed=False), "refusal failed flag")
        self.check_rejects(lambda r: r["cases"][3].update(outerAudioState="running"), "refusal context")
        self.check_rejects(lambda r: r["cases"][5]["pcm"].update(ownedTracksAfterClose=1), "refusal tracks")

    def test_separate_evidence_and_owned_process_selection(self):
        for base in ("/shipping", "/shipping/evidence", "/payload", "/payload/out", "/"):
            with self.subTest(base=base), self.assertRaises(RuntimeError):
                API["assert_separate"](Path(base), Path("/shipping"), Path("/payload"))
        API["assert_separate"](Path("/runner-temp/proof"), Path("/shipping"), Path("/payload"))
        table = {10: {"ppid": 1, "identity": "node A"},
                 11: {"ppid": 10, "identity": "chrome A"},
                 12: {"ppid": 11, "identity": "renderer A"},
                 20: {"ppid": 1, "identity": "unrelated chrome"}}
        self.assertEqual(API["descendant_identities"](table, 10),
                         {10: "node A", 11: "chrome A", 12: "renderer A"})

    def test_timeout_signals_only_original_owned_identities(self):
        namespace = API["stop_owned_tree"].__globals__
        original_table, original_kill = namespace["process_table"], namespace["os"].kill
        tables = [{10: {"ppid": 1, "identity": "node A"},
                   11: {"ppid": 10, "identity": "chrome A"}},
                  {10: {"ppid": 1, "identity": "node A"},
                   11: {"ppid": 1, "identity": "reused PID B"}},
                  {10: {"ppid": 1, "identity": "node A"},
                   11: {"ppid": 1, "identity": "reused PID B"}}]
        observed = []
        class Child:
            pid = 10
            def wait(self, timeout):
                return 1
        try:
            namespace["process_table"] = lambda: tables.pop(0)
            namespace["os"].kill = lambda pid, sig: observed.append((pid, sig))
            journal = {}
            API["stop_owned_tree"](Child(), journal)
        finally:
            namespace["process_table"] = original_table
            namespace["os"].kill = original_kill
        self.assertEqual(journal["timeoutOwnedPids"], [10, 11])
        self.assertEqual([pid for pid, _ in observed], [10, 10])

    def test_archive_binding_accepts_transport_metadata_only_and_refuses_source_drift(self):
        namespace = API["archive_binding"].__globals__
        original = {name: namespace[name] for name in
                    ("SOURCE_FILES", "SOURCE_AGGREGATE", "MODE_AGGREGATE")}
        content = b"exact source bytes\n"
        digest = hashlib.sha256(content).hexdigest()
        namespace["SOURCE_FILES"] = 1
        namespace["SOURCE_AGGREGATE"] = hashlib.sha256(
            f"file.txt\t{digest}\n".encode()).hexdigest()
        namespace["MODE_AGGREGATE"] = hashlib.sha256(
            b"file.txt\t100644\t\n").hexdigest()
        try:
            with tempfile.TemporaryDirectory(prefix="audible-archive-control-") as scratch:
                root = Path(scratch)
                source = root / "source"
                source.mkdir()
                file = source / "file.txt"
                file.write_bytes(content)
                file.chmod(0o644)
                archives = []
                for index, mtime in enumerate((1, 1000)):
                    archive = root / f"source-{index}.tar"
                    member = tarfile.TarInfo("file.txt")
                    member.size = len(content)
                    member.mode = 0o644
                    member.mtime = mtime
                    member.uid = index + 1
                    with tarfile.open(archive, "w") as bundle:
                        bundle.addfile(member, BytesIO(content))
                    archives.append(archive)
                first = API["archive_binding"](archives[0], source)
                second = API["archive_binding"](archives[1], source)
                self.assertNotEqual(first["archiveSha256"], second["archiveSha256"])
                self.assertEqual(first["aggregateSha256"], second["aggregateSha256"])
                self.assertEqual(first["canonicalModeAndSymlinkAggregateSha256"],
                                 second["canonicalModeAndSymlinkAggregateSha256"])
                file.write_bytes(b"changed source bytes\n")
                with self.assertRaises(RuntimeError):
                    API["archive_binding"](archives[0], source)
                file.write_bytes(content)
                file.chmod(0o755)
                with self.assertRaises(RuntimeError):
                    API["archive_binding"](archives[0], source)
        finally:
            namespace.update(original)


if __name__ == "__main__":
    unittest.main()
