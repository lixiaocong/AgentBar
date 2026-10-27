'use strict';

const $ = id => document.getElementById(id);
const names = {codex: 'Codex', githubCopilot: 'GitHub Copilot', gemini: 'Gemini', claude: 'Claude', zai: 'Z.ai', junie: 'Junie'};
const providerStyles = {
  codex: ['OPENAI', 'Codex'], githubCopilot: ['GITHUB', 'Copilot'], gemini: ['GOOGLE', 'Gemini'],
  claude: ['ANTHROPIC', 'Claude'], zai: ['Z.AI', 'GLM'], junie: ['JETBRAINS', 'Junie']
};
const Q = AgentBarQuotaDisplay;
const escapeHTML = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
const fmt = new Intl.NumberFormat('zh-CN');
const date = value => value ? new Date(value * 1000).toLocaleString('zh-CN', {hour12: false}) : '—';
let currentState = null;
let view = 'overview';
let range = 'day';
let authenticated = false;
let updating = false;
let historyRequest = 0;
let historyData = null;
let historyHover = null;
let clockOffset = 0;
const nowSeconds = () => (Date.now() + clockOffset) / 1000;
const providerIcon = provider => `<img src="/provider-logos/${escapeHTML(provider)}.svg" alt="" width="22" height="22">`;

async function api(path, body) {
  const response = await fetch(path, {
    credentials: 'same-origin', cache: 'no-store',
    ...(body !== undefined ? {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)} : {})
  });
  const data = await response.json();
  if (!response.ok) {
    if (response.status === 401 && path !== '/api/session') showLogin();
    throw new Error(data.error || '服务器请求失败');
  }
  return data;
}

function showLogin() {
  authenticated = false;
  historyHover = null;
  $('dashboard').hidden = true;
  $('login').hidden = false;
  if ($('account-dialog').open) $('account-dialog').close();
}

function notice(message) {
  $('notice').textContent = message;
  $('notice').hidden = !message;
}

function quotaBar(metric) {
  const remaining = metric.isUnlimited ? 100 : Math.max(0, 100 - metric.usedPercent);
  const baseline = metric.isUnlimited ? null : Q.baselineRemainingPercent(metric.resetsAt, Q.windowDuration(metric.id, metric.title), nowSeconds());
  return `<div class="progress" role="meter" aria-label="${escapeHTML(metric.title)}剩余配额" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${remaining}" aria-valuetext="${metric.isUnlimited ? 'Unlimited' : `${remaining.toFixed(1)}% left`}">
    <div class="progress-track"><div class="progress-fill" data-width="${remaining}"></div></div>
    ${baseline == null ? '' : `<span class="quota-baseline" data-baseline="${baseline}" title="Baseline ${baseline.toFixed(1)}% · 按剩余工作日时间计算"></span>`}</div>`;
}

function renderMetric(metric) {
  return `<div class="metric quota-scope" data-state="${Q.metricState(metric, nowSeconds())}"><div class="metric-heading"><span class="metric-title" title="${escapeHTML(metric.title)}">${escapeHTML(metric.title)}</span><strong class="metric-value">${escapeHTML(Q.compactRemainingLabel(metric.remainingLabel))}</strong></div>
    ${quotaBar(metric)}<div class="metric-meta"><span>${escapeHTML(metric.usedLabel)}</span>${metric.resetsAt == null ? '' : `<span data-reset-at="${metric.resetsAt}" title="${escapeHTML(date(metric.resetsAt))}">${escapeHTML(Q.resetLabel(metric.resetsAt, nowSeconds()))}</span>`}</div></div>`;
}

function highlightMetric(snapshot) {
  return (snapshot?.metrics || []).filter(metric => metric.participatesInOverallQuotaStatus !== false)
    .reduce((worst, metric) => !worst || metric.usedPercent > worst.usedPercent ? metric : worst, null);
}

