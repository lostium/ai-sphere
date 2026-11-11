"""Tests for the upload targets (no network, no Docker). Run: /usr/bin/python3 -m unittest discover -s mac/tests

The end-to-end test against real servers (S3, SFTP, FTPS, WebDAV, nginx, Apache) is hosting/test/integration.sh.
"""
import base64
import datetime as dt
import http.server
import json
import os
import stat
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import targets  # noqa: E402

DATA = b'{"v":1,"t":"2026-11-11T00:00:00Z","p":[]}'


def fake_secret(ref):
    return {"pw": "s3cret", "tok": "t0ken", "ak": "AKIDEXAMPLE", "sk": "wJalrXUtnFEMI/K7MDENG"}[ref]


class Config(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def write(self, name, obj):
        with open(os.path.join(self.dir, name), "w") as fh:
            json.dump(obj, fh)

    def test_publish_json_wins(self):
        self.write("bunny.json", {"storageZone": "z", "cdnHost": "old.b-cdn.net"})
        self.write("publish.json", {"publicUrl": "https://x.example/usage.json", "target": {"type": "file", "path": "/tmp/x"}})
        cfg = targets.load_publish_config(self.dir)
        self.assertEqual(cfg["target"]["type"], "file")
        self.assertEqual(cfg["watchKey"], "ai-sphere-watch-key")

    def test_legacy_bunny_json(self):
        self.write("bunny.json", {"storageZone": "my-zone", "storageHost": "storage.bunnycdn.com", "cdnHost": "h.b-cdn.net",
                                  "remotePath": "usage.json", "keychain": {"storagePassword": "pw-item", "watchKey": "wk-item"}})
        cfg = targets.load_publish_config(self.dir)
        self.assertEqual(cfg["publicUrl"], "https://h.b-cdn.net/usage.json")
        self.assertEqual(cfg["watchKey"], "wk-item")
        self.assertEqual(cfg["target"], {"type": "bunny", "storageZone": "my-zone", "storageHost": "storage.bunnycdn.com",
                                         "path": "usage.json", "password": "pw-item"})

    def test_explicit_path_and_missing(self):
        with self.assertRaises(targets.UploadError):
            targets.load_publish_config(self.dir)
        path = os.path.join(self.dir, "other.json")
        with open(path, "w") as fh:
            json.dump({"target": {"type": "file", "path": "/tmp/y"}}, fh)
        self.assertEqual(targets.load_publish_config(self.dir, path)["target"]["path"], "/tmp/y")

    def test_target_object_required(self):
        self.write("publish.json", {"publicUrl": "https://x"})
        with self.assertRaises(targets.UploadError):
            targets.load_publish_config(self.dir)


class Secrets(unittest.TestCase):
    def test_env(self):
        os.environ["AIS_TEST_SECRET"] = "abc"
        self.assertEqual(targets.resolve_secret("env:AIS_TEST_SECRET"), "abc")
        with self.assertRaises(targets.UploadError):
            targets.resolve_secret("env:AIS_TEST_UNSET_VARIABLE")


class Publish(unittest.TestCase):
    def test_unknown_type(self):
        with self.assertRaises(targets.UploadError) as ctx:
            targets.publish(DATA, {"type": "carrier-pigeon"})
        self.assertFalse(ctx.exception.retry)

    def test_retries_then_succeeds(self):
        calls = []

        def flaky(data, cfg, secret):
            calls.append(1)
            if len(calls) < 3:
                raise targets.UploadError("temporary")
            return "ok"

        targets.TARGETS["flaky"] = flaky
        try:
            sleeps = []
            self.assertEqual(targets.publish(DATA, {"type": "flaky"}, retries=2, sleep=sleeps.append), "ok")
            self.assertEqual(sleeps, [5, 10])
        finally:
            del targets.TARGETS["flaky"]

    def test_permanent_error_is_not_retried(self):
        calls = []

        def denied(data, cfg, secret):
            calls.append(1)
            raise targets.UploadError("401", retry=False)

        targets.TARGETS["denied"] = denied
        try:
            with self.assertRaises(targets.UploadError):
                targets.publish(DATA, {"type": "denied"}, retries=5, sleep=lambda s: None)
            self.assertEqual(len(calls), 1)
        finally:
            del targets.TARGETS["denied"]

    def test_missing_fields(self):
        for kind in ("s3", "ftp", "sftp", "http", "file", "command", "bunny"):
            with self.assertRaises(targets.UploadError, msg=kind):
                targets.publish(DATA, {"type": kind}, retries=0, secret=fake_secret)


class LocalTargets(unittest.TestCase):
    def test_file_atomic_and_readable(self):
        folder = tempfile.mkdtemp()
        path = os.path.join(folder, "sub", "usage.json")
        targets.publish(DATA, {"type": "file", "path": path})
        targets.publish(DATA + b" ", {"type": "file", "path": path})
        with open(path, "rb") as fh:
            self.assertEqual(fh.read(), DATA + b" ")
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o644)
        self.assertEqual(os.listdir(os.path.dirname(path)), ["usage.json"])

    def test_command(self):
        out = os.path.join(tempfile.mkdtemp(), "copy.json")
        targets.publish(DATA, {"type": "command", "command": ["cp", "{file}", out]})
        with open(out, "rb") as fh:
            self.assertEqual(fh.read(), DATA)

    def test_command_failures(self):
        with self.assertRaises(targets.UploadError):
            targets.publish(DATA, {"type": "command", "command": ["false"]}, retries=0)
        with self.assertRaises(targets.UploadError) as ctx:
            targets.publish(DATA, {"type": "command", "command": ["/nonexistent/tool", "{file}"]}, retries=0)
        self.assertFalse(ctx.exception.retry)

    def test_sftp_command_is_non_interactive_and_has_no_secrets(self):
        argv = targets.sftp_command({"host": "h", "user": "u", "port": 2222, "identityFile": "~/.ssh/k",
                                     "knownHostsFile": "/tmp/kh"})
        joined = " ".join(argv)
        self.assertIn("BatchMode=yes", joined)
        self.assertIn("StrictHostKeyChecking=yes", joined)
        self.assertIn("-P 2222", joined)
        self.assertIn("UserKnownHostsFile=/tmp/kh", joined)
        self.assertEqual(argv[-1], "u@h")


