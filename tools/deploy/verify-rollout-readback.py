#!/usr/bin/env python3
"""File-only complete rollout comparison. Never collects, authenticates or deploys."""
from __future__ import annotations
import argparse
import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import stat

JSON_LIMIT = 4 * 1024**2
ARTIFACT_LIMIT = 256 * 1024**2
TOTAL_ARTIFACT_LIMIT = 512 * 1024**2
MAX_AGE = 300
SHA = r"[0-9a-f]{64}"
SECRET_KEYS = {"secret", "secrets", "token", "accesstoken", "refreshtoken", "oauthtoken",
               "authorization", "password", "privatekey", "clientsecret", "apikey", "apitoken",
               "credential", "credentials", "cookie", "setcookie", "bearertoken", "signedurl"}


class Refusal(Exception):
    def __init__(self, code, paths=(), differences=()):
        self.code, self.paths, self.differences = code, list(paths), list(differences)
        super().__init__(code)


def require(ok, code, *paths):
    if not ok:
        raise Refusal(code, paths)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
                      allow_nan=False).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def same(a, b):
    # Python equality would conflate true/1 and false/0.
    return canonical(a) == canonical(b)


def file_bytes(path, maximum, retain=True):
    """Pin a regular final path; reject symlinks and a file changing during its read."""
    require(hasattr(os, "O_NOFOLLOW"), "nofollow_unavailable")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode) and before.st_size <= maximum,
                    "file_not_regular_or_too_large", str(path))
        except BaseException:
            os.close(fd)
            raise
        with os.fdopen(fd, "rb") as handle:
            chunks, count, hashed = [], 0, hashlib.sha256()
            while True:
                chunk = handle.read(65536)
                if not chunk:
                    break
                count += len(chunk)
                require(count <= maximum, "file_too_large", str(path))
                hashed.update(chunk)
                if retain:
                    chunks.append(chunk)
            after = os.fstat(handle.fileno())
            named = os.stat(path, follow_symlinks=False)
            fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns", "st_mode")
            require(all(getattr(before, k) == getattr(after, k) == getattr(named, k) for k in fields) and
                    count == before.st_size, "file_changed_during_read", str(path))
            return b"".join(chunks), hashed.hexdigest(), count
    except OSError:
        raise Refusal("file_open_refused", [str(path)]) from None


def decode(raw):
    def pairs(items):
        value = {}
        for key, item in items:
            require(key not in value, "duplicate_json_key")
            value[key] = item
        return value
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(Refusal("nonfinite_json")))
    except Refusal:
        raise
    except (ValueError, UnicodeError, RecursionError):
        raise Refusal("invalid_json") from None


def secret_safe(value, path="", depth=0, budget=None):
    budget = [0] if budget is None else budget
    budget[0] += 1
    require(depth <= 40 and budget[0] <= 50000, "json_complexity", path)
    if isinstance(value, dict):
        name, kind = value.get("name"), value.get("type")
        if kind == "secret_text":
            require(set(value) == {"name", "type"} and isinstance(name, str) and
                    re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,127}", name), "secret_binding_value", path)
        elif isinstance(name, str) and re.search(r"SECRET|TOKEN|PASSWORD|API_KEY|PRIVATE_KEY|CREDENTIAL", name.upper()):
            raise Refusal("secret_binding_type", [path])
        for key, item in value.items():
            require(isinstance(key, str) and re.fullmatch(r"[A-Za-z0-9_.$:~/-]{1,256}", key),
                    "unsafe_field_name", path)
            require(not re.search(r"\b(?:sk_live_|sk-proj-)[A-Za-z0-9_-]{12,}|\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}", key),
                    "unsafe_field_name", path)
            child = path + "/" + key.replace("~", "~0").replace("/", "~1")
            normalized = re.sub(r"[^a-z0-9]", "", key.lower())
            if normalized == "secretnames":
                require(isinstance(item, list) and all(isinstance(n, str) and
                        re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,127}", n) for n in item) and
                        len(item) == len(set(item)), "secret_names_shape", child)
            else:
                require(normalized not in SECRET_KEYS and not re.search(
                    r"(?:SECRET|TOKEN|PASSWORD|PRIVATE_KEY|API_KEY|CREDENTIAL)(?:_|$)", key.upper()),
                    "credential_value_field", child)
            secret_safe(item, child, depth + 1, budget)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            secret_safe(item, path + "/" + str(index), depth + 1, budget)
    elif isinstance(value, str):
        require(len(value) <= 65536 and not re.search(
            r"-----BEGIN [A-Z ]*PRIVATE KEY-----|(?i:bearer\s+)|"
            r"(?i:(?:x-amz-signature|x-goog-signature|access_token|refresh_token)=)|"
            r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}|"
            r"\b(?:sk_live_|sk-proj-)[A-Za-z0-9_-]{12,}", value), "capability_value", path)


