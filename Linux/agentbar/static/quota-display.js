// 对齐 AgentQuotaDisplayColor.swift 与 Windows Models.cs；日期按浏览器本地时区计算。
'use strict';

(() => {
  const colors = {healthy: '#33c759', warning: '#e0a814', low: '#ff9400', empty: '#ff3b30'};
  const ranks = {healthy: 0, warning: 1, low: 2, empty: 3};
  const clamp = value => Math.max(0, Math.min(100, value));

  function windowDuration(id, title) {
    const trailing = /(?:^|-)window-(\d+)$/i.exec(id);
    if (trailing && Number(trailing[1]) > 0) return Number(trailing[1]) * 60;
    const normalized = id.toLowerCase().replace(/-/g, '_');
    if (normalized.includes('five_hour')) return 5 * 3600;
    if (normalized.includes('seven_day')) return 7 * 86400;
    const tokens = title.toLowerCase().split(/[^\p{L}\p{N}.]+/u).filter(Boolean);
    const units = {second: 1, minute: 60, hour: 3600, day: 86400, week: 7 * 86400, month: 30 * 86400};
    const short = {s: 1, m: 60, h: 3600, d: 86400, w: 7 * 86400};
    for (let index = 0; index < tokens.length; index++) {
      const value = Number(tokens[index]);
      const unit = tokens[index + 1]?.replace(/s$/, '');
      if (value > 0 && units[unit]) return value * units[unit];
      const compact = /^(\d+(?:\.\d+)?)([smhdw])$/.exec(tokens[index]);
      if (compact) return Number(compact[1]) * short[compact[2]];
    }
    const lower = title.toLowerCase();
    if (lower.includes('weekly')) return 7 * 86400;
    if (lower.includes('monthly') || lower.includes('/ month')) return 30 * 86400;
    return null;
  }

  function weekdayTime(start, end) {
    let cursor = start;
    let duration = 0;
    while (cursor < end) {
      const date = new Date(cursor * 1000);
      const midnight = new Date(date.getFullYear(), date.getMonth(), date.getDate() + 1).getTime() / 1000;
      const next = Math.min(midnight, end);
      if (next <= cursor) break;
      if (date.getDay() !== 0 && date.getDay() !== 6) duration += next - cursor;
      cursor = next;
    }
    return duration;
  }

  function baselineRemainingPercent(reset, duration, now = Date.now() / 1000) {
    if (reset == null || !Number.isFinite(reset) || !Number.isFinite(duration) || duration <= 0 || reset <= now) return null;
    const start = reset - duration;
    const total = weekdayTime(start, reset);
    if (total <= 0) return 0;
    return clamp(weekdayTime(Math.max(now, start), reset) / total * 100);
  }

  function stateFor(remaining, reset = null, duration = null, now = Date.now() / 1000) {
    const baseline = baselineRemainingPercent(reset, duration, now);
    if (baseline !== null) {
      if (clamp(remaining) < baseline / 2) return 'empty';
      if (clamp(remaining) < baseline) return 'low';
      return 'healthy';
    }
    if (remaining >= 75) return 'healthy';
    if (remaining >= 45) return 'warning';
    if (remaining >= 20) return 'low';
    return 'empty';
  }

  function metricState(metric, now = Date.now() / 1000) {
    if (metric.isUnlimited) return 'healthy';
    return stateFor(100 - metric.usedPercent, metric.resetsAt, windowDuration(metric.id, metric.title), now);
  }

  function compactRemainingLabel(value) {
    return value.trim().replace(/ \/ /g, '/').replace(/ monthly credits left$/i, ' left');
  }

  function resetLabel(reset, now = Date.now() / 1000) {
    if (reset == null) return '';
    const delta = reset - now;
    let seconds = Math.floor(Math.abs(delta));
    const pieces = [];
    for (const [size, unit] of [[86400, 'day'], [3600, 'hr'], [60, 'min'], [1, 'sec']]) {
      const amount = Math.floor(seconds / size);
      if (amount) {
        pieces.push(`${amount} ${unit === 'day' && amount !== 1 ? 'days' : unit}`);
        seconds %= size;
      }
      if (pieces.length === 2) break;
    }
    const relative = pieces.length ? pieces.join(', ') + (delta < 0 ? ' ago' : '') : 'now';
    const time = new Date(reset * 1000).toLocaleTimeString(undefined, {hour: '2-digit', minute: '2-digit', hour12: false});
    return `Resets ${relative} at ${time}`;
  }

  function availableCredits(resetCredits) {
    return (resetCredits?.credits || []).filter(credit => credit.status.trim().toLowerCase() === 'available')
      .sort((a, b) => (a.expiresAt ?? Infinity) - (b.expiresAt ?? Infinity) || a.idSuffix.localeCompare(b.idSuffix));
  }

  function completeAggregates(snapshots) {
    if (snapshots.length <= 1 || snapshots.some(snapshot => !snapshot)) return [];
    const normalize = title => title.trim().replace(/\s+/g, ' ').toLowerCase();
    return snapshots[0].metrics.filter(metric => metric.participatesInOverallQuotaStatus !== false).flatMap(first => {
      const matches = snapshots.map(snapshot => snapshot.metrics.find(metric => metric.id === first.id && normalize(metric.title) === normalize(first.title)));
      if (matches.some(metric => !metric)) return [];
      const remaining = matches.reduce((sum, metric) => sum + clamp(100 - metric.usedPercent), 0) / snapshots.length;
      const resets = matches.map(metric => metric.resetsAt).filter(value => value != null);
      return [{...first, usedPercent: 100 - remaining, remainingPercent: remaining,
        isUnlimited: matches.some(metric => metric.isUnlimited), resetsAt: resets.length ? Math.min(...resets) : null}];
    });
  }

  const api = {colors, ranks, windowDuration, baselineRemainingPercent, stateFor, metricState,
    compactRemainingLabel, resetLabel, availableCredits, completeAggregates};
  globalThis.AgentBarQuotaDisplay = api;
  if (typeof module !== 'undefined') module.exports = api;
})();