class S3Signing(unittest.TestCase):
    NOW = dt.datetime(2026, 11, 11, 12, 0, 0, tzinfo=dt.timezone.utc)
    CFG = {"endpoint": "https://acc.r2.cloudflarestorage.com", "bucket": "b", "key": "dir/usage.json", "region": "auto"}

    def test_path_style_put(self):
        req = targets.s3_request("PUT", self.CFG, DATA, "AK", "SK", now=self.NOW)
        self.assertEqual(req.full_url, "https://acc.r2.cloudflarestorage.com/b/dir/usage.json")
        auth = req.get_header("Authorization")
        self.assertTrue(auth.startswith("AWS4-HMAC-SHA256 Credential=AK/20261111/auto/s3/aws4_request, "))
        self.assertIn("SignedHeaders=cache-control;content-type;host;x-amz-content-sha256;x-amz-date,", auth)
        self.assertEqual(req.get_header("Content-type"), "application/json")
        self.assertEqual(req.get_header("Cache-control"), "private, max-age=60")
        self.assertEqual(req.get_header("X-amz-date"), "20261111T120000Z")

    def test_virtual_hosted(self):
        req = targets.s3_request("PUT", dict(self.CFG, virtualHosted=True, endpoint="https://s3.eu-west-1.amazonaws.com",
                                             region="eu-west-1"), DATA, "AK", "SK", now=self.NOW)
        self.assertEqual(req.full_url, "https://b.s3.eu-west-1.amazonaws.com/dir/usage.json")

    def test_signature_is_deterministic_and_key_dependent(self):
        a = targets.s3_request("PUT", self.CFG, DATA, "AK", "SK", now=self.NOW).get_header("Authorization")
        b = targets.s3_request("PUT", self.CFG, DATA, "AK", "SK", now=self.NOW).get_header("Authorization")
        c = targets.s3_request("PUT", self.CFG, DATA, "AK", "SK2", now=self.NOW).get_header("Authorization")
        self.assertEqual(a, b)
        self.assertNotEqual(a, c)


