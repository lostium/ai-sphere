"""Upload targets for the AI Sphere publisher: where `usage.json` goes.

Each target takes the JSON bytes and puts them somewhere the watch can GET them over HTTPS with the
`X-Key` header. Serving (TLS, the X-Key check, Content-Type, cache) is the host's job; see hosting/.

Targets (the `type` of `target` in ~/.config/ai-sphere/publish.json):

  bunny    Bunny Storage zone (HTTP PUT with the zone password).
  s3       Any S3-compatible bucket: Cloudflare R2, AWS S3, Backblaze B2, MinIO, Wasabi… (SigV4 PUT).
  http     Plain HTTP PUT: WebDAV (Nextcloud, Apache, nginx), a Cloudflare Worker, your own endpoint.
  ftp      FTP over TLS (FTPS) by default; plain FTP only with "tls": false.
  sftp     SFTP with an SSH key, through the system `sftp` (batch mode, no prompts).
  command  Any command, e.g. rclone; "{file}" is replaced by the path of the JSON file.
  file     Copy to a local path (a folder served by a local web server, or for testing).

Secrets are referenced, never written in the config:
  "keychain:NAME" (or just "NAME")  macOS Keychain generic password with service NAME
  "env:NAME"                        environment variable NAME

Standard library only; Python 3.9.
"""
import base64
import datetime as dt
import ftplib
import hashlib
import hmac
import io
import logging
import os
import re
import ssl
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Dict, List, Optional

log = logging.getLogger("aisphere")

USER_AGENT = "ai-sphere-sync/1"
# "private": the file is only served with the X-Key, so a shared cache must not reuse the response.
DEFAULT_CACHE_CONTROL = "private, max-age=60"
TIMEOUT = 20

SecretResolver = Callable[[str], str]


class UploadError(RuntimeError):
    """Upload failed. `retry` is False for errors that will not fix themselves (bad credentials, bad config)."""

    def __init__(self, message: str, retry: bool = True) -> None:
        super().__init__(message)
        self.retry = retry


# --------------------------------------------------------------------------- secrets

def keychain_secret(service: str) -> str:
    proc = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", service, "-w"],
                          capture_output=True, text=True)
    if proc.returncode != 0 or not proc.stdout.strip():
        raise UploadError(f"Keychain item '{service}' not found or not readable", retry=False)
    return proc.stdout.strip()


def resolve_secret(ref: str) -> str:
    """Resolve "keychain:NAME", "env:NAME" or a bare Keychain service name."""
    if ref.startswith("env:"):
        value = os.environ.get(ref[4:], "")
        if not value:
            raise UploadError(f"environment variable {ref[4:]} is not set", retry=False)
        return value
    if ref.startswith("keychain:"):
        ref = ref[9:]
    return keychain_secret(ref)


LOOPBACK = {"127.0.0.1", "::1", "localhost"}


def _require_https(url: str, cfg: Dict[str, Any]) -> None:
    """Credentials must not travel in clear: https only, except on this machine or with "allowInsecure"."""
    parts = urllib.parse.urlsplit(url)
    if parts.scheme == "https" or (parts.scheme == "http" and (parts.hostname in LOOPBACK or cfg.get("allowInsecure"))):
        return
    raise UploadError(f"target '{cfg.get('type')}' needs an https:// URL (got {parts.scheme or 'none'}://)", retry=False)


def _require(cfg: Dict[str, Any], *keys: str) -> None:
    missing = [k for k in keys if not cfg.get(k)]
    if missing:
        raise UploadError(f"target '{cfg.get('type')}' needs: {', '.join(missing)}", retry=False)


# --------------------------------------------------------------------------- HTTP helper

def _http(method: str, url: str, data: Optional[bytes], headers: Dict[str, str]) -> int:
    request = urllib.request.Request(url, data=data, method=method,
                                     headers=dict(headers, **{"User-Agent": USER_AGENT}))
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return response.status
    except urllib.error.HTTPError as exc:
        raise UploadError(f"{method} failed: HTTP {exc.code}", retry=exc.code not in (400, 401, 403, 404, 405)) from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise UploadError(f"{method} failed: {exc}") from exc


# --------------------------------------------------------------------------- targets

