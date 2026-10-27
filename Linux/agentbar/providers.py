"""Provider API adapters, using the same endpoints and metric IDs as desktop."""
from __future__ import annotations

import json
import re
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, build_opener, HTTPRedirectHandler

from .models import metric, snapshot, timestamp, rounded
from .credentials import jwt_claims


class ProviderError(Exception):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request_json(url, token=None, body=None, headers=None, form=False):
    outgoing = {"Accept": "application/json", "User-Agent": "AgentBar-Linux/1.0"}
    if token:
        outgoing["Authorization"] = token if token.startswith("Bearer ") else "Bearer " + token
    outgoing.update(headers or {})
    data = None
    if body is not None:
        outgoing["Content-Type"] = "application/x-www-form-urlencoded" if form else "application/json"
        data = (urlencode(body) if form else json.dumps(body)).encode()
    try:
        # 不跟随重定向，避免把 Authorization 转发到其他主机。
        with build_opener(NoRedirect).open(Request(url, data=data, headers=outgoing), timeout=20) as response:
            return json.load(response)
    except HTTPError as error:
        message = "Provider returned HTTP %s" % error.code
        if error.code == 429:
            message += "; polling will back off automatically"
        raise ProviderError(message, error.code) from None
    except (URLError, TimeoutError, OSError):
        raise ProviderError("Provider connection failed or timed out") from None
    except (ValueError, TypeError):
        raise ProviderError("Provider returned an invalid JSON response") from None