function renderResetCredits(resetCredits) {
  if (!resetCredits) return '';
  const credits = Q.availableCredits(resetCredits);
  const count = Math.max(resetCredits.availableCount, credits.length);
  if (count <= 0) return '';
  const creditDate = value => value == null ? 'No expiration' : new Date(value * 1000).toLocaleString(undefined, {dateStyle: 'medium', timeStyle: 'short', hour12: false});
  return `<section class="reset-credits" aria-label="Codex reset credits"><div class="reset-credit-heading"><strong>${count} ${count === 1 ? 'reset' : 'resets'} available</strong>${credits[0]?.expiresAt == null ? '' : `<span>Next ${escapeHTML(creditDate(credits[0].expiresAt))}</span>`}</div>
    ${credits.slice(0, 3).map((credit, index) => `<div class="reset-credit-row"><span>Reset ${index + 1}</span><time ${credit.expiresAt == null ? '' : `datetime="${new Date(credit.expiresAt * 1000).toISOString()}"`}>${escapeHTML(creditDate(credit.expiresAt))}</time></div>`).join('')}</section>`;
}

function renderAccount(account) {
  const snap = account.snapshot;
  const highlight = highlightMetric(snap);
  const state = account.error ? 'empty' : highlight ? Q.metricState(highlight, nowSeconds()) : 'provider';
  const badges = [...new Set((account.provider === 'codex' ? [snap?.spaceLabel, snap?.planType] : [snap?.planType, snap?.spaceLabel])
    .filter(label => label && label.trim() && label.trim().toLowerCase() !== 'prolite'))];
  if (!badges.length && !snap?.metrics.length) badges.push(snap ? 'Ready' : account.error ? 'Error' : 'Loading');
  return `<article class="account-card quota-scope" data-provider="${account.provider}" data-state="${state}"><div class="card-header" title="${snap ? `更新于 ${escapeHTML(date(snap.updatedAt))}` : '尚无成功采样'}"><div class="card-identity"><div class="account-badges">${badges.map(badge => `<span class="plan-pill">${escapeHTML(badge)}</span>`).join('')}</div><h3 class="account-label" title="${escapeHTML(snap?.accountLabel || account.label)}">${escapeHTML(snap?.accountLabel || account.label)}</h3></div><button class="remove-account" data-key="${account.key}" aria-label="移除 ${escapeHTML(account.label)}">移除</button></div>
    ${account.error ? `<p class="card-error error">${escapeHTML(account.error)}${snap ? ' 当前展示上次成功的结果。' : ''}</p>${renderAuthHelp(account.authHelp)}` : ''}
    ${account.historyError ? `<p class="card-error error">${escapeHTML(account.historyError)}</p>` : ''}
    <div class="metrics">${snap ? (snap.metrics.length ? snap.metrics.map(renderMetric).join('') : `<p class="hint">${escapeHTML(snap.sourceSummary)}</p>`) : '<p class="hint">等待服务器采样…</p>'}</div>
    ${renderResetCredits(snap?.resetCredits)}</article>`;
}

function renderProvider(provider, accounts) {
  const snapshots = accounts.map(account => account.snapshot);
  const aggregates = Q.completeAggregates(snapshots).slice(0, 2);
  const highlight = snapshots.map(highlightMetric).filter(Boolean).sort((a, b) => b.usedPercent - a.usedPercent)[0];
  let state = highlight ? Q.metricState(highlight, nowSeconds()) : 'provider';
  if (aggregates.length) state = aggregates.map(metric => Q.metricState(metric, nowSeconds())).sort((a, b) => Q.ranks[b] - Q.ranks[a])[0];
  if (accounts.some(account => account.error)) state = 'empty';
  const [eyebrow, title] = providerStyles[provider];
  const summary = aggregates.length ? `<span class="summary-caption">TOTAL LEFT</span>${aggregates.map(metric => `<div class="provider-total quota-scope" data-state="${Q.metricState(metric, nowSeconds())}"><div><span title="${escapeHTML(metric.title)}">${escapeHTML(metric.title.replace(/(\d+) (day|hour|minute)s? window/ig, (_, count, unit) => count + unit[0]))}</span><strong>${metric.isUnlimited ? 'Unlimited' : `${Number(metric.remainingPercent.toFixed(2))}%`}</strong></div>${quotaBar(metric)}</div>`).join('')}` :
    `<strong class="provider-remaining">${highlight ? `${Math.round(100 - highlight.usedPercent)}%` : snapshots.some(Boolean) ? 'Ready' : accounts.some(account => account.error) ? '!' : '…'}</strong><span class="summary-caption">${highlight ? 'remaining' : snapshots.some(Boolean) ? 'linked' : accounts.some(account => account.error) ? 'error' : 'loading'}</span>`;
  return `<section class="provider-column quota-scope" data-provider="${provider}" data-state="${state}" aria-label="${escapeHTML(title)}"><header class="provider-header"><div class="provider-icon">${providerIcon(provider)}</div><div class="provider-identity"><span class="provider-eyebrow">${eyebrow}</span><h3>${title}</h3><span class="provider-account-count">${accounts.length} ${accounts.length === 1 ? 'account' : 'accounts'}</span></div><div class="provider-summary">${summary}</div></header>${accounts.map(renderAccount).join('')}</section>`;
}

