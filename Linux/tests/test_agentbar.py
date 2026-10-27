import base64
import copy
import hashlib
import json
import os
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from agentbar.accounts import AccountSelection
from agentbar.collector import Collector
from agentbar.credentials import CredentialSource, parse_credentials, read_json
from agentbar.history import HistoryStore, normalize, downsample
from agentbar.login_help import login_help
from agentbar.models import metric, snapshot, timestamp
from agentbar.providers import (ProviderClient, ProviderError, decode_codex, decode_copilot,
                               decode_gemini, decode_claude, decode_zai, decode_junie, decode_reset_credits)
from agentbar.server import Server, access_key


FIXTURES = Path(__file__).resolve().parents[2] / "Shared/AgentBarFixtures"


def fixture(name):
    return json.loads((FIXTURES / name).read_text())


def jwt(**claims):
    payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return "header." + payload + ".signature"


def quota(used=20, now=1000, reset=2000, label="dev@example.com", unlimited=False):
    return snapshot("codex", label, "pro", [metric("window-300", "5 hour window", used, reset,
                                                   unlimited=unlimited)], "Test API", now)


class ProviderTests(unittest.TestCase):
    def assert_metrics(self, result, expected):
        self.assertEqual(result["provider"], expected["provider"])
        self.assertEqual(result["planType"], expected["planType"])
        for actual, wanted in zip(result["metrics"], expected["metrics"]):
            for key, value in wanted.items():
                self.assertEqual(actual[key], value, key)

    def test_shared_codex_fixture_and_reserve(self):
        data = fixture("codex/usage-team.json")
        result = decode_codex(data, "Account test")
        self.assertEqual(len(result["metrics"]), 2)
        self.assert_metrics(result, fixture("expected/codex-team.json"))
        data["additional_rate_limits"] = [{"limit_name": "GPT Reserve", "rate_limit": data["rate_limit"]}]
        result = decode_codex(data, "Account test")
        self.assertEqual(len(result["metrics"]), 4)
        self.assertFalse(result["metrics"][2]["participatesInOverallQuotaStatus"])
        with self.assertRaises(ProviderError):
            decode_codex({}, "Test")

    def test_codex_reset_credit_fixture_matches_desktop_dates_and_statuses(self):
        credits = decode_reset_credits(fixture("codex/reset-credits.json"))
        self.assertEqual(credits["availableCount"], 3)
        available = sorted([credit for credit in credits["credits"] if credit["status"] == "available"], key=lambda c: c["expiresAt"])
        self.assertEqual([credit["idSuffix"] for credit in available], ["e2907349", "0284334e"])
        self.assertAlmostEqual(available[1]["expiresAt"], 1785109119.931028, places=3)
        self.assertNotIn("id", credits["credits"][0])
        self.assertEqual(decode_reset_credits({"available_count": None, "credits": fixture("codex/reset-credits.json")["credits"]})["availableCount"], 2)

    def test_codex_reset_credit_fetch_is_read_only_and_optional(self):
        credential = parse_credentials("codex", "/does/not/exist", {"tokens": {"access_token": "fixture-only", "account_id": "fixture"}})[0]
        calls = []
        def request(url, token, **kwargs):
            calls.append((url, kwargs))
            if url.endswith("/usage"):
                return fixture("codex/usage-team.json")
            return fixture("codex/reset-credits.json")
        result = ProviderClient(request).load(credential)
        self.assertEqual(result["resetCredits"]["availableCount"], 3)
        self.assertEqual(calls[-1][1]["headers"]["originator"], "Codex Desktop")
        self.assertEqual(calls[-1][1]["headers"]["OAI-Product-Sku"], "CODEX")
        def unavailable(url, token, **kwargs):
            if url.endswith("/usage"):
                return fixture("codex/usage-team.json")
            raise ProviderError("HTTP 404", 404)
        result = ProviderClient(unavailable).load(credential)
        self.assertEqual(len(result["metrics"]), 2)
        self.assertIsNone(result["resetCredits"])

    def test_codex_space_badges_and_dynamic_reserve_label_match_desktop(self):
        data = fixture("codex/usage-team.json")
        self.assertEqual(decode_codex(data, "Test", space="NewsBreak workspace #1")["spaceLabel"], "NewsBreak · Team")
        data["plan_type"] = "prolite"
        self.assertEqual(decode_codex(data, "Test")["spaceLabel"], "Personal Pro")
        data["additional_rate_limits"] = [{"metered_feature": "gpt_reserve", "rate_limit": data["rate_limit"]}]
        reserve = decode_codex(data, "Test")["metrics"][2]
        self.assertTrue(reserve["title"].startswith("GPT Reserve"))
        self.assertFalse(reserve["participatesInOverallQuotaStatus"])

    def test_copilot_dynamic_unlimited_and_missing_remaining(self):
        data = fixture("copilot/premium.json")
        self.assert_metrics(decode_copilot(data, "Fallback"), fixture("expected/copilot-premium.json"))
        quota = data["quota_snapshots"]["premium_interactions"]
        quota["unlimited"] = True
        self.assertTrue(decode_copilot(data, "Fallback")["metrics"][0]["isUnlimited"])
        quota["unlimited"] = False
        quota.pop("remaining")
        self.assertEqual(decode_copilot(data, "Fallback")["metrics"][0]["usedPercent"], 50)

    def test_gemini_filters_unavailable_epoch_bucket(self):
        result = decode_gemini(fixture("gemini/code-assist-free.json"), fixture("gemini/quota-free.json"), "test@example.com")
        self.assertEqual(len(result["metrics"]), 2)
        self.assert_metrics(result, fixture("expected/gemini-free.json"))

    def test_claude_accepts_new_windows_and_ignores_disabled(self):
        data = fixture("claude/usage.json")
        result = decode_claude(data, "dev@example.com", {"subscription_type": "claude_max"})
        self.assert_metrics(result, fixture("expected/claude-usage.json"))
        data["new_model"] = {"utilization": 3.2}
        data["disabled"] = {"utilization": 100, "is_enabled": False}
        result = decode_claude(data, "Test")
        self.assertIn("claude-new_model", [m["id"] for m in result["metrics"]])
        self.assertNotIn("claude-disabled", [m["id"] for m in result["metrics"]])

    def test_zai_and_junie_balance(self):
        result = decode_zai(fixture("zai/quota-limit.json"), "Z.ai")
        self.assertEqual([m["usedPercent"] for m in result["metrics"]], [8, 37, 25])
        self.assertEqual(result["metrics"][0]["resetsAt"], 1781661646.979)
        result = decode_junie(fixture("junie/auth-info.json"), "Test", fixture("junie/quota.json"))
        self.assert_metrics(result, fixture("expected/junie-pro.json"))
        self.assertEqual(decode_junie({"balanceLeft": 123}, "Test")["metrics"], [])

    def test_expired_credentials_are_only_read_never_refreshed(self):
        credential = parse_credentials("codex", "/does/not/exist", {
            "tokens": {"access_token": "private-test-value", "refresh_token": "refresh-test-value", "account_id": "a"}})[0]
        requests = []
        def request(url, token, **kwargs):
            requests.append(url)
            raise ProviderError("Provider returned HTTP 401", 401)
        with self.assertRaises(ProviderError):
            ProviderClient(request).load(credential)
        self.assertEqual(requests, ["https://chatgpt.com/backend-api/wham/usage"])

    def test_timestamp_offsets_and_percentage_validation(self):
        self.assertEqual(timestamp("2026-01-01T08:00:00+08:00"), timestamp("2026-01-01T00:00:00Z"))
        with self.assertRaises(ValueError):
            metric("x", "x", float("nan"))

    def test_login_commands_are_provider_specific(self):
        self.assertEqual(login_help("codex")["command"], "codex login --device-auth")
        self.assertEqual(login_help("gemini")["command"], "NO_BROWSER=true gemini")
        self.assertEqual(login_help("gemini")["interactiveCommand"], "/auth")
        self.assertEqual(login_help("githubCopilot")["command"], "copilot login")
        self.assertEqual(login_help("claude")["command"], "claude auth login")
        for provider in ("zai", "junie"):
            self.assertIsNone(login_help(provider)["command"])

    def test_copilot_cli_file_and_legacy_login_share_the_same_identity(self):
        legacy = parse_credentials("githubCopilot", "/old/apps.json", {
            "github.com:app": {"user": "monalisa", "oauth_token": "old-test-value"}})[0]
        native = parse_credentials("githubCopilot", "/new/config.json", {
            "copilot_tokens": {"https://github.com:monalisa": "new-test-value", "https://other.invalid:user": "ignored"}})[0]
        self.assertEqual(native.key, legacy.key)
        self.assertEqual(native.token, "new-test-value")


class LocalTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.auth = self.home / ".codex/auth.json"
        self.auth.parent.mkdir()
        self.document = {"auth_mode": "chatgpt", "tokens": {"access_token": "private-test-value", "refresh_token": "refresh-test-value",
                         "account_id": "workspace", "id_token": jwt(sub="first-user", email="test@example.com")}}
        self.auth.write_text(json.dumps(self.document))
        self.env = patch.dict(os.environ, {"CODEX_HOME": str(self.auth.parent), "CLAUDE_CONFIG_DIR": str(self.home / ".claude"),
                                         "COPILOT_HOME": str(self.home / ".copilot"),
                                         "XDG_CONFIG_HOME": str(self.home / ".config")})
        self.env.start()
        self.source = CredentialSource(self.home)
        self.history = HistoryStore(self.root / "data/history.sqlite3")
        self.selection = AccountSelection(self.root / "data/accounts.json")

    def tearDown(self):
        self.env.stop()
        self.temporary.cleanup()

    def enable(self):
        account = self.source.discover()[0][0]
        self.selection.set(account.key, account)
        return account

    def test_discovery_is_read_only_and_identity_survives_token_rotation(self):
        before = self.auth.read_bytes()
        first = self.source.discover()[0][0]
        self.assertEqual(self.auth.read_bytes(), before)
        self.assertNotIn("private-test-value", repr(first))
        document = copy.deepcopy(self.document)
        document["tokens"]["access_token"] = "rotated-test-value"
        self.auth.write_text(json.dumps(document))
        second = self.source.discover()[0][0]
        self.assertEqual(first.key, second.key)
        self.assertEqual(second.token, "rotated-test-value")
        document["tokens"]["id_token"] = jwt(sub="different-user", email="other@example.com")
        self.auth.write_text(json.dumps(document))
        self.assertNotEqual(first.key, self.source.discover()[0][0].key)

    def test_unconfigured_accounts_not_collected_remove_preserves_history_and_login(self):
        calls = []
        class Client:
            def load(self, account):
                calls.append(account.key)
                return quota(now=time.time())
        collector = Collector(self.source, self.history, self.selection, client=Client())
        collector.collect_once()
        self.assertEqual(calls, [])
        account = self.source.discover()[0][0]
        before = self.auth.read_bytes()
        collector.set_account(account.key, True)
        collector.collect_once()
        self.assertEqual(calls, [account.key])
        self.assertEqual(self.history.stats()["sampleCount"], 1)
        collector.set_account(account.key, False)
        collector.collect_once()
        self.assertEqual(calls, [account.key])
        self.assertEqual(collector.state()["accounts"], [])
        self.assertEqual(self.history.accounts()[0]["key"], account.key)
        self.assertEqual(self.auth.read_bytes(), before)
        self.assertEqual(AccountSelection(self.selection.path).accounts(), {})

    def test_scoped_discovery_skips_unselected_provider_credentials(self):
        path = self.home / ".config/github-copilot/apps.json"
        path.parent.mkdir(parents=True)
        path.write_text("invalid test JSON")
        with patch("agentbar.credentials.read_json", wraps=read_json) as reader:
            accounts, errors = self.source.discover(providers={"codex"})
        self.assertEqual([account.provider for account in accounts], ["codex"])
        self.assertEqual(errors, [])
        self.assertNotIn(path, [call.args[0] for call in reader.call_args_list])
        self.assertTrue(any("GitHub Copilot" in error for error in self.source.discover()[1]))
        with patch("agentbar.credentials.read_json", side_effect=AssertionError("No enabled accounts should read no files")):
            self.assertEqual(self.source.discover(providers=set()), ([], []))

    def test_removed_account_scan_error_stays_in_add_dialog_and_active_errors_remain_visible(self):
        codex = self.enable()
        path = self.home / ".config/github-copilot/apps.json"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps({"github.com:app": {"user": "test-user", "oauth_token": "fixture-only"}}))
        copilot = next(account for account in self.source.discover()[0] if account.provider == "githubCopilot")
        self.selection.set(copilot.key, copilot)
        class Client:
            def load(self, account):
                value = quota(now=time.time())
                value["provider"] = account.provider
                return value
        collector = Collector(self.source, self.history, self.selection, client=Client())
        collector.collect_once()
        path.write_text("invalid test JSON")
        collector.collect_once()
        states = {account["key"]: account for account in collector.state()["accounts"]}
        self.assertIsNotNone(states[copilot.key]["error"])
        self.assertEqual(states[copilot.key]["authHelp"]["command"], "copilot login")
        collector.set_account(copilot.key, False)
        with patch("agentbar.credentials.read_json", wraps=read_json) as reader:
            collector.collect_once()
        self.assertNotIn(path, [call.args[0] for call in reader.call_args_list])
        self.assertEqual([account["key"] for account in collector.state()["accounts"]], [codex.key])
        self.assertEqual(collector.state()["errors"], [])
        self.assertTrue(any("GitHub Copilot" in error for error in collector.available_accounts()["errors"]))
        self.assertEqual(collector.state()["errors"], [])
        self.assertEqual(path.read_text(), "invalid test JSON")
        self.assertIn(copilot.key, [account["key"] for account in self.history.accounts()])

    def test_broken_removed_profile_of_an_enabled_provider_does_not_raise_global_error(self):
        self.enable()
        profile = self.home / "removed-codex/auth.json"
        profile.parent.mkdir()
        profile.write_text("invalid test JSON")
        config = self.root / "config.json"
        config.write_text(json.dumps({"accounts": [{"provider": "codex", "credentials_file": str(profile)}]}))
        source = CredentialSource(self.home, config=config)
        class Client:
            def load(self, account):
                return quota(now=time.time())
        collector = Collector(source, self.history, self.selection, client=Client())
        collector.collect_once()
        self.assertEqual(collector.state()["errors"], [])
        self.assertIsNone(collector.state()["accounts"][0]["error"])
        self.assertTrue(collector.available_accounts()["errors"])

    def test_background_sampling_without_browser_and_restart_persistence(self):
        account = self.enable()
        called = threading.Event()
        calls = []
        class Client:
            def load(self, credential):
                calls.append(credential.key)
                if len(calls) >= 2:
                    called.set()
                return quota(used=20 + len(calls), now=time.time())
        collector = Collector(self.source, self.history, self.selection, interval=.03, client=Client())
        collector.start()
        self.assertTrue(called.wait(3))
        collector.stop()
        self.assertGreaterEqual(self.history.stats()["sampleCount"], 2)
        self.assertIn(account.key, AccountSelection(self.selection.path).accounts())
        self.assertEqual(HistoryStore(self.history.path).stats()["sampleCount"], len(calls))

    def test_new_cli_token_resumes_collection_without_waiting_for_error_backoff(self):
        self.enable()
        calls = []
        class Client:
            def load(self, credential):
                calls.append(credential.token)
                if credential.token == "private-test-value":
                    raise ProviderError("Provider returned HTTP 401", 401)
                return quota(now=time.time())
        collector = Collector(self.source, self.history, self.selection, interval=3600, client=Client())
        collector.collect_once()
        self.document["tokens"]["access_token"] = "new-test-value"
        self.auth.write_text(json.dumps(self.document))
        collector.collect_once()
        self.assertEqual(calls, ["private-test-value", "new-test-value"])
        self.assertEqual(self.history.stats()["sampleCount"], 1)

    def test_unauthorized_card_contains_login_instructions_and_success_clears_them(self):
        account = self.enable()
        class Client:
            fail = True
            def load(self, credential):
                if self.fail:
                    raise ProviderError("Provider returned HTTP 401", 401)
                return quota(now=time.time())
        client = Client()
        collector = Collector(self.source, self.history, self.selection, client=client)
        collector.collect_account(account)
        state = collector.state()["accounts"][0]
        self.assertIn("HTTP 401", state["error"])
        self.assertEqual(state["authHelp"]["command"], "codex login --device-auth")
        self.assertNotIn("private-test-value", json.dumps(state))
        client.fail = False
        collector.collect_account(account)
        self.assertIsNone(collector.state()["accounts"][0]["authHelp"])

    def test_copilot_login_file_precedes_stale_legacy_credentials_and_is_read_only(self):
        native_path = self.home / ".copilot/config.json"
        legacy_path = self.home / ".config/github-copilot/apps.json"
        native_path.parent.mkdir(parents=True)
        legacy_path.parent.mkdir(parents=True)
        native_path.write_text(json.dumps({"store_token_plaintext": True,
            "copilot_tokens": {"https://github.com:monalisa": "new-test-value"}}))
        legacy_path.write_text(json.dumps({"github.com:app": {"user": "monalisa", "oauth_token": "stale-test-value"}}))
        before = native_path.read_bytes(), legacy_path.read_bytes()
        accounts, errors = self.source.discover()
        copilot = [a for a in accounts if a.provider == "githubCopilot"]
        self.assertEqual(len(copilot), 1)
        self.assertEqual(copilot[0].token, "new-test-value")
        self.assertEqual(before, (native_path.read_bytes(), legacy_path.read_bytes()))

    def test_copilot_keyring_login_is_discovered_without_exporting_token_to_file(self):
        path = self.home / ".copilot/config.json"
        path.parent.mkdir()
        path.write_text(json.dumps({"logged_in_users": [{"host": "https://github.com", "login": "monalisa"}]}))
        before = path.read_bytes()
        with patch.object(self.source, "copilot_keyring_tokens", return_value={"https://github.com:monalisa": "keyring-test-value"}):
            accounts, errors = self.source.discover()
        copilot = [a for a in accounts if a.provider == "githubCopilot"]
        self.assertEqual(len(copilot), 1)
        self.assertEqual(copilot[0].token, "keyring-test-value")
        self.assertEqual(before, path.read_bytes())
        self.assertNotIn("keyring-test-value", repr(copilot))

    def test_missing_credentials_include_the_correct_login_command(self):
        self.enable()
        self.auth.unlink()
        collector = Collector(self.source, self.history, self.selection)
        collector.collect_once()
        state = collector.state()["accounts"][0]
        self.assertEqual(state["authHelp"]["command"], "codex login --device-auth")

    def test_remove_waits_for_inflight_collection_and_then_stops_future_writes(self):
        account = self.enable()
        started, release = threading.Event(), threading.Event()
        class Client:
            def load(self, credential):
                started.set()
                release.wait(3)
                return quota(now=time.time())
        collector = Collector(self.source, self.history, self.selection, client=Client())
        with ThreadPoolExecutor(max_workers=2) as pool:
            collecting = pool.submit(collector.collect_once)
            self.assertTrue(started.wait(3))
            removing = pool.submit(collector.set_account, account.key, False)
            self.assertFalse(removing.done())
            release.set()
            collecting.result(timeout=3)
            removing.result(timeout=3)
        count = self.history.stats()["sampleCount"]
        collector.collect_once()
        self.assertEqual(self.history.stats()["sampleCount"], count)
        self.assertEqual(collector.state()["accounts"], [])

    def test_failure_isolation_and_history_write_failure_does_not_hide_live_snapshot(self):
        account = self.enable()
        class BrokenHistory:
            def record(self, *args):
                raise OSError("private-test-value")
        class Client:
            def load(self, credential):
                return quota()
        collector = Collector(self.source, BrokenHistory(), self.selection, client=Client())
        collector.collect_account(account)
        state = collector.statuses[account.key]
        self.assertIsNotNone(state["snapshot"])
        self.assertIsNone(state["error"])
        self.assertNotIn("private-test-value", state["historyError"])

    def test_provider_failure_does_not_block_another_account(self):
        first = self.enable()
        second_document = copy.deepcopy(self.document)
        second_document["tokens"]["account_id"] = "second-workspace"
        second = parse_credentials("codex", self.auth, second_document)[0]
        self.selection.set(second.key, second)
        class Source:
            def discover(self, providers=None):
                return [first, second], []
        class Client:
            def load(self, account):
                if account.key == first.key:
                    raise ProviderError("Provider returned HTTP 429", 429)
                return quota(now=time.time())
        collector = Collector(Source(), self.history, self.selection, client=Client())
        collector.collect_once()
        states = {account["key"]: account for account in collector.state()["accounts"]}
        self.assertIsNotNone(states[first.key]["error"])
        self.assertIsNone(states[second.key]["error"])
        self.assertGreater(states[first.key]["nextPollAt"], states[second.key]["nextPollAt"])
        self.assertEqual(self.history.stats()["sampleCount"], 1)

    def test_http_authentication_account_management_and_no_credentials_in_responses(self):
        class Client:
            def load(self, credential):
                return quota(now=time.time())
        collector = Collector(self.source, self.history, self.selection, client=Client())
        key = access_key(self.root / "data/web-access-key")
        server = Server(("127.0.0.1", 0), collector, key)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = "http://127.0.0.1:%s" % server.server_port
        def request(path, data=None, headers=None):
            outgoing = {"Content-Type": "application/json", **(headers or {})}
            return urlopen(Request(base + path, data=json.dumps(data).encode() if data is not None else None, headers=outgoing), timeout=5)
        try:
            with self.assertRaises(HTTPError) as denied:
                request("/api/state")
            self.assertEqual(denied.exception.code, 401)
            with self.assertRaises(HTTPError):
                request("/api/session", {"key": "wrong"})
            response = request("/api/session", {"key": key})
            cookie = response.headers["Set-Cookie"]
            self.assertIn("HttpOnly", cookie)
            self.assertIn("SameSite=Strict", cookie)
            headers = {"Cookie": cookie.split(";", 1)[0]}
            payload = request("/api/available-accounts", headers=headers).read()
            self.assertNotIn(b"private-test-value", payload)
            self.assertNotIn(b"refresh-test-value", payload)
            account = json.loads(payload)["accounts"][0]
            request("/api/accounts", {"key": account["key"], "enabled": True}, headers).close()
            collector.collect_once()
            self.assertNotIn(b"private-test-value", request("/api/state", headers=headers).read())
            self.assertEqual(len(json.load(request("/api/history/accounts", headers=headers))), 1)
            with self.assertRaises(HTTPError) as csrf:
                request("/api/accounts", {"key": account["key"], "enabled": False}, {**headers, "Origin": "https://other.invalid"})
            self.assertEqual(csrf.exception.code, 403)
            request("/api/accounts", {"key": account["key"], "enabled": False}, headers).close()
            self.assertEqual(self.auth.read_text(), json.dumps(self.document))
            self.assertEqual(self.history.stats()["sampleCount"], 1)
            with self.assertRaises(HTTPError) as bad_range:
                request("/api/history?account=" + account["key"] + "&range=bad", headers=headers)
            self.assertEqual(bad_range.exception.code, 400)
            with self.assertRaises(HTTPError):
                request("/../credentials.py", headers=headers)
            self.assertFalse(server.valid_session("0.bad"))
            self.assertFalse(server.valid_session("not-a-session"))
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.store = HistoryStore(Path(self.temporary.name) / "quota-history.sqlite3")
        self.key = hashlib.sha256(b"test-account").hexdigest()

    def tearDown(self):
        self.temporary.cleanup()

    def record(self, used, now, reset=2000, unlimited=False):
        self.store.record(self.key, quota(used, now, reset, unlimited=unlimited))

    def rows(self):
        return self.store.query(self.key, now=100000)["windows"][0]["samples"]

    def test_records_every_successful_poll_including_unchanged_quota_and_restart(self):
        self.record(20, 1000)
        self.record(20, 1060)
        self.record(20, 1120)
        self.assertEqual(self.store.stats()["sampleCount"], 3)
        self.assertEqual([row["sampled_at"] for row in self.rows()], [1000, 1060, 1120])
        self.assertEqual([row["used"] for row in self.rows()], [2000, 2000, 2000])
        self.record(20.01, 1180)
        self.record(20.01, 1180)
        self.assertEqual(self.store.stats()["sampleCount"], 4)
        restarted = HistoryStore(self.store.path)
        restarted.record(self.key, quota(20.01, 1240))
        self.assertEqual(restarted.stats()["sampleCount"], 5)

    def test_recovery_and_schedule_require_confirmation(self):
        self.record(80, 1000)
        self.record(10, 2010, 4000)
        self.assertEqual(len(self.rows()), 1)
        self.record(11, 2020, 4000)
        self.assertEqual([row["event"] for row in self.rows()], ["initial", "reset", "sample"])

    def test_transient_recovery_is_hidden_and_next_poll_confirms_real_recovery(self):
        self.record(70, 1000)
        self.record(20, 1100)
        self.record(70, 1110)
        self.assertEqual([row["used"] for row in self.rows()], [7000, 7000])
        self.record(30, 1200)
        self.record(30, 1210)
        self.assertEqual(self.store.stats()["sampleCount"], 5)
        self.assertEqual(self.rows()[-1]["used"], 3000)

    def test_transient_terminal_exhaustion_is_hidden_real_exhaustion_confirmed(self):
        self.record(20, 1000)
        self.record(100, 1100)
        self.assertEqual(len(self.rows()), 1)
        self.record(20, 1110)
        self.assertEqual([row["used"] for row in self.rows()], [2000, 2000])
        self.record(100, 1200)
        self.record(100, 1210)
        self.assertEqual([row["used"] for row in self.rows()][-2:], [10000, 10000])

    def test_rolling_deadline_and_nil_activation_are_not_resets(self):
        self.record(20, 1000, None)
        self.record(20, 1100, 3000)
        self.record(20, 1110, 3000)
        self.record(21, 2000, 3890)
        self.record(21, 2010, 3900)
        self.assertNotIn("reset", [row["event"] for row in self.rows()])

    def test_deadline_disappearing_after_expiry_is_reset(self):
        self.record(20, 1000)
        self.record(20, 2100, None)
        self.record(20, 2110, None)
        self.assertEqual(self.rows()[1]["event"], "reset")

    def test_range_has_preceding_balance_and_reset_context(self):
        self.record(80, 1000)
        self.record(10, 2010, 4000)
        self.record(11, 2020, 4000)
        result = self.store.query(self.key, seconds=20, now=2025)["windows"][0]["samples"]
        self.assertEqual(result[0]["event"], "carry")
        self.assertEqual(result[0]["recorded_at"], 1000)
        self.assertEqual(result[1]["event"], "reset")

    def test_unlimited_and_removed_dynamic_windows_retained(self):
        self.record(0, 1000, unlimited=True)
        self.record(0, 1010, unlimited=False)
        self.assertEqual(len(self.rows()), 2)
        self.store.record(self.key, snapshot("codex", "Renamed", "pro", [metric("new-window", "New", 10)], "Test", 1020))
        self.assertEqual(len(self.store.query(self.key)["windows"]), 2)
        self.assertEqual(self.store.accounts()[0]["label"], "Renamed")

    def test_downsampling_keeps_extremes_endpoints_and_resets(self):
        rows = [dict(sampled_at=i, used=5000, event="sample") for i in range(1000)]
        rows[111]["used"] = 0
        rows[112]["used"] = 10000
        rows[500]["event"] = "reset"
        sampled = downsample(rows)
        self.assertLess(len(sampled), 400)
        for index in (0, 111, 112, 500, 999):
            self.assertIn(rows[index], sampled)

    def test_concurrent_writes_are_serialized_by_sqlite(self):
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda index: self.store.record(str(index), quota(now=1000)), range(12)))
        self.assertEqual(self.store.stats()["sampleCount"], 12)


if __name__ == "__main__":
    unittest.main()