class Handler(http.server.BaseHTTPRequestHandler):
    files = {}
    seen = []

    def log_message(self, *args):
        pass

    def do_PUT(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        Handler.seen.append(("PUT", self.path, self.headers.get("Authorization"), self.headers.get("Content-Type")))
        if self.path.startswith("/denied"):
            self.send_response(403)
        else:
            Handler.files[self.path] = body
            self.send_response(201)
        self.end_headers()

    def do_MOVE(self):
        dest = self.headers["Destination"].split("//", 1)[1].split("/", 1)[1]
        Handler.seen.append(("MOVE", self.path, self.headers.get("Overwrite"), "/" + dest))
        Handler.files["/" + dest] = Handler.files.pop(self.path)
        self.send_response(204)
        self.end_headers()


class HttpTarget(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        Handler.files.clear()
        Handler.seen.clear()

    def test_put_with_bearer(self):
        targets.publish(DATA, {"type": "http", "url": self.base + "/usage.json", "token": "tok"}, secret=fake_secret)
        self.assertEqual(Handler.files["/usage.json"], DATA)
        self.assertEqual(Handler.seen[0][2:], ("Bearer t0ken", "application/json"))

    def test_webdav_put_then_move_with_basic(self):
        targets.publish(DATA, {"type": "webdav", "url": self.base + "/dav/usage.json", "username": "me", "password": "pw",
                               "webdavMove": True}, secret=fake_secret)
        self.assertEqual(Handler.files, {"/dav/usage.json": DATA})
        put, move = Handler.seen
        self.assertEqual(put[1], "/dav/usage.json.tmp")
        self.assertEqual(put[2], "Basic " + base64.b64encode(b"me:s3cret").decode())
        self.assertEqual(move, ("MOVE", "/dav/usage.json.tmp", "T", "/dav/usage.json"))

    def test_403_is_permanent(self):
        with self.assertRaises(targets.UploadError) as ctx:
            targets.publish(DATA, {"type": "http", "url": self.base + "/denied"}, retries=3, sleep=lambda s: None)
        self.assertFalse(ctx.exception.retry)
        self.assertEqual(len(Handler.seen), 1)


if __name__ == "__main__":
    unittest.main()


class Hardening(unittest.TestCase):
    """Security review fixes for the upload targets."""

    def test_credentials_require_https(self):
        for target in ({"type": "http", "url": "http://dav.example.com/usage.json", "token": "tok"},
                       {"type": "s3", "endpoint": "http://s3.example.com", "bucket": "b",
                        "accessKeyId": "ak", "secretAccessKey": "sk"}):
            with self.assertRaises(targets.UploadError) as ctx:
                targets.publish(DATA, target, retries=0, secret=fake_secret)
            self.assertIn("https", str(ctx.exception))
            self.assertFalse(ctx.exception.retry)

    def test_loopback_and_explicit_opt_in_allowed(self):
        targets._require_https("http://127.0.0.1:8080/x", {})
        targets._require_https("http://localhost/x", {})
        targets._require_https("http://nas.lan/x", {"allowInsecure": True})
        targets._require_https("https://dav.example.com/x", {})

    def test_sftp_rejects_injection_in_path_and_host(self):
        for path in ('a"\n!touch /tmp/pwned\n"', "a*", "dir/[x].json", "-x", "a\\b"):
            with self.assertRaises(targets.UploadError, msg=path):
                targets.publish(DATA, {"type": "sftp", "host": "h", "user": "u", "path": path}, retries=0)
        for host in ("-oProxyCommand=x", "h;ls", "a b"):
            with self.assertRaises(targets.UploadError, msg=host):
                targets.sftp_command({"host": host, "user": "u"})

    def test_default_cache_is_private(self):
        self.assertTrue(targets.DEFAULT_CACHE_CONTROL.startswith("private"))