function applyQuotaBars() {
  document.querySelectorAll('[data-width]').forEach(element => { element.style.width = `${Number(element.dataset.width)}%`; });
  document.querySelectorAll('[data-baseline]').forEach(element => { element.style.left = `${Math.min(99.7, Math.max(.3, Number(element.dataset.baseline)))}%`; });
}

function renderAuthHelp(help) {
  if (!help) return '';
  return `<div class="auth-help">${help.command ? `<span>在服务器终端执行</span><pre><code>${escapeHTML(help.command)}</code></pre>` : ''}
    ${help.interactiveCommand ? `<span>进入 CLI 后输入</span><pre><code>${escapeHTML(help.interactiveCommand)}</code></pre>` : ''}
    <p>${escapeHTML(help.instructions)}</p></div>`;
}

function renderState(state) {
  currentState = state;
  clockOffset = state.serverTime * 1000 - Date.now();
  const accounts = state.accounts;
  const errors = accounts.filter(account => account.error).length;
  $('account-count').textContent = accounts.length;
  $('account-badge').textContent = accounts.length;
  $('sample-count').textContent = state.history ? fmt.format(state.history.sampleCount) : '—';
  $('sample-count').title = state.history?.oldestSampleAt ? `开始于 ${date(state.history.oldestSampleAt)}` : '等待首次采样';
  $('sampling-state').textContent = accounts.length ? (errors === accounts.length ? '采样异常' : errors ? '部分异常' : '持续记录中') : '等待添加';
  $('sampling-state').title = `每 ${state.interval} 秒查询 · ${errors ? `${errors} 个账户异常` : '服务端独立采样'}`;
  notice(state.errors.join(' '));
  const providers = [...new Set(accounts.map(account => account.provider))];
  $('account-grid').innerHTML = accounts.length ? providers.map(provider => renderProvider(provider, accounts.filter(account => account.provider === provider))).join('') :
    `<div class="empty-state"><div class="empty-icon" aria-hidden="true">▥</div><h2>把你的 Agent 加进来</h2><p>从服务器已有的 CLI 凭据中选择账户，开始持续记录用量。</p><button id="empty-add" class="primary">＋ 添加第一个账户</button></div>`;
  applyQuotaBars();
}

async function update() {
  if (updating) return;
  updating = true;
  try {
    const state = await api('/api/state');
    authenticated = true;
    $('login').hidden = true;
    $('dashboard').hidden = false;
    renderState(state);
    if (view === 'history') await loadHistoryAccounts();
  } catch (error) {
    if (authenticated) notice('连接失败，页面暂时保留上次结果。' + error.message);
    else if ($('login').hidden) showLogin();
  } finally { updating = false; }
}