def put_bunny(data: bytes, cfg: Dict[str, Any], secret: SecretResolver) -> str:
    _require(cfg, "storageZone")
    host = cfg.get("storageHost") or "storage.bunnycdn.com"
    path = cfg.get("path") or "usage.json"
    password = secret(cfg.get("password") or "ai-sphere-bunny-storage")
    status = _http("PUT", f"https://{host}/{cfg['storageZone']}/{path}", data,
                   {"AccessKey": password, "Content-Type": "application/json"})
    return f"{cfg['storageZone']}/{path} (HTTP {status})"


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _hmac(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def s3_request(method: str, cfg: Dict[str, Any], data: bytes, access_key: str, secret_key: str,
               now: Optional[dt.datetime] = None) -> urllib.request.Request:
    """Build a SigV4-signed S3 request (path-style by default, virtual-hosted with "virtualHosted": true)."""
    endpoint = urllib.parse.urlsplit(cfg["endpoint"])
    scheme, host = endpoint.scheme or "https", endpoint.netloc
    bucket, key = cfg["bucket"], (cfg.get("key") or "usage.json").lstrip("/")
    quoted_key = urllib.parse.quote(key, safe="/-_.~")
    if cfg.get("virtualHosted"):
        host = f"{bucket}.{host}"
        path = f"/{quoted_key}"
    else:
        path = f"/{bucket}/{quoted_key}"
    region = cfg.get("region") or "auto"
    now = now or dt.datetime.now(dt.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    day = now.strftime("%Y%m%d")
    payload_hash = _sha256(data)

    headers = {"host": host, "x-amz-content-sha256": payload_hash, "x-amz-date": amz_date}
    if method == "PUT":
        headers["content-type"] = "application/json"
        headers["cache-control"] = cfg.get("cacheControl") or DEFAULT_CACHE_CONTROL
    signed = sorted(headers)
    canonical = "\n".join([
        method, path, "",
        "".join(f"{name}:{headers[name].strip()}\n" for name in signed),
        ";".join(signed), payload_hash])
    scope = f"{day}/{region}/s3/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, _sha256(canonical.encode("utf-8"))])
    signing_key = _hmac(_hmac(_hmac(_hmac(("AWS4" + secret_key).encode("utf-8"), day), region), "s3"), "aws4_request")
    signature = hmac.new(signing_key, to_sign.encode("utf-8"), hashlib.sha256).hexdigest()

    out = {name.title(): value for name, value in headers.items() if name != "host"}
    out["Authorization"] = (f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, "
                            f"SignedHeaders={';'.join(signed)}, Signature={signature}")
    out["User-Agent"] = USER_AGENT
    return urllib.request.Request(f"{scheme}://{host}{path}", data=data if method == "PUT" else None,
                                  method=method, headers=out)


def put_s3(data: bytes, cfg: Dict[str, Any], secret: SecretResolver) -> str:
    _require(cfg, "endpoint", "bucket", "accessKeyId", "secretAccessKey")
    _require_https(cfg["endpoint"], cfg)
    request = s3_request("PUT", cfg, data, secret(cfg["accessKeyId"]), secret(cfg["secretAccessKey"]))
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            status = response.status
    except urllib.error.HTTPError as exc:
        detail = exc.read(300).decode("utf-8", "replace")
        code = detail.split("<Code>")[1].split("</Code>")[0] if "<Code>" in detail else ""
        raise UploadError(f"S3 PUT failed: HTTP {exc.code} {code}".strip(),
                          retry=exc.code not in (400, 403, 404)) from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise UploadError(f"S3 PUT failed: {exc}") from exc
    return f"{cfg['bucket']}/{cfg.get('key') or 'usage.json'} (HTTP {status})"


def put_http(data: bytes, cfg: Dict[str, Any], secret: SecretResolver) -> str:
    _require(cfg, "url")
    _require_https(cfg["url"], cfg)
    headers = {"Content-Type": "application/json"}
    headers.update(cfg.get("headers") or {})
    if cfg.get("token"):
        headers["Authorization"] = "Bearer " + secret(cfg["token"])
    elif cfg.get("username"):
        pair = f"{cfg['username']}:{secret(cfg['password'])}" if cfg.get("password") else f"{cfg['username']}:"
        headers["Authorization"] = "Basic " + base64.b64encode(pair.encode("utf-8")).decode("ascii")
    url = cfg["url"]
    if cfg.get("webdavMove"):
        # Upload under a temporary name, then MOVE over the real one, so readers never see half a file.
        tmp = url + ".tmp"
        _http("PUT", tmp, data, headers)
        move = {k: v for k, v in headers.items() if k != "Content-Type"}
        move.update({"Destination": url, "Overwrite": "T"})
        status = _http("MOVE", tmp, None, move)
    else:
        status = _http("PUT", url, data, headers)
    return f"{urllib.parse.urlsplit(url).path} (HTTP {status})"


def put_ftp(data: bytes, cfg: Dict[str, Any], secret: SecretResolver) -> str:
    _require(cfg, "host", "user")
    use_tls = cfg.get("tls", True)
    path = cfg.get("path") or "usage.json"
    folder, name = os.path.split(path)
    tmp = name + ".tmp"
    password = secret(cfg["password"]) if cfg.get("password") else ""
    if use_tls:
        # ftplib's default TLS context does not verify the server; this one does.
        context = ssl.create_default_context(cafile=os.path.expanduser(cfg["caFile"]) if cfg.get("caFile") else None)
        if cfg.get("verifyTls") is False:
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
        ftp = ftplib.FTP_TLS(timeout=TIMEOUT, context=context)
    else:
        ftp = ftplib.FTP(timeout=TIMEOUT)
    try:
        ftp.connect(cfg["host"], int(cfg.get("port") or 21))
        ftp.login(cfg["user"], password)
        if use_tls:
            ftp.prot_p()  # encrypt the data channel too
        ftp.set_pasv(cfg.get("passive", True))
        if folder:
            ftp.cwd(folder)
        ftp.storbinary(f"STOR {tmp}", io.BytesIO(data))
        try:
            ftp.rename(tmp, name)
        except ftplib.error_perm:
            # Some servers refuse to rename over an existing file.
            try:
                ftp.delete(name)
            except ftplib.error_perm:
                pass
            ftp.rename(tmp, name)
        ftp.quit()
    except ftplib.error_perm as exc:
        raise UploadError(f"FTP failed: {exc}", retry=not str(exc).startswith("530")) from exc
    except (ftplib.Error, OSError, EOFError) as exc:
        raise UploadError(f"FTP failed: {exc or type(exc).__name__}") from exc
    finally:
        try:
            ftp.close()
        except Exception:  # noqa: BLE001
            pass
    return f"{'ftps' if use_tls else 'ftp'}://{cfg['host']}/{path}"


def sftp_command(cfg: Dict[str, Any]) -> List[str]:
    for field in ("user", "host"):
        if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9._-]*", str(cfg.get(field) or "")):
            raise UploadError(f"sftp {field} contains characters that are not allowed", retry=False)
    cmd = ["/usr/bin/sftp", "-b", "-", "-q",
           "-o", "BatchMode=yes",
           "-o", f"StrictHostKeyChecking={cfg.get('strictHostKeyChecking', 'yes')}",
           "-o", f"ConnectTimeout={TIMEOUT}",
           "-P", str(cfg.get("port") or 22)]
    if cfg.get("identityFile"):
        cmd += ["-i", os.path.expanduser(cfg["identityFile"]), "-o", "IdentitiesOnly=yes"]
    if cfg.get("knownHostsFile"):
        cmd += ["-o", f"UserKnownHostsFile={os.path.expanduser(cfg['knownHostsFile'])}"]
    cmd.append(f"{cfg['user']}@{cfg['host']}")
    return cmd


def put_sftp(data: bytes, cfg: Dict[str, Any], secret: SecretResolver) -> str:
    _require(cfg, "host", "user")
    path = cfg.get("path") or "usage.json"
    # The path goes into an sftp batch file: refuse anything that could break out of the quotes,
    # start a new command or act as a wildcard.
    if any(c in path for c in '"\\\n\r*?[]') or path.startswith(("-", "!")):
        raise UploadError("sftp path contains characters that are not allowed", retry=False)
    with tempfile.NamedTemporaryFile("wb", suffix=".json", delete=False) as fh:
        fh.write(data)
        local = fh.name
    try:
        # OpenSSH's `rename` uses posix-rename when the server supports it, which replaces atomically.
        batch = f'put "{local}" "{path}.tmp"\nrename "{path}.tmp" "{path}"\n'
        proc = subprocess.run(sftp_command(cfg), input=batch, capture_output=True, text=True, timeout=TIMEOUT * 3)
    except subprocess.TimeoutExpired as exc:
        raise UploadError("SFTP timed out") from exc
    finally:
        os.unlink(local)
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout).strip().splitlines()
        message = err[-1] if err else f"exit {proc.returncode}"
        permanent = any(s in message for s in ("Permission denied", "Host key verification failed", "No such file"))
        raise UploadError(f"SFTP failed: {message}", retry=not permanent)
    return f"sftp://{cfg['host']}/{path}"


