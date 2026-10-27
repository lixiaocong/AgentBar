"""A continuously running, browser-independent collector with isolated failures."""
from __future__ import annotations

import copy
import hashlib
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from .models import PROVIDERS
from .login_help import login_help
from .providers import ProviderClient, ProviderError


class Collector:
    def __init__(self, source, history, selection, interval=60, client=None):
        self.source, self.history, self.interval = source, history, interval
        self.selection = selection
        self.client = client or ProviderClient()
        self.lock = threading.Lock()
        self.refresh_lock = threading.Lock()
        self.stop_event = threading.Event()
        self.wake = threading.Event()
        self.statuses = {}
        self.errors = []
        self.next_due = {}
        self.failures = {}
        self.credential_versions = {}
        self.started_at = time.time()
        self.thread = None

    def start(self):
        self.thread = threading.Thread(target=self.run, name="quota-collector", daemon=True)
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        self.wake.set()
        if self.thread:
            self.thread.join(timeout=90)

    def request_refresh(self):
        # 浏览器只能唤醒定时器，不能绕过 API 轮询间隔或退避限制。
        self.wake.set()

    def available_accounts(self):
        accounts, errors = self.source.discover()
        selected = self.selection.accounts()
        return dict(accounts=[dict(key=a.key, provider=a.provider, label=a.label,
                                   source=str(a.path), selected=a.key in selected) for a in accounts], errors=errors)

    def set_account(self, key, enabled):
        # 与正在执行的采样串行：移除操作返回后不会再落库该账户的新样本。
        with self.refresh_lock:
            if enabled:
                accounts, errors = self.source.discover()
                account = next((account for account in accounts if account.key == key), None)
                if account is None:
                    raise ValueError("Local credentials are no longer available. Refresh the list.")
                self.selection.set(key, account)
                self.next_due.pop(key, None)
                with self.lock:
                    self.statuses.setdefault(key, dict(key=key, provider=account.provider,
                        label=account.label, snapshot=None, error=None))
            else:
                self.selection.set(key)
                self.next_due.pop(key, None)
                with self.lock:
                    self.statuses.pop(key, None)
        self.wake.set()

    def run(self):
        while not self.stop_event.is_set():
            try:
                self.collect_once()
            except Exception:
                with self.lock:
                    self.errors = ["Collection failed; the next scheduled poll will retry."]
            self.wake.wait(1)
            self.wake.clear()

    def collect_once(self):
        with self.refresh_lock:
            selected = self.selection.accounts()
            providers = {metadata["provider"] for metadata in selected.values()}
            accounts, _ = self.source.discover(providers=providers)
            accounts = [account for account in accounts if account.key in selected]
            keys = {account.key for account in accounts}
            for account in accounts:
                version = hashlib.sha256(account.token.encode()).digest()
                if self.credential_versions.get(account.key) != version:
                    self.credential_versions[account.key] = version
                    self.next_due.pop(account.key, None)
                    self.failures[account.key] = 0
            with self.lock:
                # 完整扫描的诊断属于“添加账户”；后台仅为无法解析的启用账户显示卡片错误。
                self.errors = []
                self.statuses = {key: value for key, value in self.statuses.items() if key in selected}
                for key, metadata in selected.items():
                    if key not in keys:
                        self.statuses[key] = dict(key=key, **metadata, snapshot=None,
                            error="未找到或无法读取此账户的本地凭据。请检查 CLI 登录和文件权限，或移除这个账户。",
                            authHelp=login_help(metadata["provider"]))
                    else:
                        self.statuses.setdefault(key, dict(key=key, **metadata, snapshot=None, error=None))
            due = [account for account in accounts if self.next_due.get(account.key, 0) <= time.time()]
            with ThreadPoolExecutor(max_workers=6) as pool:
                list(pool.map(self.collect_account, due))

    def collect_account(self, account):
        with self.lock:
            state = dict(self.statuses.get(account.key) or dict(
                key=account.key, provider=account.provider, label=account.label, snapshot=None))
        try:
            state["snapshot"] = self.client.load(account)
            state["error"] = None
            state["authHelp"] = None
            self.failures[account.key] = 0
            try:
                self.history.record(account.key, state["snapshot"])
                state["historyError"] = None
            except Exception:
                state["historyError"] = "Could not write quota history; live usage is still available."
        except Exception as error:
            # 不把异常 repr 或上游响应写到日志/API，避免包含 token 或凭据内容。
            if isinstance(error, ProviderError) and error.status == 401:
                state["error"] = "%s 凭据未通过验证（HTTP 401）。请在服务器更新登录。" % PROVIDERS[account.provider]
                state["authHelp"] = login_help(account.provider)
            else:
                state["error"] = str(error) if isinstance(error, ProviderError) else "Could not load usage; check the CLI login and file permissions."
                state["authHelp"] = None
            self.failures[account.key] = min(self.failures.get(account.key, 0) + 1, 6)
        state["lastAttemptAt"] = time.time()
        state["nextPollAt"] = time.time() + min(3600, self.interval * 2 ** self.failures.get(account.key, 0))
        self.next_due[account.key] = state["nextPollAt"]
        with self.lock:
            if account.key in self.selection.accounts():
                self.statuses[account.key] = state

    def state(self):
        with self.lock:
            accounts = sorted(copy.deepcopy(list(self.statuses.values())),
                              key=lambda state: (list(PROVIDERS).index(state["provider"]), state["label"]))
            errors = list(self.errors)
        try:
            history = self.history.stats()
        except Exception:
            history = None
            errors.append("Could not read history statistics.")
        return dict(accounts=accounts, errors=errors, interval=self.interval,
                    startedAt=self.started_at, serverTime=time.time(), history=history)
