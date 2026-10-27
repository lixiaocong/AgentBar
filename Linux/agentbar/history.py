"""SQLite history for every successful Linux poll, with desktop confirmation rules.

History is observed quota state, not a token/billing ledger. Only successful
provider responses are recorded; collection never depends on browser traffic.
"""
from __future__ import annotations

import sqlite3
import time
from collections import defaultdict
from contextlib import contextmanager
from pathlib import Path

from .models import rounded


def schedules_equal(a, b):
    old, new = a["resets_at"], b["resets_at"]
    if old is None or new is None:
        return old == new
    return abs(new - old) < 300 or abs((new - b["sampled_at"]) - (old - a["sampled_at"])) < 300


def recovery(a, b):
    return not a["unlimited"] and not b["unlimited"] and a["used"] - b["used"] >= 10


def exhaustion(a, b):
    return not a["unlimited"] and not b["unlimited"] and a["used"] < 10000 <= b["used"]


def normalize(samples):
    # 顺序与 macOS 一致：先过滤瞬时耗尽，再过滤瞬时恢复，再确认重置周期。
    def confirmed(rows, terminal):
        result = []
        for index, current in enumerate(rows):
            previous = result[-1] if result else None
            candidate = previous and (exhaustion(previous, current) if terminal else recovery(previous, current))
            if candidate:
                following = rows[index + 1] if index + 1 < len(rows) else None
                if not following or following["unlimited"] or not schedules_equal(current, following):
                    continue
                if terminal and following["used"] < 10000:
                    continue
                if not terminal and previous["used"] - following["used"] < 10:
                    continue
            result.append(dict(current))
        return result

    result = confirmed(confirmed(samples, True), False)
    stable = None
    for index, current in enumerate(result):
        current["event"] = "initial" if index == 0 else "sample"
        if stable is None or schedules_equal(stable, current):
            stable = current
            continue
        following = result[index + 1] if index + 1 < len(result) else None
        if not following or not schedules_equal(current, following):
            continue
        old, new = stable["resets_at"], current["resets_at"]
        deadline_reached = old is not None and current["sampled_at"] >= old - 120
        if old is not None and ((new is None and deadline_reached) or
                                (new is not None and new - old >= 300 and
                                 (deadline_reached or recovery(stable, current)))):
            current["event"] = "reset"
        stable = current
    return result


def downsample(rows):
    if len(rows) <= 360:
        return rows
    span = max(1, rows[-1]["sampled_at"] - rows[0]["sampled_at"])
    buckets = defaultdict(list)
    for index, row in enumerate(rows):
        buckets[int((row["sampled_at"] - rows[0]["sampled_at"]) / span * 96)].append(index)
    selected = set()
    for indices in buckets.values():
        selected.update((indices[0], indices[-1], min(indices, key=lambda i: rows[i]["used"]),
                         max(indices, key=lambda i: rows[i]["used"])))
        selected.update(i for i in indices if rows[i]["event"] == "reset")
    return [rows[index] for index in sorted(selected)]