async function scanAccounts() {
  $('account-error').textContent = '';
  $('available-accounts').textContent = '正在读取本地凭据…';
  try {
    const result = await api('/api/available-accounts');
    $('available-accounts').innerHTML = result.accounts.length ? result.accounts.map(account => `
      <label class="credential-row"><input type="checkbox" value="${account.key}" ${account.selected ? 'checked disabled' : ''}><div class="provider-icon">${providerIcon(account.provider)}</div><div class="credential-details"><strong>${escapeHTML(names[account.provider])} · ${escapeHTML(account.label)}</strong><small>${escapeHTML(account.source)}</small></div>${account.selected ? '<span>已添加</span>' : ''}</label>`).join('') :
      '<div class="empty-state"><h2>尚未发现可用凭据</h2><p>在服务器上完成 codex login、gemini 或其他 CLI 登录后，点击“重新扫描”。</p></div>';
    $('account-error').textContent = result.errors.join(' ');
  } catch (error) { $('account-error').textContent = error.message; }
}

async function openAccounts() {
  $('account-dialog').showModal();
  await scanAccounts();
}

function setView(next) {
  view = next;
  if (next !== 'history') historyHover = null;
  $('overview').hidden = next !== 'overview';
  $('history').hidden = next !== 'history';
  $('nav-overview').classList.toggle('active', next === 'overview');
  $('nav-history').classList.toggle('active', next === 'history');
  $('page-title').textContent = next === 'overview' ? '用量概览' : '用量历史';
  $('page-subtitle').textContent = next === 'overview' ? '关注剩余额度，把精力留给开发。' : '每一次用量变化，都有迹可循。';
  if (next === 'history') loadHistoryAccounts().catch(error => notice(error.message));
}

async function loadHistoryAccounts() {
  const accounts = await api('/api/history/accounts');
  const selected = $('history-account').value;
  const active = new Set(currentState?.accounts.map(account => account.key) || []);
  $('history-account').innerHTML = accounts.map(account => `<option value="${account.key}" data-provider="${account.provider}">${escapeHTML(names[account.provider])} · ${escapeHTML(account.label)}${active.has(account.key) ? '' : '（已停止采样）'}</option>`).join('');
  if (accounts.some(account => account.key === selected)) $('history-account').value = selected;
  if (!accounts.length) {
    $('history-charts').innerHTML = '<div class="empty-state"><h2>历史记录从首次成功采样开始</h2><p>添加本地账户后，服务器会持续记录用量变化。关闭浏览器不会中断采样。</p></div>';
    return;
  }
  await loadHistory();
}

