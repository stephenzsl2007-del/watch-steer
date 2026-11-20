if(new URLSearchParams(location.search).get('desktop')==='1')document.body.classList.add('desktop-app');
'use strict';
const $ = id => document.getElementById(id);
let stream, state, receivedAt = 0, target = 0, displayed = 0, lastFrame = performance.now();
let lastSeq = -1, lastSession = '', browserRtt = null, lastLoggedSeq = '', rows = [];
let pingTimer;
let browserAuthenticated = false;
const demo = () => $('demo').checked;
const filePreview = location.protocol === 'file:';
const driving = window.createWatchSteerDriving?.();
$('endpoint').textContent = filePreview ? '本地文件预览 · 可直接开启演示' : location.origin;
if (filePreview) { $('pair-message').textContent = '当前为文件预览；连接手表需启动电脑服务。'; $('token').disabled = true; document.querySelector('#pair-form button').disabled = true; }

function connect() {
  browserAuthenticated = true;
  if (stream) stream.close();
  clearInterval(pingTimer);
  stream = new EventSource('/api/events');
  stream.onopen = () => { $('pair-message').textContent = '已配对 · 网页已连接。手表采样时方向盘会跟随。'; };
  stream.onmessage = event => {
    const next = JSON.parse(event.data);
    const sample = next.sample;
    if (sample) {
      if (sample.session === lastSession && sample.seq < lastSeq) return;
      lastSeq = sample.seq; lastSession = sample.session;
    }
    state = next; receivedAt = performance.now();
    if (sample && lastLoggedSeq !== sample.session + ':' + sample.seq) {
      lastLoggedSeq = sample.session + ':' + sample.seq;
      rows.push([Date.now(), sample.session, sample.seq, sample.steering, sample.angleDeg,
        sample.sampleHz, next.ingestHz, sample.sampleAgeMs, sample.rttMs,
        browserRtt ?? '', next.serverAgeMs, document.visibilityState]);
      if (rows.length > 12000) rows.shift(); // ~10 minutes @20Hz; bounded memory.
    }
  };
  stream.onerror = () => { $('pair-message').textContent = '实时链路重连中；若持续失败，请重新输入令牌。'; };
  ping(); pingTimer = setInterval(ping, 3000);
}

async function ping() {
  const start = performance.now();
  try {
    const response = await fetch('/api/ping', {cache: 'no-store', signal: AbortSignal.timeout(2000)});
    if (!response.ok) {
      if (response.status === 401) { browserAuthenticated = false; $('pair-message').textContent = '网页连接已过期，请从 Mac 接收器重新打开网页。'; }
      throw new Error();
    }
    browserRtt = performance.now() - start;
    $('browser-rtt').textContent = browserRtt.toFixed(1);
  } catch { browserRtt = null; $('browser-rtt').textContent = '—'; }
}

$('pair-form').addEventListener('submit', async event => {
  event.preventDefault();
  try {
    const response = await fetch('/api/login', {method: 'POST',
      headers: {'Content-Type': 'application/json'}, body: JSON.stringify({token: $('token').value.trim()}),
      signal: AbortSignal.timeout(3000)});
    if (!response.ok) throw new Error('令牌不正确，或网页来源与服务配置不符。');
    $('token').value = ''; connect();
  } catch (error) { $('pair-message').textContent = error.message; }
});

$('demo').addEventListener('change', () => {
  $('manual').disabled = !demo();
  $('manual').value = '0';
  target = 0;
});
$('manual').addEventListener('input', () => { if (demo()) target = Number($('manual').value); });
document.addEventListener('keydown', event => {
  if (!demo() || /INPUT|TEXTAREA|SELECT/.test(event.target.tagName)) return;
  if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
    event.preventDefault(); target = event.key === 'ArrowLeft' ? -0.65 : 0.65; $('manual').value = target;
  }
});
document.addEventListener('keyup', event => {
  if (demo() && (event.key === 'ArrowLeft' || event.key === 'ArrowRight')) {
    target = 0; $('manual').value = '0';
  }
});
window.addEventListener('blur', () => { if (demo()) { target = 0; $('manual').value = '0'; } });