def pointer(path):
    require(isinstance(path, str) and path.startswith("/") and len(path) <= 2048 and
            "*" not in path, "invalid_pointer")
    parts = path[1:].split("/")
    require(all(re.fullmatch(r"[A-Za-z0-9_.$:~-]+", part) and not re.search(r"~(?![01])", part)
                for part in parts) and not re.search(
                    r"\b(?:sk_live_|sk-proj-)[A-Za-z0-9_-]{12,}|\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}", path),
            "invalid_pointer")
    return tuple(part.replace("~1", "/").replace("~0", "~") for part in parts)


def child(value, part, path):
    if isinstance(value, dict):
        require(part in value, "pointer_missing", path)
        return value, part
    require(isinstance(value, list) and re.fullmatch(r"0|[1-9][0-9]*", part), "pointer_type", path)
    index = int(part)
    require(index < len(value), "pointer_missing", path)
    return value, index


def locate(value, parts, path):
    for part in parts[:-1]:
        parent, key = child(value, part, path)
        value = parent[key]
    return child(value, parts[-1], path)


def nonoverlapping(paths):
    require(len(set(paths)) == len(paths), "duplicate_pointer")
    for i, a in enumerate(paths):
        for b in paths[i + 1:]:
            require(a[:len(b)] != b and b[:len(a)] != a, "overlapping_pointers")


def expected_control(baseline, changes):
    require(isinstance(changes, list) and len(changes) <= 128, "changes_shape")
    paths = []
    for entry in changes:
        require(isinstance(entry, dict) and set(entry) == {"path", "old", "new"}, "change_shape")
        paths.append(pointer(entry["path"]))
        secret_safe(entry["old"])
        secret_safe(entry["new"])
    nonoverlapping(paths)
    expected = copy.deepcopy(baseline)
    for entry, parts in zip(changes, paths):
        parent, key = locate(expected, parts, entry["path"])
        require(same(parent[key], entry["old"]), "change_old_mismatch", entry["path"])
        require(not same(entry["old"], entry["new"]), "no_op_change", entry["path"])
        parent[key] = copy.deepcopy(entry["new"])
    return expected


def normalize(control, inventories):
    require(isinstance(inventories, list) and len(inventories) <= 64, "inventory_shape")
    paths = []
    for entry in inventories:
        require(isinstance(entry, dict) and set(entry) == {"path", "key"} and
                isinstance(entry["key"], str) and entry["key"], "inventory_shape")
        paths.append(pointer(entry["path"]))
    nonoverlapping(paths)
    result = copy.deepcopy(control)
    for entry, parts in zip(inventories, paths):
        parent, key = locate(result, parts, entry["path"])
        rows = parent[key]
        require(isinstance(rows, list), "inventory_not_array", entry["path"])
        keys = []
        for row in rows:
            if entry["key"] == "$value":
                value = row
            else:
                require(isinstance(row, dict) and entry["key"] in row, "inventory_key_missing", entry["path"])
                value = row[entry["key"]]
            require(isinstance(value, str) and value, "inventory_key_type", entry["path"])
            keys.append(value)
        require(len(keys) == len(set(keys)), "inventory_duplicate", entry["path"])
        parent[key] = [row for _, row in sorted(zip(keys, rows), key=lambda pair: pair[0])]
    return result


def differences(expected, actual, path=""):
    if same(expected, actual):
        return []
    if isinstance(expected, dict) and isinstance(actual, dict):
        result = []
        for key in sorted(set(expected) | set(actual)):
            child_path = path + "/" + key.replace("~", "~0").replace("/", "~1")
            if key not in expected or key not in actual:
                record = {"path": child_path}
                if key in expected: record["expectedSHA256"] = digest(expected[key])
                if key in actual: record["actualSHA256"] = digest(actual[key])
                result.append(record)
            else:
                result.extend(differences(expected[key], actual[key], child_path))
        return result
    if isinstance(expected, list) and isinstance(actual, list) and len(expected) == len(actual):
        return [item for index, (a, b) in enumerate(zip(expected, actual))
                for item in differences(a, b, path + "/" + str(index))]
    return [{"path": path, "expectedSHA256": digest(expected), "actualSHA256": digest(actual)}]


def observed(value, now, maximum, path):
    require(isinstance(value, str), "timestamp_shape", path)
    try:
        stamp = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        require(stamp.tzinfo is not None and 0 <= (now - stamp).total_seconds() <= maximum,
                "snapshot_not_fresh", path)
        return stamp
    except ValueError:
        raise Refusal("timestamp_shape", [path]) from None