function chart(window, start, end, width = 800) {
  const rows = window.samples;
  if (!rows.length) return `<article class="chart-card"><h3>${escapeHTML(window.title)}</h3><p class="hint">此时间范围内没有记录。</p></article>`;
  const W = Math.max(200, width);
  const H = Math.round(Math.max(180, Math.min(320, globalThis.innerHeight * .3)));
  const left = 45, right = 12, top = 13, bottom = 28;
  // 新账户只展示已有观测的时间段，避免少量记录挤在整天坐标轴的末端。
  const min = Math.max(start ?? rows[0].sampled_at, rows[0].sampled_at);
  const span = Math.max(1, end - min);
  const x = t => left + Math.max(0, Math.min(1, (t - min) / span)) * (W - left - right);
  const y = used => top + Math.min(100, Math.max(0, used / 100)) / 100 * (H - top - bottom);
  let line = `M ${x(rows[0].sampled_at)} ${y(rows[0].used)}`;
  for (const row of rows.slice(1)) line += ` ${row.event === 'reset' ? 'M' : 'L'} ${x(row.sampled_at)} ${y(row.used)}`;
  const latest = rows[rows.length - 1];
  const grid = [0, 25, 50, 75, 100].map(p => `<line class="chart-grid" x1="${left}" x2="${W - right}" y1="${y((100 - p) * 100)}" y2="${y((100 - p) * 100)}"/><text class="chart-label" x="${left - 8}" y="${y((100 - p) * 100) + 4}" text-anchor="end">${p}%</text>`).join('');
  const resets = rows.filter(row => row.event === 'reset').map(row => `<line class="reset-line" x1="${x(row.sampled_at)}" x2="${x(row.sampled_at)}" y1="${top}" y2="${H - bottom}"><title>已确认重置 ${escapeHTML(date(row.sampled_at))}</title></line>`).join('');
  const ticks = (W < 500 ? [0, .5, 1] : [0, .25, .5, .75, 1]).map(fraction => {
    const t = min + span * fraction;
    const label = new Date(t * 1000).toLocaleString('zh-CN', span > 86400 ? {month: 'numeric', day: 'numeric', hour: '2-digit', hour12: false} : {hour: '2-digit', minute: '2-digit', hour12: false});
    return `<text class="chart-label" x="${x(t)}" y="${H - 7}" text-anchor="${fraction === 0 ? 'start' : fraction === 1 ? 'end' : 'middle'}">${escapeHTML(label)}</text>`;
  }).join('');
  const points = rows.map(row => `<circle class="${rows.length === 1 ? 'chart-point' : 'chart-hit-point'}" cx="${x(row.sampled_at)}" cy="${y(row.used)}" r="${rows.length === 1 ? 3 : 4}"><title>${escapeHTML(date(row.recorded_at || row.sampled_at))} · ${escapeHTML(row.remaining_label)}${row.event === 'carry' ? '（延续此前记录）' : ''}</title></circle>`).join('');
  const provider = $('history-account').selectedOptions[0]?.dataset.provider || 'codex';
  const remaining = 100 - latest.used / 100;
  return `<article class="chart-card" data-history-provider="${provider}"><div class="chart-heading"><div><h3>${escapeHTML(window.title)}</h3>${latest.resets_at > nowSeconds() ? `<span class="history-reset" data-reset-at="${latest.resets_at}" title="${escapeHTML(date(latest.resets_at))}">${escapeHTML(Q.resetLabel(latest.resets_at, nowSeconds()))}</span>` : ''}</div><div class="chart-summary"><small title="最近记录：${escapeHTML(date(latest.recorded_at || latest.sampled_at))}">${fmt.format(window.sampleCount)} 条记录</small><strong data-state="${Q.stateFor(remaining)}">${latest.unlimited ? 'Unlimited' : `${Math.round(remaining)}% left`}</strong></div></div>
    <div class="history-plot"><svg class="history-chart" viewBox="0 0 ${W} ${H}" data-start="${min}" data-end="${end}" tabindex="0" role="img" aria-label="${escapeHTML(window.title)}剩余配额历史，可使用左右方向键查看采样点" aria-describedby="history-tooltip-${window.id}"><title>${escapeHTML(window.title)}剩余配额历史</title>${grid}<path class="chart-line" d="${line}"/>${resets}${points}${ticks}
      <g class="chart-selection" hidden aria-hidden="true"><line class="chart-selection-line" y1="${top}" y2="${H - bottom}"/><circle class="chart-selection-point" r="4"/></g>
      <rect class="chart-hover-surface" x="${left}" y="${top}" width="${W - left - right}" height="${H - top - bottom}"/></svg>
      <div id="history-tooltip-${window.id}" class="chart-tooltip" role="tooltip" aria-live="polite" hidden></div></div></article>`;
}

