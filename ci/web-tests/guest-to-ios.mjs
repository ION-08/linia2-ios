#!/usr/bin/env node
// Линия 2.0 — «гость по ссылке → приложение iOS» для Linia2GuestLinkCallTests (CI, e2e-часть uitest.yml).
// Владелец — пользователь iOS-теста (L2_LOGIN/L2_PASSWORD, ci-пользователь): скрипт входит в Tinode его логином,
// создаёт постоянную аудиоссылку (POST /call/api/links, как web-tests/calls-regress.mjs режим link-web), гость —
// headless Chrome (поддельный микрофон) открывает ссылку и звонит. Сценарии — по очереди, синхронизация через L2_SYNC_DIR:
//   iOS пишет guest-ready-N (готов принять звонок N) → гость звонит (до 3 попыток) → ICE connected у гостя →
//   guest-connected-N (метка времени; в сценариях «фон» — iOS по ней видит, что ответ ушёл и соединилось в фоне) →
//   bytesReceived аудио у гостя растёт → ждём ios-phase-N (iOS проверил у себя звук в обе стороны, в т.ч. после
//   перехода на WKWebView) → снова ICE connected и рост байтов у гостя → iOS кладёт трубку → у гостя «Звонок завершён».
//   1 — приложение на экране; 2 — в фоне (ответ сразу, нативный движок); 3 — в фоне + переход на WKWebView.
// Код выхода 0 — все сценарии прошли; stdout — JSON-итог; stderr — ход работы; скриншоты — в OUT_DIR.
// env: L2_LOGIN, L2_PASSWORD, CI_TOKEN, L2_SYNC_DIR, OUT_DIR, BASE, SCENARIOS (3), READY_WAIT_S (1500), ANSWER_WAIT_S (60).
// Нужен Node 22+ (встроенный WebSocket и fetch), сторонние пакеты не нужны.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';