def put_command(data: bytes, cfg: Dict[str, Any], secret: SecretResolver) -> str:
    _require(cfg, "command")
    command = cfg["command"]
    if not isinstance(command, list) or not command:
        raise UploadError("target 'command' needs \"command\": a list of arguments", retry=False)
    with tempfile.TemporaryDirectory() as tmpdir:
        local = os.path.join(tmpdir, "usage.json")
        with open(local, "wb") as fh:
            fh.write(data)
        argv = [str(a).replace("{file}", local) for a in command]
        try:
            proc = subprocess.run(argv, capture_output=True, text=True, timeout=int(cfg.get("timeoutSeconds") or 60))
        except FileNotFoundError as exc:
            raise UploadError(f"command not found: {argv[0]}", retry=False) from exc
        except subprocess.TimeoutExpired as exc:
            raise UploadError("command timed out") from exc
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout).strip().splitlines()
        raise UploadError(f"command failed (exit {proc.returncode}): {err[-1] if err else ''}")
    return f"{os.path.basename(argv[0])} (exit 0)"


def put_file(data: bytes, cfg: Dict[str, Any], secret: SecretResolver) -> str:
    _require(cfg, "path")
    path = os.path.expanduser(cfg["path"])
    folder = os.path.dirname(path) or "."
    try:
        os.makedirs(folder, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=folder, prefix=".usage-", suffix=".tmp")
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.chmod(tmp, int(str(cfg.get("mode") or "644"), 8))
        os.replace(tmp, path)
    except OSError as exc:
        raise UploadError(f"file copy failed: {exc}", retry=False) from exc
    return path