function bindHistoryHover(card, window) {
  const svg = card.querySelector('.history-chart');
  if (!svg) return;
  const plot = card.querySelector('.history-plot');
  const tooltip = card.querySelector('.chart-tooltip');
  const selection = svg.querySelector('.chart-selection');
  const rule = selection.querySelector('line');
  const point = selection.querySelector('circle');
  const surface = svg.querySelector('.chart-hover-surface');
  const bounds = {left: surface.x.baseVal.value, top: surface.y.baseVal.value,
    width: surface.width.baseVal.value, height: surface.height.baseVal.value};
  const start = Number(svg.dataset.start), end = Number(svg.dataset.end);
  const span = Math.max(1, end - start);
  const rows = window.samples;
  let selected = -1;

  function hide() {
    tooltip.hidden = true;
    selection.setAttribute('hidden', '');
    selected = -1;
    if (svg.isConnected && historyHover?.windowID === window.id) historyHover = null;
  }

  function show(index) {
    const row = rows[index];
    const remaining = Math.max(0, 100 - row.used / 100);
    const x = bounds.left + Math.max(0, Math.min(1, (row.sampled_at - start) / span)) * bounds.width;
    const y = bounds.top + (100 - remaining) / 100 * bounds.height;
    rule.setAttribute('x1', x); rule.setAttribute('x2', x);
    point.setAttribute('cx', x); point.setAttribute('cy', y);
    selection.removeAttribute('hidden');
    tooltip.hidden = false;
    if (selected !== index) {
      tooltip.dataset.state = row.unlimited ? 'healthy' : Q.stateFor(remaining);
      const value = row.unlimited ? 'Unlimited' : `${Number(remaining.toFixed(2))}%`;
      tooltip.innerHTML = `<time datetime="${new Date((row.recorded_at || row.sampled_at) * 1000).toISOString()}">${escapeHTML(date(row.recorded_at || row.sampled_at))}</time>
        <div class="chart-tooltip-value"><span>剩余配额</span><strong>${value}</strong></div>
        <div class="chart-tooltip-labels">${escapeHTML(row.remaining_label || '')}${row.used_label && row.used_label !== row.remaining_label ? `<span>${escapeHTML(row.used_label)}</span>` : ''}</div>
        ${row.event === 'carry' ? '<span class="chart-tooltip-carry">延续此前采样</span>' : ''}`;
      selected = index;
    }
    const box = svg.getBoundingClientRect();
    const scaleX = box.width / svg.viewBox.baseVal.width;
    const scaleY = box.height / svg.viewBox.baseVal.height;
    const left = x * scaleX + (x < svg.viewBox.baseVal.width / 2 ? 12 : -tooltip.offsetWidth - 12);
    const above = y * scaleY - tooltip.offsetHeight - 12;
    tooltip.style.left = `${Math.max(4, Math.min(plot.clientWidth - tooltip.offsetWidth - 4, left))}px`;
    tooltip.style.top = `${Math.max(4, Math.min(plot.clientHeight - tooltip.offsetHeight - 4, above >= 4 ? above : y * scaleY + 12))}px`;
  }

  function move(clientX, clientY) {
    const box = svg.getBoundingClientRect();
    const x = (clientX - box.left) / box.width * svg.viewBox.baseVal.width;
    const y = (clientY - box.top) / box.height * svg.viewBox.baseVal.height;
    // 浏览器指针和 SVG 坐标有亚像素舍入，端点保留半像素命中容差。
    if (x < bounds.left - .5 || x > bounds.left + bounds.width + .5 || y < bounds.top - .5 || y > bounds.top + bounds.height + .5) return hide();
    const time = start + Math.max(0, Math.min(1, (x - bounds.left) / bounds.width)) * span;
    const index = rows.reduce((nearest, row, i) => Math.abs(row.sampled_at - time) < Math.abs(rows[nearest].sampled_at - time) ? i : nearest, 0);
    historyHover = {windowID: window.id, clientX, clientY};
    show(index);
  }

  svg.addEventListener('pointermove', event => move(event.clientX, event.clientY));
  svg.addEventListener('pointerdown', event => move(event.clientX, event.clientY));
  svg.addEventListener('pointerleave', event => { if (event.pointerType !== 'touch') hide(); });
  svg.addEventListener('pointercancel', hide);
  svg.addEventListener('blur', hide);
  svg.addEventListener('keydown', event => {
    if (event.altKey || event.ctrlKey || event.metaKey) return;
    if (event.key === 'Escape') return hide();
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const index = event.key === 'Home' ? 0 : event.key === 'End' ? rows.length - 1 :
      selected < 0 ? (event.key === 'ArrowLeft' ? rows.length - 1 : 0) : Math.max(0, Math.min(rows.length - 1, selected + (event.key === 'ArrowLeft' ? -1 : 1)));
    historyHover = {windowID: window.id, sampledAt: rows[index].sampled_at};
    show(index);
  });
  if (historyHover?.windowID === window.id) {
    if (historyHover.clientX != null) move(historyHover.clientX, historyHover.clientY);
    else show(rows.reduce((nearest, row, index) => Math.abs(row.sampled_at - historyHover.sampledAt) < Math.abs(rows[nearest].sampled_at - historyHover.sampledAt) ? index : nearest, 0));
  }
}

