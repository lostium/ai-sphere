"""Upload a payload through one target and read it back the way the watch does.

Used by hosting/test/integration.sh, which starts local servers in Docker. Can also be pointed at a
real host:

  /usr/bin/python3 hosting/test/roundtrip.py --target target.json --read-url https://…/usage.json \
      --watch-key keychain:ai-sphere-watch-key

Exit code 0 when every check passes. Secrets are references ("env:NAME", "keychain:NAME").
"""
import argparse
import time
import json
import os
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "mac"))

import targets  # noqa: E402


def get(url, key=None):
    headers = {"User-Agent": "ai-sphere-roundtrip/1"}
    if key is not None:
        headers["X-Key"] = key
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=15) as r:
            return r.status, r.headers.get("Content-Type", ""), r.headers.get("Cache-Control", ""), r.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.headers.get("Content-Type", ""), "", b""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default="target")
    ap.add_argument("--target", required=True, help="JSON file with the target object")
    ap.add_argument("--read-url", help="URL the watch would GET; omit to only test the upload")
    ap.add_argument("--watch-key", help="secret ref of the X-Key; omit if the reader does not check it")
    ap.add_argument("--settle", type=float, default=0, help="seconds to wait before reading back")
    ap.add_argument("--read-s3", action="store_true", help="read back with a signed S3 GET instead of --read-url")
    args = ap.parse_args()

    with open(args.target, encoding="utf-8") as fh:
        target = json.load(fh)
    failures = []

    def check(ok, what):
        print(f"  {'ok  ' if ok else 'FAIL'} {what}")
        if not ok:
            failures.append(what)

    print(f"[{args.name}]")
    for n in (1, 2):  # twice: the second upload must replace the first
        body = json.dumps({"v": 1, "t": f"2026-11-11T00:00:0{n}Z", "p": [], "run": n}, separators=(",", ":")).encode()
        try:
            where = targets.publish(body, target, retries=0)
            check(True, f"upload {n} -> {where}")
        except targets.UploadError as exc:
            check(False, f"upload {n}: {exc}")
            break

    if args.settle:
        time.sleep(args.settle)

    if args.read_s3 and not failures:
        req = targets.s3_request("GET", target, b"", targets.resolve_secret(target["accessKeyId"]),
                                 targets.resolve_secret(target["secretAccessKey"]))
        with urllib.request.urlopen(req, timeout=15) as r:
            check(r.read() == body, "signed GET returns the second upload")
            check(r.headers.get("Content-Type") == "application/json", f"stored Content-Type {r.headers.get('Content-Type')}")
            check(r.headers.get("Cache-Control") == targets.DEFAULT_CACHE_CONTROL, f"stored Cache-Control {r.headers.get('Cache-Control')}")

    if args.read_url and not failures:
        if args.watch_key:
            key = targets.resolve_secret(args.watch_key)
            status, *_ = get(args.read_url)
            check(status == 403, f"no X-Key -> {status} (want 403)")
            status, *_ = get(args.read_url, "wrong-" + key)
            check(status == 403, f"wrong X-Key -> {status} (want 403)")
        else:
            key = None
        status, ctype, cache, data = get(args.read_url, key)
        check(status == 200, f"right X-Key -> {status} (want 200)")
        check(ctype.split(";")[0].strip() == "application/json", f"Content-Type {ctype!r}")
        check("max-age=60" in cache, f"Cache-Control {cache!r}")
        check(data == body, "body is the second upload")
        tmp_status, *_ = get(args.read_url + ".tmp", key)
        check(tmp_status in (403, 404), f"temporary file not served ({tmp_status})")
        head, _, name = args.read_url.rpartition("/")
        upper_status, *_ = get(f"{head}/{name.upper()}")
        check(upper_status != 200, f"upper-case path without X-Key not served ({upper_status})")

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
