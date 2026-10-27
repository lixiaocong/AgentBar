"""JSON models matching AgentBarCore's quota snapshots."""
import math
import re
import time
from datetime import datetime, timezone


PROVIDERS = {
    "codex": "Codex", "githubCopilot": "GitHub Copilot", "gemini": "Gemini",
    "claude": "Claude", "zai": "Z.ai", "junie": "Junie",
}


def timestamp(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return value / 1000 if value > 10_000_000_000 else value
    if isinstance(value, str):
        try:
            numeric = float(value)
            if math.isfinite(numeric):
                return timestamp(numeric)
        except ValueError:
            pass
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return (parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)).timestamp()
    except (ValueError, TypeError):
        return None


def rounded(value):
    return math.floor(value + 0.5)


def metric(key, title, used, reset=None, used_label=None, remaining_label=None, unlimited=False):
    used = float(used)
    if not math.isfinite(used):
        raise ValueError("Invalid quota percentage")
    used = max(0, min(100, used))
    words = re.findall(r"[^\W_]+", title.lower())
    return dict(id=key, title=title, usedPercent=used, remainingPercent=100 - used,
                usedLabel="Unlimited" if unlimited else used_label or "%s%% used" % rounded(used),
                remainingLabel="Unlimited" if unlimited else remaining_label or "%s%% left" % rounded(100 - used),
                resetsAt=timestamp(reset), isUnlimited=unlimited,
                participatesInOverallQuotaStatus=words[:2] != ["gpt", "reserve"])


def snapshot(provider, label, plan, metrics, source, now=None, space=None, reset_credits=None):
    return dict(provider=provider, accountLabel=label, planType=plan, metrics=metrics,
                sourceSummary=source, updatedAt=time.time() if now is None else now,
                spaceLabel=space, resetCredits=reset_credits)