def compare(contract, baseline, actual, now):
    require(set(contract) == {"schema", "identity", "baseline", "actual", "max_age_seconds", "inventories", "changes", "artifacts"} and
            contract["schema"] == "rendprop-rollout-readback-v1", "contract_shape")
    identity = contract["identity"]
    require(isinstance(identity, dict) and set(identity) == {"environment", "account", "resource"} and
            all(isinstance(v, str) and 0 < len(v) <= 256 for v in identity.values()), "identity_shape")
    secret_safe(identity)
    age = contract["max_age_seconds"]
    require(type(age) is int and 1 <= age <= MAX_AGE and now.tzinfo is not None, "age_policy")
    stamps = []
    for label, value in [("baseline", baseline), ("actual", actual)]:
        require(isinstance(value, dict) and set(value) == {"identity", "observed_at_utc", "control"}, "snapshot_shape", label)
        require(same(value["identity"], identity), "identity_mismatch", "/" + label + "/identity")
        require(isinstance(value["control"], dict), "control_shape", label)
        secret_safe(value["control"])
        stamps.append(observed(value["observed_at_utc"], now, age, "/" + label + "/observed_at_utc"))
    require(stamps[1] >= stamps[0], "readback_precedes_baseline")
    # Validate baseline inventory integrity too; a replacement cannot hide a bad baseline.
    normalize(baseline["control"], contract["inventories"])
    expected = normalize(expected_control(baseline["control"], contract["changes"]), contract["inventories"])
    received = normalize(actual["control"], contract["inventories"])
    delta = differences(expected, received)
    if delta:
        raise Refusal("control_document_drift", differences=delta)
    return {"identitySHA256": digest(identity), "expectedControlSHA256": digest(expected),
            "actualControlSHA256": digest(received), "baselineControlSHA256": digest(baseline["control"])}


def resolve(base, value):
    require(isinstance(value, str) and value and "\x00" not in value, "path_shape")
    path = Path(value)
    return path if path.is_absolute() else base / path


def verify(contract_path, expected_contract_sha, now=None):
    require(isinstance(expected_contract_sha, str) and re.fullmatch(SHA, expected_contract_sha), "contract_hash_shape")
    raw, actual_contract_sha, _ = file_bytes(contract_path, JSON_LIMIT)
    require(actual_contract_sha == expected_contract_sha, "contract_hash_mismatch", str(contract_path))
    contract = decode(raw)
    require(isinstance(contract, dict), "contract_shape")
    base = Path(contract_path).parent
    documents, input_hashes = {}, {str(contract_path): actual_contract_sha}
    for label in ("baseline", "actual"):
        entry = contract.get(label)
        require(isinstance(entry, dict) and set(entry) == {"path", "sha256"} and
                isinstance(entry["sha256"], str) and re.fullmatch(SHA, entry["sha256"]), "document_reference")
        path = resolve(base, entry["path"])
        data, actual_sha, _ = file_bytes(path, JSON_LIMIT)
        require(actual_sha == entry["sha256"], "document_hash_mismatch", str(path))
        input_hashes[str(path)] = actual_sha
        documents[label] = decode(data)
    result = compare(contract, documents["baseline"], documents["actual"], now or dt.datetime.now(dt.timezone.utc))
    artifacts = contract["artifacts"]
    require(isinstance(artifacts, dict) and 1 <= len(artifacts) <= 256, "artifact_map_shape")
    artifact_hashes, total = {}, 0
    for name, expected_sha in artifacts.items():
        require(isinstance(expected_sha, str) and re.fullmatch(SHA, expected_sha), "artifact_hash_shape")
        path = resolve(base, name)
        _, actual_sha, size = file_bytes(path, ARTIFACT_LIMIT, retain=False)
        total += size
        require(total <= TOTAL_ARTIFACT_LIMIT, "artifact_total_size")
        require(actual_sha == expected_sha, "artifact_hash_mismatch", str(path))
        artifact_hashes[str(path)] = actual_sha
    return {"status": "HISTORICAL_REPLAY" if now is not None else "VERIFIED_FILE_ONLY",
            **result, "inputSHA256": input_hashes,
            "artifactSHA256": artifact_hashes}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--contract-sha256", required=True)
    args = parser.parse_args()
    try:
        result = verify(args.contract, args.contract_sha256)
        code = 0
    except Refusal as error:
        result = {"status": "REFUSED", "code": error.code, "paths": error.paths}
        if error.differences:
            result["differences"] = error.differences[:64]
            result["difference_count"] = len(error.differences)
        code = 2
    except Exception:
        result, code = {"status": "REFUSED", "code": "input_error", "paths": []}, 2
    print(json.dumps(result, sort_keys=True, allow_nan=False))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