function render(now) {
  const dt = Math.min(0.1, Math.max(0, (now - lastFrame) / 1000)); lastFrame = now;
  const s = state?.sample;
  const age = state && state.serverAgeMs !== null ? state.serverAgeMs + now - receivedAt : Infinity;
  const live = Boolean(s && age <= (state?.staleAfterMs ?? 500) && !state?.stale);
  if (!demo()) target = live && s.calibrated ? s.steering : 0;
  // 12 ms visual smoothing; the 500 ms stale watchdog remains unchanged.
  displayed += (target - displayed) * (1 - Math.exp(-dt / 0.012));
  $('wheel').style.transform = `rotateZ(${displayed * 120}deg)`;
  $('wheel').setAttribute('aria-label', `方向盘 ${Math.round(displayed * 120)} 度`);
  $('angle').innerHTML = `${(displayed * 120).toFixed(1)}<span>°</span>`;
  $('steering').textContent = displayed.toFixed(3);
  $('bar-dot').style.left = `${50 + displayed * 50}%`;
  $('bar-fill').style.left = `${50 + Math.min(0, displayed) * 50}%`;
  $('bar-fill').style.width = `${Math.abs(displayed) * 50}%`;
  $('status').textContent = demo() ? '本机演示' : !browserAuthenticated ? '网页未连接' : live ? (s.calibrated ? '手表已连接' : '等待手表校准') : '等待新鲜数据';
  $('led').classList.toggle('live', demo() || live);
  $('mode-label').textContent = demo() ? 'LOCAL DEMO · 模拟数据' : 'LIVE TELEMETRY';
  $('stream-state').textContent = !browserAuthenticated ? '请从 Mac 接收器打开网页' : stream?.readyState === EventSource.OPEN ? (live ? '实时传输' : '网页已连接 · 等待手表采样') : '实时链路重连中';
  $('sample-hz').textContent = demo() || !live ? '—' : s.sampleHz.toFixed(0);
  $('ingest-hz').textContent = demo() || !live ? '—' : state.ingestHz.toFixed(1);
  $('watch-rtt').textContent = demo() || !live ? '—' : s.rttMs.toFixed(0);
  $('age').textContent = Number.isFinite(age) ? Math.round(age).toString() : '—';
  driving?.update({now, dt, steering: target, live, calibrated: Boolean(s?.calibrated), demo: demo()});
  requestAnimationFrame(render);
}
requestAnimationFrame(render);

$('export').addEventListener('click', () => {
  const header = 'browserUnixMs,session,seq,steering,physicalAngleDeg,sampleHz,ingestHz,sampleAgeBeforeSendMs,previousWatchHttpRttMs,browserHttpRttMs,serverAgeAtEventMs,visibility';
  const quote = value => '"' + String(value).replaceAll('"', '""') + '"';
  const csv = header + '\n' + rows.map(row => row.map(quote).join(',')).join('\n');
  const url = URL.createObjectURL(new Blob([csv], {type: 'text/csv;charset=utf-8'}));
  const a = document.createElement('a'); a.href = url; a.download = 'watchsteer-diagnostics.csv'; a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
});
// Native receiver hands the browser a short-lived, single-use read-only ticket.
// Remove it from the visible URL before any request; never store device tokens.
async function boot() {
  if (filePreview) return;
  const ticket = new URLSearchParams(location.hash.slice(1)).get('connect');
  if (ticket) {
    history.replaceState(null, '', location.pathname + location.search);
    try {
      const response = await fetch('/api/browser-redeem', {method: 'POST',
        headers: {'Content-Type': 'application/json'}, body: JSON.stringify({ticket}),
        signal: AbortSignal.timeout(3000)});
      if (!response.ok) throw new Error('网页连接已过期，请从 Mac 接收器重新打开网页。');
      connect(); return;
    } catch (error) { $('pair-message').textContent = error.message; }
  }
  try {
    const response = await fetch('/api/state', {signal: AbortSignal.timeout(3000)});
    if (response.ok) connect();
    else if (!ticket) $('pair-message').textContent = '请在 Mac 接收器中点击“打开方向盘网页”自动连接；也可手动输入令牌。';
  } catch { $('pair-message').textContent = '无法连接电脑服务，请先打开 Mac 接收器。'; }
}
boot();