class HistoryStore:
    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with self.connect() as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.executescript("""
                CREATE TABLE IF NOT EXISTS accounts (
                    key TEXT PRIMARY KEY, provider TEXT NOT NULL, label TEXT NOT NULL,
                    plan TEXT, first_seen REAL NOT NULL, last_seen REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS windows (
                    id INTEGER PRIMARY KEY, account_key TEXT NOT NULL REFERENCES accounts(key),
                    metric_key TEXT NOT NULL, title TEXT NOT NULL,
                    UNIQUE(account_key, metric_key));
                CREATE TABLE IF NOT EXISTS samples (
                    window_id INTEGER NOT NULL REFERENCES windows(id), sampled_at REAL NOT NULL,
                    used INTEGER NOT NULL, used_label TEXT NOT NULL, remaining_label TEXT NOT NULL,
                    resets_at REAL, unlimited INTEGER NOT NULL, candidate INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(window_id, sampled_at));
                PRAGMA user_version=1;
            """)
        self.path.chmod(0o600)

    @contextmanager
    def connect(self):
        db = sqlite3.connect(str(self.path), timeout=10)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        try:
            with db:
                yield db
        finally:
            db.close()

    def record(self, key, snapshot):
        now = snapshot["updatedAt"]
        if not snapshot["metrics"]:
            return
        with self.connect() as db:
            db.execute("""INSERT INTO accounts VALUES(?,?,?,?,?,?) ON CONFLICT(key) DO UPDATE SET
                label=excluded.label,plan=excluded.plan,last_seen=excluded.last_seen""",
                       (key, snapshot["provider"], snapshot["accountLabel"], snapshot["planType"], now, now))
            for metric in snapshot["metrics"]:
                db.execute("""INSERT INTO windows(account_key,metric_key,title) VALUES(?,?,?)
                    ON CONFLICT(account_key,metric_key) DO UPDATE SET title=excluded.title""",
                           (key, metric["id"], metric["title"]))
                window = db.execute("SELECT id FROM windows WHERE account_key=? AND metric_key=?",
                                    (key, metric["id"])).fetchone()[0]
                row = dict(sampled_at=now, used=rounded(metric["usedPercent"] * 100),
                           used_label=metric["usedLabel"], remaining_label=metric["remainingLabel"],
                           resets_at=metric["resetsAt"], unlimited=int(metric["isUnlimited"]))
                previous = db.execute("SELECT * FROM samples WHERE window_id=? ORDER BY sampled_at DESC LIMIT 1",
                                      (window,)).fetchone()
                candidate = False
                if previous:
                    if now <= previous["sampled_at"]:
                        continue
                    schedule_changed = not schedules_equal(previous, row)
                    candidate = schedule_changed or recovery(previous, row) or exhaustion(previous, row)
                # Linux 服务常驻，每次成功查询都保留实际观测；相同额度也需要时间点。
                # 尖峰和重置仍由查询路径确认，不能用重复的旧快照补造历史。
                db.execute("""INSERT INTO samples(window_id,sampled_at,used,used_label,remaining_label,
                    resets_at,unlimited,candidate) VALUES(?,?,?,?,?,?,?,?)""",
                           (window, now, row["used"], row["used_label"], row["remaining_label"],
                            row["resets_at"], row["unlimited"], int(candidate)))

    def accounts(self):
        with self.connect() as db:
            return [dict(row) for row in db.execute("SELECT * FROM accounts ORDER BY provider,label")]

    def query(self, key, seconds=None, now=None):
        now = time.time() if now is None else now
        start = now - seconds if seconds is not None else None
        result = []
        with self.connect() as db:
            for window in db.execute("SELECT * FROM windows WHERE account_key=? ORDER BY id", (key,)).fetchall():
                raw = db.execute("SELECT * FROM samples WHERE window_id=? ORDER BY sampled_at", (window["id"],)).fetchall()
                rows = normalize(raw)
                preceding = [row for row in rows if start is not None and row["sampled_at"] < start]
                visible = [row for row in rows if (start is None or row["sampled_at"] >= start) and row["sampled_at"] <= now]
                if preceding:
                    # 范围左边界延续最近已知余额，保留实际采样时间以免误称为新测量。
                    visible.insert(0, dict(preceding[-1], sampled_at=start, event="carry",
                                           recorded_at=preceding[-1]["sampled_at"]))
                result.append(dict(id=window["id"], metricKey=window["metric_key"], title=window["title"],
                                   sampleCount=len(visible), samples=downsample(visible)))
        return dict(accountKey=key, start=start, end=now, windows=result)

    def stats(self):
        with self.connect() as db:
            row = db.execute("SELECT COUNT(*) AS sampleCount, MIN(sampled_at) AS oldestSampleAt, MAX(sampled_at) AS latestSampleAt FROM samples").fetchone()
        return dict(row)