TARGETS = {
    "bunny": put_bunny,
    "s3": put_s3,
    "http": put_http,
    "webdav": put_http,
    "ftp": put_ftp,
    "sftp": put_sftp,
    "command": put_command,
    "file": put_file,
}


def publish(data: bytes, target: Dict[str, Any], retries: int = 2,
            secret: SecretResolver = resolve_secret, sleep: Callable[[float], None] = time.sleep) -> str:
    """Upload with retries (5 s, 10 s…). Returns a short description for the log."""
    kind = str(target.get("type") or "")
    func = TARGETS.get(kind)
    if func is None:
        raise UploadError(f"unknown target type '{kind}' (choose one of: {', '.join(sorted(TARGETS))})", retry=False)
    attempt = 0
    while True:
        attempt += 1
        try:
            return func(data, target, secret)
        except UploadError as exc:
            if not exc.retry or attempt > retries:
                raise
            log.warning("%s upload: %s; retrying", kind, exc)
        sleep(5 * attempt)


# --------------------------------------------------------------------------- config

def load_publish_config(config_dir: str, path: Optional[str] = None) -> Dict[str, Any]:
    """Read publish.json, or build the same structure from the older bunny.json.

    Returns {"publicUrl": str, "watchKey": secret ref, "target": {...}}.
    """
    import json
    path = path or os.path.join(config_dir, "publish.json")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            cfg = json.load(fh)
        if not isinstance(cfg, dict) or not isinstance(cfg.get("target"), dict):
            raise UploadError(f"{path} needs a \"target\" object", retry=False)
        cfg.setdefault("watchKey", "ai-sphere-watch-key")
        return cfg

    legacy = os.path.join(config_dir, "bunny.json")
    if os.path.exists(legacy):
        with open(legacy, encoding="utf-8") as fh:
            bunny = json.load(fh)
        keychain = bunny.get("keychain") or {}
        remote = bunny.get("remotePath") or "usage.json"
        return {
            "publicUrl": f"https://{bunny['cdnHost']}/{remote}" if bunny.get("cdnHost") else "",
            "watchKey": keychain.get("watchKey") or "ai-sphere-watch-key",
            "target": {
                "type": "bunny",
                "storageZone": bunny.get("storageZone"),
                "storageHost": bunny.get("storageHost"),
                "path": remote,
                "password": keychain.get("storagePassword") or "ai-sphere-bunny-storage",
            },
        }
    raise UploadError(f"no publish config: create {path} (see hosting/README.md)", retry=False)