const BASE = (process.env.BASE || 'https://v2.chat-linia.site').replace(/\/$/, '');
const OUT = process.env.OUT_DIR || path.resolve('guest-to-ios-out');
const SYNC_DIR = process.env.L2_SYNC_DIR || '';
const N = +(process.env.SCENARIOS || 3), READY_WAIT_S = +(process.env.READY_WAIT_S || 1500), ANSWER_WAIT_S = +(process.env.ANSWER_WAIT_S || 60);
const LOGIN = process.env.L2_LOGIN, PASS = process.env.L2_PASSWORD;
const APIKEY = 'AQEAAAABAAD_rAp4DJh05a1HAwFT3A6K';
fs.mkdirSync(OUT, { recursive: true });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const log = (...a) => console.error(new Date().toISOString().slice(11, 19), ...a);
const result = { ok: false, steps: [], calls: [], error: null, shots: [] };
function step(name, ok, detail = '') { result.steps.push({ name, ok: !!ok, detail: String(detail).slice(0, 300) }); log((ok ? 'OK  ' : 'FAIL') + ' ' + name + (detail ? ' — ' + detail : '')); return !!ok; }
function syncWrite(name, ms) { if (!SYNC_DIR) return; try { fs.mkdirSync(SYNC_DIR, { recursive: true }); fs.writeFileSync(path.join(SYNC_DIR, name + '.txt'), String(ms)); } catch {} }
function syncRead(name) { try { const v = +fs.readFileSync(path.join(SYNC_DIR, name + '.txt'), 'utf8').trim(); return v > 0 ? v : null; } catch { return null; } }
async function waitSync(name, after, ms) { const end = Date.now() + ms; for (;;) { const v = syncRead(name); if (v && v >= after - 1000) return v; if (Date.now() > end) return null; await sleep(500); } }
const day = () => new Date().toISOString().slice(0, 10).replace(/-/g, '');
const ciHeaderOf = () => process.env.CI_TOKEN ? crypto.createHmac('sha256', process.env.CI_TOKEN).update('linia2-ci:' + day()).digest('hex') : '';
let chromeProc = null, tmpProfile = null, linkId = null, token = null;
async function api(method, p, body) {
  const r = await fetch(BASE + '/call/api' + p, { method, headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json', 'X-L2-CI': ciHeaderOf() }, body: body ? JSON.stringify(body) : undefined });
  return r.json();
}
async function finish(code) {
  try { if (linkId && token) { const d = await api('DELETE', '/links/' + linkId); step('уборка: ссылка удалена', !!d.ok); } } catch {}
  try { if (chromeProc) chromeProc.kill('SIGKILL'); } catch {}
  try { if (tmpProfile) fs.rmSync(tmpProfile, { recursive: true, force: true }); } catch {}
  process.stdout.write(JSON.stringify(result) + '\n');
  process.exit(code);
}
process.on('SIGINT', () => { result.error = 'прервано'; finish(2); });
process.on('SIGTERM', () => { result.error = 'прервано'; finish(2); });
function tinodeLogin(login, pass) {
  return new Promise((res, rej) => {
    const ws = new WebSocket(BASE.replace(/^http/, 'ws') + '/v0/channels?apikey=' + APIKEY, { headers: { 'X-L2-CI': ciHeaderOf() } });
    const send = o => ws.send(JSON.stringify(o));
    const timer = setTimeout(() => { try { ws.close(); } catch {} rej(new Error('таймаут Tinode')); }, 20000);
    ws.onopen = () => send({ hi: { id: '1', ver: '0.25' } });
    ws.onerror = () => { clearTimeout(timer); rej(new Error('ошибка WebSocket')); };
    ws.onmessage = ev => { const m = JSON.parse(ev.data); if (!m.ctrl) return;
      if (m.ctrl.id === '1') send({ login: { id: '2', scheme: 'basic', secret: Buffer.from(login + ':' + pass).toString('base64') } });
      else if (m.ctrl.id === '2') { clearTimeout(timer); try { ws.close(); } catch {} if (m.ctrl.code >= 300) rej(new Error('вход ' + m.ctrl.code)); else res(m.ctrl.params); } };
  });
}

// ---------------- Chrome ----------------
function chromeBin() {
  if (process.env.CHROME_BIN) return process.env.CHROME_BIN;
  const c = ['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/usr/bin/google-chrome', '/usr/bin/google-chrome-stable', '/usr/bin/chromium', '/usr/bin/chromium-browser'];
  return c.find(f => { try { return fs.statSync(f).isFile(); } catch { return false; } });
}
async function cdpUrl() {
  if (process.env.CDP) { const r = await fetch(process.env.CDP.replace(/\/$/, '') + '/json/version'); return (await r.json()).webSocketDebuggerUrl; }
  const bin = chromeBin(); if (!bin) throw new Error('Chrome не найден: задайте CHROME_BIN или CDP');
  tmpProfile = fs.mkdtempSync(path.join(os.tmpdir(), 'l2-call-scn-'));
  const port = 9300 + Math.floor(Math.random() * 500);
  chromeProc = spawn(bin, ['--headless=new', '--no-first-run', '--no-default-browser-check', '--user-data-dir=' + tmpProfile,
    '--remote-debugging-port=' + port, '--lang=ru-RU', '--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
    '--autoplay-policy=no-user-gesture-required', '--disable-background-timer-throttling', '--disable-renderer-backgrounding',
    '--disable-backgrounding-occluded-windows', ...(process.getuid && process.getuid() === 0 ? ['--no-sandbox'] : []), 'about:blank'], { stdio: 'ignore' });
  for (let i = 0; i < 60; i++) {
    await sleep(500);
    try { const r = await fetch('http://127.0.0.1:' + port + '/json/version'); if (r.ok) return (await r.json()).webSocketDebuggerUrl; } catch {}
  }
  throw new Error('Chrome не запустился');
}
class Cdp {
  constructor(url) { this.url = url; this.id = 0; this.pend = new Map(); }
  open() { return new Promise((res, rej) => { this.ws = new WebSocket(this.url); this.ws.onopen = res; this.ws.onerror = rej;
    this.ws.onmessage = ev => { const m = JSON.parse(ev.data);
      if (m.id && this.pend.has(m.id)) { const p = this.pend.get(m.id); this.pend.delete(m.id); m.error ? p.rej(new Error(m.error.message)) : p.res(m.result); }
      else if (m.method === 'Page.javascriptDialogOpening') this.send('Page.handleJavaScriptDialog', { accept: true }, m.sessionId).catch(() => {});
      else if (m.method === 'Fetch.requestPaused') onPaused(m); }; }); }
  send(method, params = {}, sessionId) { const id = ++this.id; this.ws.send(JSON.stringify({ id, method, params, sessionId }));
    return new Promise((res, rej) => { this.pend.set(id, { res, rej }); setTimeout(() => { if (this.pend.has(id)) { this.pend.delete(id); rej(new Error('CDP timeout ' + method)); } }, 60000); }); }
}
let cdp, sid, ciHeader = '';
function onPaused(m) {
  const h = Object.entries(m.params.request.headers || {}).map(([name, value]) => ({ name, value }));
  if (ciHeader) h.push({ name: 'X-L2-CI', value: ciHeader });
  cdp.send('Fetch.continueRequest', { requestId: m.params.requestId, headers: h }, m.sessionId).catch(() => {});
}
const send = (m, p) => cdp.send(m, p, sid);
async function ev(expr) { const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text); return r.result.value; }
async function wait(expr, ms, what) { const t0 = Date.now(); for (;;) { let v; try { v = await ev(expr); } catch {} if (v) return v; if (Date.now() - t0 > ms) throw new Error('не дождались: ' + what); await sleep(300); } }
async function shot(name) { try { const r = await send('Page.captureScreenshot', { format: 'png' }); const f = path.join(OUT, name + '.png'); fs.writeFileSync(f, Buffer.from(r.data, 'base64')); result.shots.push(f); } catch {} }
const iceJs = `(function(){var p=window.__gc&&window.__gc.pc;return p?p.iceConnectionState:'none'})()`;
const bytesJs = `(async function(){var p=window.__gc&&window.__gc.pc;if(!p)return -1;var b=0;(await p.getStats()).forEach(function(s){if(s.type==='inbound-rtp'&&(s.kind||s.mediaType)==='audio')b+=s.bytesReceived||0});return b})()`;
const outJs = `(async function(){var p=window.__gc&&window.__gc.pc;if(!p)return -1;var b=0;(await p.getStats()).forEach(function(s){if(s.type==='outbound-rtp'&&(s.kind||s.mediaType)==='audio')b+=s.bytesSent||0});return b})()`;
const screenJs = `(function(){var v=['s-prep','s-wait','s-call','s-end'].filter(function(id){var e=document.getElementById(id);return e&&!e.hidden});return v.join(',')})()`;
async function grows(label, ms = 4000) {
  const a = await ev(bytesJs).catch(() => -1), ao = await ev(outJs).catch(() => -1); await sleep(ms);
  const b = await ev(bytesJs).catch(() => -1), bo = await ev(outJs).catch(() => -1), ice = await ev(iceJs).catch(() => '?');
  return step(label, /connected|completed/.test(ice) && a >= 0 && b > a && bo > ao, `ice=${ice} in ${a}→${b} out ${ao}→${bo}`);
}
const names = ['приложение на экране', 'приложение в фоне (нативный движок)', 'приложение в фоне → переход на WKWebView'];

async function main() {
  if (!LOGIN || !PASS) { result.error = 'нет L2_LOGIN / L2_PASSWORD'; return finish(2); }
  const t0 = Date.now();
  const params = await tinodeLogin(LOGIN, PASS); token = params.token;
  step('вход владельца (пользователь iOS-теста)', !!token, LOGIN);
  const lj = await api('POST', '/links', { title: 'CI iOS ' + String(Date.now() % 1e4), mode: 'audio', ttl: 'never', once: false });
  if (!step('ссылка создана (POST /call/api/links)', !!(lj.link && lj.link.url), lj.link ? lj.link.url.replace(/[A-Za-z0-9_-]{43}$/, '<token>') : JSON.stringify(lj).slice(0, 200))) return finish(1);
  linkId = lj.link.id;
  cdp = new Cdp(await cdpUrl()); await cdp.open();
  const { browserContextId } = await cdp.send('Target.createBrowserContext', { disposeOnDetach: true });
  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank', browserContextId });
  ({ sessionId: sid } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
  await send('Page.enable'); await send('Runtime.enable'); await send('Page.bringToFront').catch(() => {});
  await send('Emulation.setDeviceMetricsOverride', { width: 402, height: 874, deviceScaleFactor: 2, mobile: true });
  await send('Emulation.setFocusEmulationEnabled', { enabled: true }).catch(() => {});
  await cdp.send('Browser.grantPermissions', { browserContextId, origin: BASE, permissions: ['audioCapture', 'videoCapture'] }).catch(() => {});
  ciHeader = ciHeaderOf();
  if (ciHeader) await send('Fetch.enable', { patterns: [{ urlPattern: BASE + '/*', requestStage: 'Request' }] });
  let prevReady = t0;
  for (let i = 1; i <= N; i++) {
    const name = 'звонок ' + i + ' (' + (names[i - 1] || '') + ')';
    const c = { name, ok: false, tries: 0 }; result.calls.push(c);
    log(name + ': жду guest-ready-' + i);
    const ready = await waitSync('guest-ready-' + i, prevReady, READY_WAIT_S * 1000);
    if (!step(name + ': iOS готов принять', !!ready, ready ? '' : 'нет guest-ready-' + i)) continue;
    prevReady = ready;
    await sleep(1500);
    let connected = false;
    for (let tr = 1; tr <= 3 && !connected; tr++) {
      c.tries = tr;
      await send('Page.navigate', { url: lj.link.url + '?ci=' + ciHeader });
      try {
        await wait(`(function(){var e=document.getElementById('s-prep');return e&&!e.hidden})()`, 25000, 'экрана подготовки');
        await ev(`(function(){var e=document.getElementById('p-name');var d=Object.getOwnPropertyDescriptor(Object.getPrototypeOf(e),'value');d.set.call(e,'Гость CI ${i}');e.dispatchEvent(new Event('input',{bubbles:true}));return true})()`);
        await ev(`document.getElementById('p-call').click()`);
        log(name + ': звоню, попытка ' + tr);
        await wait(`(function(){var p=window.__gc&&window.__gc.pc;return p&&/connected|completed/.test(p.iceConnectionState)})()`, ANSWER_WAIT_S * 1000, 'ответа iOS и ICE connected');
        connected = true;
      } catch (e) {
        log(name + ': ' + e.message + ' (экран: ' + (await ev(screenJs).catch(() => '?')) + ')');
        await shot(i + '-try' + tr);
        await ev(`(function(){var b=document.getElementById('c-hang')||document.getElementById('w-cancel');if(b)b.click();return true})()`).catch(() => {});
        await sleep(5000);
      }
    }
    if (!step(name + ': гость дозвонился, ICE connected', connected, 'попыток: ' + c.tries)) continue;
    syncWrite('guest-connected-' + i, Date.now());
    await shot(i + '-connected');
    const g1 = await grows(name + ': у гостя звук в обе стороны (байты аудио растут)');
    log(name + ': жду ios-phase-' + i);
    const ph = await waitSync('ios-phase-' + i, ready, 180000);
    step(name + ': iOS проверил звонок у себя', !!ph, ph ? '' : 'нет ios-phase-' + i);
    const g2 = ph ? await grows(name + ': у гостя после проверок iOS' + (i === 3 ? ' (после перехода на WKWebView)' : '') + ' ICE connected, звук в обе стороны') : false;
    await shot(i + '-after');
    let ended = false; const endBy = Date.now() + 60000;
    while (!ended && Date.now() < endBy) { ended = /s-end/.test(await ev(screenJs).catch(() => '')); if (!ended) await sleep(300); }
    step(name + ': iOS положил трубку — у гостя «Звонок завершён»', ended);
    c.ok = connected && g1 && g2 && ended && !!ph;
  }
  result.ok = result.steps.every(s => s.ok) && result.calls.length === N && result.calls.every(c => c.ok);
  return finish(result.ok ? 0 : 1);
}
main().catch(e => { result.error = String(e && e.message || e); log('ОШИБКА', result.error); finish(2); });