function renderHistoryCharts(data) {
  const container = $('history-charts');
  const hovered = historyHover;
  const focusedTooltip = document.activeElement?.classList.contains('history-chart')
    ? document.activeElement.getAttribute('aria-describedby') : null;
  container.innerHTML = data.windows.map(window => chart(window, data.start, data.end)).join('');
  Array.from(container.children).forEach((card, index) => {
    const style = getComputedStyle(card);
    const width = card.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
    card.outerHTML = chart(data.windows[index], data.start, data.end, width);
  });
  // 替换旧 SVG 时 blur 会清掉交互状态；刷新后恢复原来的选点和键盘焦点。
  historyHover = hovered;
  Array.from(container.children).forEach((card, index) => bindHistoryHover(card, data.windows[index]));
  if (focusedTooltip) container.querySelector(`[aria-describedby="${CSS.escape(focusedTooltip)}"]`)?.focus({preventScroll: true});
}

async function loadHistory() {
  const account = $('history-account').value;
  if (!account) return;
  const requestId = ++historyRequest;
  const data = await api(`/api/history?account=${encodeURIComponent(account)}&range=${range}`);
  if (requestId !== historyRequest || view !== 'history') return;
  historyData = data;
  renderHistoryCharts(data);
}

let resizeTimer;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    if (view === 'history' && historyData) {
      renderHistoryCharts(historyData);
    }
  }, 100);
});

$('login-form').addEventListener('submit', async event => {
  event.preventDefault();
  const button = event.submitter || $('login-form').querySelector('button');
  button.disabled = true;
  $('login-error').textContent = '';
  try {
    await api('/api/session', {key: $('access-key').value});
    $('access-key').value = '';
    await update();
  } catch (error) { $('login-error').textContent = error.message; }
  finally { button.disabled = false; }
});
$('add-account').addEventListener('click', openAccounts);
$('close-dialog').addEventListener('click', () => $('account-dialog').close());
$('reload-credentials').addEventListener('click', scanAccounts);
$('save-accounts').addEventListener('click', async () => {
  $('save-accounts').disabled = true;
  try {
    for (const input of $('available-accounts').querySelectorAll('input:checked:not(:disabled)')) {
      await api('/api/accounts', {key: input.value, enabled: true});
    }
    $('account-dialog').close();
    await update();
  } catch (error) { $('account-error').textContent = error.message; }
  finally { $('save-accounts').disabled = false; }
});
$('account-grid').addEventListener('click', async event => {
  const remove = event.target.closest('.remove-account');
  if (event.target.closest('#empty-add')) return openAccounts();
  if (!remove) return;
  remove.disabled = true;
  try { await api('/api/accounts', {key: remove.dataset.key, enabled: false}); await update(); }
  catch (error) { notice(error.message); remove.disabled = false; }
});
$('nav-overview').addEventListener('click', () => setView('overview'));
$('nav-history').addEventListener('click', () => setView('history'));
$('history-account').addEventListener('change', () => {
  historyHover = null;
  loadHistory().catch(error => notice(error.message));
});
$('ranges').addEventListener('click', event => {
  const button = event.target.closest('[data-range]');
  if (!button) return;
  range = button.dataset.range;
  historyHover = null;
  for (const item of $('ranges').children) item.classList.toggle('active', item === button);
  loadHistory().catch(error => notice(error.message));
});
$('refresh').addEventListener('click', async () => {
  $('refresh').disabled = true;
  try { await api('/api/refresh', {}); await update(); }
  catch (error) { notice(error.message); }
  finally { $('refresh').disabled = false; }
});
$('disconnect').addEventListener('click', async () => {
  try { await api('/api/logout', {}); showLogin(); }
  catch (error) { notice(error.message); }
});
update();
setInterval(() => { if (authenticated && !document.hidden) update(); }, 10000);
document.addEventListener('visibilitychange', () => { if (authenticated && !document.hidden) update(); });
setInterval(() => {
  if (authenticated && !document.hidden) document.querySelectorAll('[data-reset-at]').forEach(element => {
    element.textContent = Q.resetLabel(Number(element.dataset.resetAt), nowSeconds());
  });
}, 1000);
