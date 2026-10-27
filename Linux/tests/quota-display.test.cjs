'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const Q = require('../agentbar/static/quota-display.js');
const at = value => Date.parse(value) / 1000;
const near = (actual, expected) => assert.ok(Math.abs(actual - expected) < .000001, `${actual} != ${expected}`);
function inZone(zone, fn) {
  const previous = process.env.TZ;
  process.env.TZ = zone;
  try { fn(); } finally { if (previous == null) delete process.env.TZ; else process.env.TZ = previous; }
}

test('desktop RGB palette and fallback percentage boundaries', () => {
  assert.deepEqual(Q.colors, {healthy: '#33c759', warning: '#e0a814', low: '#ff9400', empty: '#ff3b30'});
  for (const [value, state] of [[100, 'healthy'], [75, 'healthy'], [74.99, 'warning'], [45, 'warning'], [44.99, 'low'], [20, 'low'], [19.99, 'empty'], [0, 'empty']]) {
    assert.equal(Q.stateFor(value), state);
  }
});

test('desktop seven-day and five-hour schedule states and exact boundaries', () => inZone('UTC', () => {
  const now = at('2026-09-04T00:00:00Z'), reset = now + 3 * 86400;
  near(Q.baselineRemainingPercent(reset, 7 * 86400, now), 20);
  for (const [remaining, state] of [[25, 'healthy'], [20, 'healthy'], [15, 'low'], [10, 'low'], [9, 'empty']]) assert.equal(Q.stateFor(remaining, reset, 7 * 86400, now), state);
  const midday = at('2026-09-02T12:00:00Z');
  near(Q.baselineRemainingPercent(midday + 2.5 * 3600, 5 * 3600, midday), 50);
  assert.equal(Q.stateFor(49, midday + 2.5 * 3600, 5 * 3600, midday), 'low');
  assert.equal(Q.stateFor(24, midday + 2.5 * 3600, 5 * 3600, midday), 'empty');
}));

test('fresh windows, monthly normalization, weekends and partial weekdays match desktop', () => inZone('UTC', () => {
  const end = at('2026-09-07T00:00:00Z');
  near(Q.baselineRemainingPercent(end, 7 * 86400, end - 7 * 86400), 100);
  near(Q.baselineRemainingPercent(end, 7 * 86400, end - 8 * 86400), 100);
  near(Q.baselineRemainingPercent(end, 30 * 86400, at('2026-09-04T00:00:00Z')), 5);
  for (const now of ['2026-09-05T00:00:00Z', '2026-09-06T12:00:00Z', '2026-09-07T00:00:00Z']) near(Q.baselineRemainingPercent(at('2026-09-08T00:00:00Z'), 7 * 86400, at(now)), 20);
  near(Q.baselineRemainingPercent(at('2026-09-05T17:00:00Z'), 5 * 3600, at('2026-09-05T12:00:00Z')), 0);
  for (const [now, reset, expected] of [
    ['2026-09-04T22:00:00Z', '2026-09-05T02:00:00Z', 2 / 3 * 100],
    ['2026-09-06T22:00:00Z', '2026-09-07T02:00:00Z', 100],
    ['2026-09-07T01:00:00Z', '2026-09-07T02:00:00Z', 50]
  ]) near(Q.baselineRemainingPercent(at(reset), 5 * 3600, at(now)), expected);
}));

test('browser local timezone and daylight-saving boundaries match native tests', () => {
  const now = at('2026-09-04T15:00:00Z'), reset = at('2026-09-04T20:00:00Z');
  inZone('Asia/Shanghai', () => {
    near(Q.baselineRemainingPercent(reset, 10 * 3600, now), 100 / 6);
    assert.equal(Q.stateFor(25, reset, 10 * 3600, now), 'healthy');
  });
  inZone('UTC', () => assert.equal(Q.stateFor(25, reset, 10 * 3600, now), 'low'));
  for (const [zone, current, end, expected] of [
    ['America/New_York', '2026-03-06T00:00:00-05:00', '2026-03-09T00:00:00-04:00', 20],
    ['America/New_York', '2026-10-30T00:00:00-04:00', '2026-11-02T00:00:00-05:00', 24 / 119 * 100],
    ['America/Santiago', '2026-09-04T00:00:00-04:00', '2026-09-07T00:00:00-03:00', 20]
  ]) inZone(zone, () => near(Q.baselineRemainingPercent(at(end), 7 * 86400, at(current)), expected));
});

test('unknown or expired schedules fall back and unlimited remains healthy', () => {
  const now = 1700000000;
  for (const [reset, duration] of [[null, 18000], [now - 1, 18000], [now + 60, null]]) assert.equal(Q.stateFor(60, reset, duration, now), 'warning');
  for (const duration of [0, -1, Infinity, NaN]) assert.equal(Q.baselineRemainingPercent(now + 1, duration, now), null);
  assert.equal(Q.metricState({id: 'unknown', title: 'Unknown', usedPercent: 100, isUnlimited: true}), 'healthy');
});

test('window identifiers and titles use desktop duration rules', () => {
  for (const [id, title, hours] of [['window-300', '5 hour window', 5], ['gpt-5-3-codex-spark-window-10080', 'GPT-5.3-Codex-Spark 7 day window', 168], ['claude-five_hour', 'Session (5h)', 5], ['claude-seven_day_opus', 'Opus weekly', 168], ['zai-token-limit', 'Token usage 5 hour window', 5], ['copilot', 'Premium requests / month', 720]]) assert.equal(Q.windowDuration(id, title), hours * 3600);
  assert.equal(Q.windowDuration('gemini-2.5-pro', 'Gemini 2.5 Pro'), null);
});

test('reset labels include a relative duration and the local reset clock time', () => inZone('Asia/Shanghai', () => {
  const now = at('2026-10-27T04:00:00Z');
  assert.equal(Q.resetLabel(now + 86400 + 3660, now), 'Resets 1 day, 1 hr at 13:01');
  assert.equal(Q.resetLabel(now + 125, now), 'Resets 2 min, 5 sec at 12:02');
  assert.match(Q.resetLabel(now - 60, now), /1 min ago at 11:59$/);
  assert.equal(Q.resetLabel(null, now), '');
}));

test('credit status filtering and expiry ordering match desktop', () => {
  assert.deepEqual(Q.availableCredits({credits: [
    {idSuffix: 'used', status: 'redeemed', expiresAt: 1}, {idSuffix: 'late', status: 'available', expiresAt: 20},
    {idSuffix: 'none', status: ' AVAILABLE ', expiresAt: null}, {idSuffix: 'first', status: 'available', expiresAt: 10}
  ]}).map(credit => credit.idSuffix), ['first', 'late', 'none']);
  assert.equal(Q.compactRemainingLabel('  $120.50 / $200 left  '), '$120.50/$200 left');
  assert.equal(Q.compactRemainingLabel('50 monthly credits left'), '50 left');
});

test('provider totals require all matching windows and exclude GPT reserve', () => {
  const metric = {id: 'window-10080', title: '7 day window', usedPercent: 20, resetsAt: 2000};
  const reserve = {...metric, id: 'reserve', participatesInOverallQuotaStatus: false};
  const first = {metrics: [metric, reserve]}, second = {metrics: [{...metric, usedPercent: 80, resetsAt: 1000}]};
  const totals = Q.completeAggregates([first, second]);
  assert.equal(totals.length, 1);assert.equal(totals[0].remainingPercent, 50);assert.equal(totals[0].resetsAt, 1000);
  assert.deepEqual(Q.completeAggregates([first, null]), []);
  assert.deepEqual(Q.completeAggregates([first, {metrics: []}]), []);
});
