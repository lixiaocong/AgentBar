"""Small authenticated HTTP server; no credential or login-management endpoints."""
from __future__ import annotations

import hashlib
import hmac
import json
import secrets
import ssl
import time
from http.cookies import SimpleCookie, CookieError
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


RANGES = {"hour": 3600, "halfDay": 43200, "day": 86400, "week": 604800, "month": 2592000, "all": None}
ASSETS = {"/": ("index.html", "text/html; charset=utf-8"),
          "/app.js": ("app.js", "text/javascript; charset=utf-8"),
          "/quota-display.js": ("quota-display.js", "text/javascript; charset=utf-8"),
          "/style.css": ("style.css", "text/css; charset=utf-8")}
ASSETS.update({"/provider-logos/" + provider + ".svg": ("provider-logos/" + provider + ".svg", "image/svg+xml")
               for provider in ("codex", "githubCopilot", "gemini", "claude", "zai", "junie")})


def access_key(path):
    path = Path(path)
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with path.open("x") as stream:
            path.chmod(0o600)
            stream.write(secrets.token_urlsafe(32) + "\n")
    value = path.read_text().strip()
    if len(value) < 24:
        raise ValueError("Web access key must contain at least 24 characters")
    path.chmod(0o600)
    return value


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, collector, key):
        super().__init__(address, Handler)
        self.collector = collector
        self.key = key
        self.failed_logins = {}
        import threading
        self.login_lock = threading.Lock()

    def session(self):
        expires = str(int(time.time()) + 12 * 3600)
        signature = hmac.new(self.key.encode(), expires.encode(), hashlib.sha256).hexdigest()
        return expires + "." + signature

    def valid_session(self, value):
        try:
            expires, signature = value.split(".", 1)
            expected = hmac.new(self.key.encode(), expires.encode(), hashlib.sha256).hexdigest()
            return time.time() < int(expires) <= time.time() + 12 * 3600 and hmac.compare_digest(expected, signature)
        except (ValueError, TypeError):
            return False


class Handler(BaseHTTPRequestHandler):
    server_version = "AgentBar"

    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, format, *args):
        # URL、cookie 和请求体都可能包含访问密钥，访问日志不记录这些内容。
        pass

    def respond(self, status, data, content_type="application/json; charset=utf-8", cookie=None):
        body = json.dumps(data).encode() if content_type.startswith("application/json") else data
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        bearer = self.headers.get("Authorization", "")
        if bearer.startswith("Bearer ") and hmac.compare_digest(bearer[7:].encode(), self.server.key.encode()):
            return True
        try:
            cookies = SimpleCookie(self.headers.get("Cookie", ""))
            value = cookies.get("agentbar_session")
            return bool(value and self.server.valid_session(value.value))
        except CookieError:
            return False

    def cookie(self, session):
        secure = "; Secure" if isinstance(self.connection, ssl.SSLSocket) else ""
        return "agentbar_session=%s; Path=/; HttpOnly; SameSite=Strict; Max-Age=%s%s" % (
            session, 43200 if session else 0, secure)

    def do_GET(self):
        path = urlsplit(self.path)
        if path.path in ASSETS:
            filename, mime = ASSETS[path.path]
            self.respond(200, (Path(__file__).parent / "static" / filename).read_bytes(), mime)
            return
        if not self.authorized():
            self.respond(401, {"error": "Enter the server's Web access key to continue."})
            return
        try:
            if path.path == "/api/state":
                self.respond(200, self.server.collector.state())
            elif path.path == "/api/available-accounts":
                self.respond(200, self.server.collector.available_accounts())
            elif path.path == "/api/history/accounts":
                self.respond(200, self.server.collector.history.accounts())
            elif path.path == "/api/history":
                params = parse_qs(path.query)
                key = params.get("account", [""])[0]
                range_name = params.get("range", ["day"])[0]
                if len(key) != 64 or any(c not in "0123456789abcdef" for c in key) or range_name not in RANGES:
                    self.respond(400, {"error": "Invalid account or history range"})
                    return
                self.respond(200, self.server.collector.history.query(key, RANGES[range_name]))
            else:
                self.respond(404, {"error": "Not found"})
        except Exception:
            self.respond(500, {"error": "Could not read history; check server storage."})

    def do_POST(self):
        origin = self.headers.get("Origin")
        if origin and urlsplit(origin).netloc != self.headers.get("Host"):
            self.respond(403, {"error": "Cross-origin requests are not allowed"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 4096 or self.headers.get_content_type() != "application/json":
                raise ValueError()
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise ValueError()
        except (ValueError, OSError):
            self.respond(400, {"error": "Expected a small JSON object"})
            return
        path = urlsplit(self.path).path
        if path == "/api/session":
            address = self.client_address[0]
            with self.server.login_lock:
                now = time.time()
                self.server.failed_logins = {ip: value for ip, value in self.server.failed_logins.items() if value[1] > now - 300}
                count, last = self.server.failed_logins.get(address, (0, now))
                if count >= 10:
                    self.respond(429, {"error": "Too many attempts. Try again in five minutes."})
                    return
                key = body.get("key")
                if not isinstance(key, str) or not hmac.compare_digest(key.encode(), self.server.key.encode()):
                    self.server.failed_logins[address] = (count + 1, last)
                    self.respond(401, {"error": "Incorrect Web access key"})
                    return
                self.server.failed_logins.pop(address, None)
            self.respond(200, {"ok": True}, cookie=self.cookie(self.server.session()))
        elif not self.authorized():
            self.respond(401, {"error": "Session expired. Enter the Web access key again."})
        elif path == "/api/logout":
            self.respond(200, {"ok": True}, cookie=self.cookie(""))
        elif path == "/api/refresh":
            self.server.collector.request_refresh()
            self.respond(202, {"ok": True})
        elif path == "/api/accounts":
            key, enabled = body.get("key"), body.get("enabled")
            if not isinstance(key, str) or len(key) != 64 or not isinstance(enabled, bool):
                self.respond(400, {"error": "Expected an account key and enabled boolean"})
                return
            try:
                self.server.collector.set_account(key, enabled)
                self.respond(200, {"ok": True})
            except ValueError as error:
                self.respond(400, {"error": str(error)})
            except OSError:
                self.respond(500, {"error": "Could not save account selection"})
        else:
            self.respond(404, {"error": "Not found"})