def window_title(minutes):
    if minutes % 1440 == 0:
        return "%s day window" % (minutes // 1440)
    if minutes % 60 == 0:
        return "%s hour window" % (minutes // 60)
    return "%s minute window" % minutes


def decode_reset_credits(data):
    credits = []
    for item in data.get("credits") or []:
        credits.append(dict(idSuffix=(str(item.get("id") or "reset").strip().split("-")[-1]),
                            status=str(item.get("status") or "unknown").strip(),
                            resetType=item.get("reset_type", item.get("resetType", "codex_rate_limits")),
                            expiresAt=timestamp(item.get("expires_at", item.get("expiresAt")))))
    available = sum(credit["status"].lower() == "available" for credit in credits)
    count = data.get("available_count", data.get("availableCount"))
    return dict(availableCount=max(0, int(count if count is not None else available)), credits=credits)


def codex_space_label(plan, raw=None):
    plan = (plan or "").strip().lower()
    if any(word in plan for word in ("team", "business", "enterprise", "workspace", "edu")):
        kind = next((label for word, label in (("enterprise", "Enterprise"), ("edu", "Education"), ("team", "Team"))
                     if word in plan), "Business")
        if raw and raw.strip().lower() not in ("personal", "personal workspace", "personal org"):
            return re.sub(r"(?i)\s+workspace\s+#\d+$", "", raw.strip()) + " · " + kind
        return kind
    if "pro" in plan:
        return "Personal Pro"
    if "plus" in plan:
        return "Personal Plus"
    return "Personal Free" if plan == "free" else raw


def decode_codex(data, label, now=None, space=None, reset_credits=None):
    metrics = []

    def add(rate, prefix="", title=""):
        for field in ("primary_window", "secondary_window"):
            window = rate.get(field) or {}
            seconds = window.get("limit_window_seconds")
            minutes = int((seconds + 59) // 60) if seconds else window.get("window_duration_mins")
            if minutes and window.get("used_percent") is not None and window.get("reset_at"):
                metrics.append(metric(prefix + "window-%s" % minutes, title + window_title(minutes),
                                      window["used_percent"], window["reset_at"]))

    add(data.get("rate_limit") or {})
    add(data.get("code_review_rate_limit") or {}, "code-review-", "Code review ")
    for index, extra in enumerate(data.get("additional_rate_limits") or [], 1):
        title = extra.get("limit_name")
        if not title:
            title = (extra.get("metered_feature") or "Additional limit %s" % index).replace("_", " ").replace("-", " ").title()
            title = re.sub(r"\bGpt\b", "GPT", title)
        add(extra.get("rate_limit") or {}, "additional-%s-" % index, title + " ")
    if not metrics and not any(key in data for key in ("rate_limit", "credits", "code_review_rate_limit")) and not (reset_credits or {}).get("availableCount"):
        raise ProviderError("Codex response did not contain quota windows")
    return snapshot("codex", label, data.get("plan_type"), metrics, "ChatGPT Codex API", now,
                    codex_space_label(data.get("plan_type"), space), reset_credits)


def decode_copilot(data, label, now=None):
    metrics = []
    titles = {"chat": "Chat / month", "completions": "Completions / month",
              "premium_interactions": "Premium requests / month"}
    for key, quota in (data.get("quota_snapshots") or {}).items():
        if not isinstance(quota, dict):
            continue
        total = quota.get("entitlement") or 0
        unlimited = quota.get("unlimited") is True
        if not unlimited and total <= 0:
            continue
        remaining = quota.get("remaining")
        if remaining is None:
            remaining = rounded(total * float(quota.get("percent_remaining", 0)) / 100)
        remaining = max(0, min(total, remaining))
        used = total - remaining
        metrics.append(metric("github-copilot-" + key.replace("_", "-"),
                              titles.get(key, key.replace("_", " ").title()),
                              used / total * 100 if total else 0, data.get("quota_reset_date_utc"),
                              "%s/%s used" % (used, total), "%s left" % remaining, unlimited))
    if not metrics:
        raise ProviderError("Copilot response did not contain quota windows")
    return snapshot("githubCopilot", "@" + data["login"] if data.get("login") else label,
                    data.get("copilot_plan"), metrics, "GitHub Copilot API", now)


def decode_gemini(assist, quota, label, now=None):
    metrics = []
    for bucket in quota.get("buckets") or []:
        if bucket.get("tokenType") != "REQUESTS":
            continue
        remaining = max(0, min(1, float(bucket.get("remainingFraction", 0))))
        reset = timestamp(bucket.get("resetTime"))
        # 与 macOS 一致：epoch + 空余额代表不可用模型，不应显示为已耗尽。
        if remaining == 0 and reset is not None and reset < 100:
            continue
        model = bucket.get("modelId") or "unknown"
        amount = bucket.get("remainingAmount")
        used_label = remaining_label = None
        if amount is not None:
            amount = int(amount)
            remaining_label = "%s left" % amount
            if remaining > 0:
                total = rounded(amount / remaining)
                used_label = "%s/%s used" % (max(0, total - amount), total)
        metrics.append(metric(model, model.replace("gemini-", "Gemini ", 1).replace("-", " ").title(),
                              (1 - remaining) * 100, reset, used_label, remaining_label))
    tier = assist.get("currentTier") or {}
    plan = {"free-tier": "Free", "legacy-tier": "Legacy", "standard-tier": "Standard"}.get(tier.get("id"), tier.get("name"))
    return snapshot("gemini", label, plan, metrics, "Google Cloud Code Assist API", now)


def decode_claude(data, label, profile=None, now=None):
    profile = profile or {}
    account = profile.get("account") or {}
    org = profile.get("organization") or {}
    titles = {"five_hour": "Session (5h)", "seven_day": "Weekly (all models)",
              "seven_day_opus": "Weekly (Opus)", "seven_day_sonnet": "Weekly (Sonnet)"}
    keys = sorted(data, key=lambda key: (list(titles).index(key) if key in titles else len(titles), key))
    metrics = [metric("claude-" + key, titles.get(key, key.replace("_", " ").title()),
                      data[key]["utilization"], data[key].get("resets_at"))
               for key in keys if isinstance(data[key], dict) and data[key].get("utilization") is not None
               and data[key].get("is_enabled") is not False]
    if not metrics:
        raise ProviderError("Claude response did not contain quota windows")
    plan = profile.get("subscription_type") or org.get("subscription_type")
    return snapshot("claude", account.get("email") or profile.get("email") or label,
                    plan.replace("_", " ").title() if plan else None, metrics, "Claude usage API", now)


def decode_zai(data, label, now=None):
    data = data.get("data") or data
    metrics = []
    units = {1: "second", 2: "minute", 3: "hour", 4: "day", 5: "month", 6: "week"}
    for index, limit in enumerate(data.get("limits") or []):
        kind, unit, number = limit.get("type", "LIMIT"), limit.get("unit"), limit.get("number")
        total = limit.get("total") or limit.get("maximum") or limit.get("limit") or limit.get("usage")
        used = limit.get("currentValue", limit.get("used"))
        remaining = limit.get("remaining")
        percentage = limit.get("percentage")
        if percentage is None:
            percentage = 100 * (used if used is not None else total - remaining) / total if total else 0
        title = {"TOKENS_LIMIT": "Token usage", "TIME_LIMIT": "MCP usage"}.get(kind, kind.replace("_", " ").title())
        if unit and number:
            title += " %s %s window" % (number, units.get(unit, "unit"))
        key = "zai-%s-u%s-n%s-i%s" % (kind.lower().replace("_", "-"), unit, number, index)
        metrics.append(metric(key, title, percentage, limit.get("nextResetTime"),
                              "%s/%s used" % (used, total) if used is not None and total else None,
                              "%s/%s left" % (remaining, total) if remaining is not None and total else None))
    if not metrics:
        raise ProviderError("Z.ai response did not contain quota windows")
    return snapshot("zai", data.get("accountLabel") or label, data.get("level"), metrics, "Z.ai Coding Plan API", now)


def decode_junie(data, label, quota=None, now=None):
    def amount(value):
        return float(value["amount"] if isinstance(value, dict) else value) if value is not None else None
    quota = (quota or {}).get("current") or quota or {}
    remaining = amount(quota.get("current", data.get("balanceLeft")))
    total = amount(quota.get("maximum", data.get("balanceTotal")))
    metrics = []
    if remaining is not None and total and total > 0:
        metrics.append(metric("junie-subscription-quota", "Subscription quota", (1 - remaining / total) * 100,
                              used_label="$%.2f used" % max(0, total - remaining),
                              remaining_label="$%.2f / $%g left" % (remaining, total)))
    return snapshot("junie", data.get("username") or label, (data.get("licenseType") or "").replace("junie_", "").title(),
                    metrics, "Junie API" + (" · balance %s" % remaining if not metrics and remaining is not None else ""), now)


class ProviderClient:
    def __init__(self, request=request_json):
        self.request = request

    def load(self, credential):
        return self.fetch(credential)

    def fetch(self, credential):
        c, get = credential, self.request
        if c.provider == "codex":
            account_id = c.raw.get("account_id")
            headers = {"ChatGPT-Account-Id": account_id} if account_id else {}
            usage = get("https://chatgpt.com/backend-api/wham/usage", c.token, headers=headers)
            reset_credits = None
            try:
                credit_headers = dict(headers, originator="Codex Desktop", **{"OAI-Product-Sku": "CODEX"})
                reset_credits = decode_reset_credits(get("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", c.token, headers=credit_headers))
            except (ProviderError, ValueError, TypeError, AttributeError):
                pass
            auth = jwt_claims(c.raw.get("id_token") or "").get("https://api.openai.com/auth", {})
            organizations = auth.get("organizations") or []
            organization = next((org for org in organizations if org.get("is_default")), organizations[0] if organizations else {})
            return decode_codex(usage, c.label, space=organization.get("title") or organization.get("name"), reset_credits=reset_credits)
        if c.provider == "githubCopilot":
            return decode_copilot(get("https://api.github.com/copilot_internal/user", c.token), c.label)
        if c.provider == "gemini":
            url = "https://cloudcode-pa.googleapis.com/v1internal:"
            assist = get(url + "loadCodeAssist", c.token, body={"metadata": {
                "ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"}})
            project = assist.get("cloudaicompanionProject") or ""
            if isinstance(project, dict):
                project = project.get("id", "")
            quota = get(url + "retrieveUserQuota", c.token, body={"project": project})
            return decode_gemini(assist, quota, c.label)
        if c.provider == "claude":
            headers = {"anthropic-beta": "oauth-2025-04-20"}
            usage = get("https://api.anthropic.com/api/oauth/usage", c.token, headers=headers)
            try:
                profile = get("https://api.anthropic.com/api/oauth/profile", c.token, headers=headers)
            except ProviderError:
                profile = {}
            return decode_claude(usage, c.label, profile)
        if c.provider == "zai":
            return decode_zai(get("https://api.z.ai/api/monitor/usage/quota/limit", c.token), c.label)
        if c.provider == "junie":
            return decode_junie(get("https://ingrazzio-cloud-prod.labs.jb.gg/auth/test", c.token), c.label)
        raise ProviderError("Unsupported provider")
