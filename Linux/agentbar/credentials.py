"""Read the server user's CLI profiles; never expose credentials through HTTP."""
from __future__ import annotations

import base64
import hashlib
import json
import os
import platform
import shutil
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

from .models import PROVIDERS


def jwt_claims(token):
    try:
        payload = token.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except (ValueError, IndexError, TypeError):
        return {}


def read_json(path):
    with Path(path).open() as stream:
        data = json.load(stream)
    if not isinstance(data, dict):
        raise ValueError("Expected a JSON object")
    return data


@dataclass
class Credential:
    provider: str
    path: Path
    selector: str
    identity: str
    label: str
    token: str = field(repr=False)
    raw: dict = field(repr=False)
    document: dict = field(repr=False)

    @property
    def key(self):
        # 登录切换必须创建独立历史，不能把同一路径下的不同账户合并。
        return hashlib.sha256((self.provider + "::" + self.identity).encode()).hexdigest()


def parse_credentials(provider, path, document, label=None):
    if provider == "codex":
        raw = document.get("tokens") or {}
        token = raw.get("access_token")
        claims = jwt_claims(raw.get("id_token") or token or "")
        profile = claims.get("https://api.openai.com/profile", {})
        auth = claims.get("https://api.openai.com/auth", {})
        account = raw.get("account_id") or auth.get("chatgpt_account_id") or ""
        user = claims.get("sub") or claims.get("email") or profile.get("email") or ""
        identity = (account + ":" + user) if account or user else None
        name = claims.get("email") or profile.get("email") or claims.get("name") or "Codex account"
        rows = [("tokens", raw, token, identity, name)]
    elif provider == "claude":
        raw = document.get("claudeAiOauth") or {}
        token = raw.get("accessToken")
        profile = document.get("oauthAccount") or {}
        identity = profile.get("accountUuid") or jwt_claims(token or "").get("sub")
        rows = [("claudeAiOauth", raw, token, identity, profile.get("emailAddress") or "Claude account")]
    elif provider == "gemini":
        claims = jwt_claims(document.get("id_token", ""))
        rows = [("", document, document.get("access_token"), claims.get("sub") or claims.get("email"),
                 claims.get("email") or "Gemini account")]
    elif provider == "githubCopilot":
        rows = []
        for key, token in (document.get("copilot_tokens") or {}).items():
            host, _, user = key.rpartition(":")
            if host == "https://github.com" and user:
                rows.append((key, {}, token, user, "@" + user))
        rows += [(host, raw, raw.get("oauth_token"), raw.get("user"), "@" + raw.get("user", "GitHub"))
                 for host, raw in document.items() if host.startswith("github.com") and isinstance(raw, dict)]
    else:
        rows = [("", document, document.get("access_token") or document.get("token"),
                 document.get("account_id") or label, label or PROVIDERS[provider])]
    return [Credential(provider, Path(path), selector, str(identity or Path(path).resolve()),
                       label or name, token, raw, document)
            for selector, raw, token, identity, name in rows if isinstance(token, str) and token.strip()]


class CredentialSource:
    def __init__(self, home=None, config=None):
        self.home = Path(home or Path.home())
        self.config = Path(config) if config else None
        self._keyring_cache = None

    def copilot_keyring_tokens(self, config_path):
        signature = (config_path.stat().st_mtime_ns, config_path.stat().st_size)
        now = time.monotonic()
        if self._keyring_cache and self._keyring_cache[0] == signature and self._keyring_cache[1] > now:
            return self._keyring_cache[2]
        tokens = {}
        executable, node = shutil.which("copilot"), shutil.which("node")
        architecture = {"x86_64": "x64", "aarch64": "arm64"}.get(platform.machine())
        if executable and node and architecture:
            native = Path(executable).resolve().parent / "prebuilds" / ("linux-" + architecture) / "keytar.node"
            if native.is_file():
                try:
                    result = subprocess.run([node, str(Path(__file__).with_name("copilot_keyring.cjs")), str(native)],
                                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5, check=True)
                    decoded = json.loads(result.stdout)
                    if isinstance(decoded, dict):
                        tokens = {key: value for key, value in decoded.items() if isinstance(value, str)}
                except (OSError, ValueError, subprocess.SubprocessError):
                    pass
        self._keyring_cache = (signature, now + 15, tokens)
        return tokens

    def discover(self, providers=None):
        if providers is not None and not providers:
            return [], []
        home = self.home
        codex = Path(os.environ.get("CODEX_HOME", str(home / ".codex")))
        claude = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(home / ".claude")))
        config_home = Path(os.environ.get("XDG_CONFIG_HOME", str(home / ".config")))
        copilot = Path(os.environ.get("COPILOT_HOME", str(home / ".copilot")))
        paths = [("codex", codex / "auth.json", None),
                 ("claude", claude / ".credentials.json", None),
                 ("gemini", home / ".gemini/oauth_creds.json", None),
                 ("githubCopilot", copilot / "config.json", None),
                 ("githubCopilot", config_home / "github-copilot/apps.json", None),
                 ("githubCopilot", config_home / "github-copilot/hosts.json", None)]
        errors = []
        if self.config and self.config.exists():
            try:
                for account in read_json(self.config).get("accounts", []):
                    if account["provider"] not in PROVIDERS:
                        raise ValueError("Unknown provider")
                    paths.append((account["provider"], Path(account["credentials_file"]).expanduser(), account.get("label")))
            except (ValueError, OSError, KeyError, TypeError):
                errors.append("Could not read accounts configuration; check the file format and permissions.")
        accounts = {}
        for provider, path, label in paths:
            if providers is not None and provider not in providers:
                continue
            if not path.exists():
                continue
            try:
                if path == copilot / "config.json" and path.stat().st_size == 0:
                    continue
                document = read_json(path)
                if provider == "githubCopilot" and document.get("logged_in_users") and not document.get("store_token_plaintext"):
                    tokens = dict(document.get("copilot_tokens") or {})
                    tokens.update(self.copilot_keyring_tokens(path))
                    document = dict(document, copilot_tokens=tokens)
                if provider == "claude" and not document.get("oauthAccount"):
                    metadata_path = home / ".claude.json"
                    if metadata_path.exists():
                        document = dict(document, oauthAccount=read_json(metadata_path).get("oauthAccount", {}))
                for credential in parse_credentials(provider, path, document, label):
                    accounts.setdefault(credential.key, credential)
            except (OSError, ValueError, TypeError, AttributeError):
                errors.append("Could not read %s credentials; check the local CLI login." % PROVIDERS[provider])
        return list(accounts.values()), errors
