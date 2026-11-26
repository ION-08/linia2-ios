#!/usr/bin/env node
// Линия 2.0 — веб-сторона сквозных звонков для Linia2CallTests (CI). Пользователь B в браузере (Chrome, поддельные камера/микрофон):
//   1) ждёт входящий от iOS (аудио) → принимает → проверяет ICE и растущий bytesReceived → ждёт, пока трубку положит iOS;
//   2) то же для видео;
//   3) звонит iOS (аудио) через window.L2Call.start (повтор, пока iOS не примет) → держит → ждёт, пока iOS положит трубку;
//   4) то же для видео.
// Каждый звонок должен продержаться ≥ MIN_HOLD_S (60) с. Код выхода 0 — все 4 прошли, 1 — проверка не прошла, 2 — не смог выполниться.
// stdout — одна строка JSON-итога; stderr — ход работы; скриншоты — в OUT_DIR.
// env: L2_PEER_LOGIN, L2_PEER_PASSWORD (B), L2_IOS_UID (uid A = топик p2p у B), CI_TOKEN (заголовок X-L2-CI),
//      OUT_DIR, BASE, FIRST_WAIT_S (1800), MIN_HOLD_S (60), END_WAIT_S (240), DIAL_TRIES (8).
// Нужен Node 22+ (встроенный WebSocket и fetch), сторонние пакеты не нужны.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';

const BASE = (process.env.BASE || 'https://v2.chat-linia.site').replace(/\/$/, '');
const OUT = process.env.OUT_DIR || path.resolve('call-scenario-out');
const FIRST_WAIT_S = +(process.env.FIRST_WAIT_S || 1800), MIN_HOLD_S = +(process.env.MIN_HOLD_S || 60), END_WAIT_S = +(process.env.END_WAIT_S || 240), DIAL_TRIES = +(process.env.DIAL_TRIES || 8);
const LOGIN = process.env.L2_PEER_LOGIN, PASS = process.env.L2_PEER_PASSWORD;
fs.mkdirSync(OUT, { recursive: true });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const log = (...a) => console.error(new Date().toISOString().slice(11, 19), ...a);
const result = { ok: false, login: LOGIN || null, steps: [], calls: [], error: null, shots: [] };
function step(name, ok, detail = '') { result.steps.push({ name, ok: !!ok, detail }); log((ok ? 'OK  ' : 'FAIL') + ' ' + name + (detail ? ' — ' + detail : '')); return !!ok; }
let chromeProc = null, tmpProfile = null;
function finish(code) {
  try { if (chromeProc) chromeProc.kill('SIGKILL'); } catch {}
  try { if (tmpProfile) fs.rmSync(tmpProfile, { recursive: true, force: true }); } catch {}
  process.stdout.write(JSON.stringify(result) + '\n');
  process.exit(code);
}
process.on('SIGINT', () => { result.error = 'прервано'; finish(2); });
process.on('SIGTERM', () => { result.error = 'прервано'; finish(2); });

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
const statsJs = `(async function(){var out=[];for(const pc of (window.__pcs||[])){if(pc.connectionState==='closed'||pc.signalingState==='closed')continue;var b=0;(await pc.getStats()).forEach(function(s){if(s.type==='inbound-rtp')b+=s.bytesReceived||0});out.push({ice:pc.iceConnectionState,conn:pc.connectionState,bytes:b})}return out})()`;
const stateJs = `(function(){try{if(window.L2Call)return window.L2Call.state();}catch(e){}var r=document.querySelector('.incoming-call');return {state:r?'incoming':(document.querySelector('#video-container')?'active':'idle')}})()`;

async function main() {
  if (!LOGIN || !PASS) { result.error = 'нет L2_PEER_LOGIN / L2_PEER_PASSWORD'; return finish(2); }
  cdp = new Cdp(await cdpUrl()); await cdp.open();
  const { browserContextId } = await cdp.send('Target.createBrowserContext', { disposeOnDetach: true });
  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank', browserContextId });
  ({ sessionId: sid } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
  await send('Page.enable'); await send('Runtime.enable'); await send('Page.bringToFront').catch(() => {});
  await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 860, deviceScaleFactor: 1, mobile: false });
  await send('Emulation.setFocusEmulationEnabled', { enabled: true }).catch(() => {});
  await cdp.send('Browser.grantPermissions', { browserContextId, origin: BASE, permissions: ['audioCapture', 'videoCapture', 'notifications'] }).catch(() => {});
  if (process.env.CI_TOKEN) {
    const day = new Date().toISOString().slice(0, 10).replace(/-/g, '');
    ciHeader = crypto.createHmac('sha256', process.env.CI_TOKEN).update('linia2-ci:' + day).digest('hex');
    // Только запросы к своему серверу (заголовок на CDN сломал бы CORS-загрузку скриптов).
    await send('Fetch.enable', { patterns: [{ urlPattern: BASE + '/*', requestStage: 'Request' }] });
  }
  // Все RTCPeerConnection страницы — в window.__pcs (для getStats).
  await send('Page.addScriptToEvaluateOnNewDocument', { source: `(function(){var N=window.RTCPeerConnection;if(!N)return;window.__pcs=[];var P=function(c,o){var pc=new N(c,o);window.__pcs.push(pc);return pc};P.prototype=N.prototype;Object.setPrototypeOf(P,N);window.RTCPeerConnection=P;})();` });

  // 1. Вход
  await send('Page.navigate', { url: BASE + '/' });
  await wait(`(function(){var b=[...document.querySelectorAll('#l2a .btn')].find(b=>/Войти/.test(b.textContent));if(b&&b.offsetParent){b.click();return true}return !!document.getElementById('l2-head')})()`, 40000, 'экрана входа');
  if (!(await ev(`!!document.getElementById('l2-head')`))) {
    await wait(`!!document.querySelector('#l2a input[autocomplete=username]')`, 15000, 'поля логина');
    await sleep(400);
    for (const [sel, v] of [['#l2a input[autocomplete=username]', LOGIN], ['#l2a input[type=password]', PASS]]) {
      await ev(`(function(){var e=document.querySelector(${JSON.stringify(sel)});e.focus();var d=Object.getOwnPropertyDescriptor(Object.getPrototypeOf(e),'value');d.set.call(e,${JSON.stringify(v)});e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));return true})()`);
    }
    await ev(`[...document.querySelectorAll('#l2a .btn')].find(b=>/Войти/.test(b.textContent)).click()`);
  }
  try { await wait(`!!document.getElementById('l2-head')`, 40000, 'входа'); step('вход в веб-версию', true, LOGIN); }
  catch (e) { await shot('01-login-fail'); step('вход в веб-версию', false, e.message); return finish(1); }
  await shot('01-logged-in');


  // ---- сценарий ----
  const kinds = [['iOS → веб (аудио)', 'in', false], ['iOS → веб (видео)', 'in', true], ['веб → iOS (аудио)', 'out', false], ['веб → iOS (видео)', 'out', true]];
  for (let i = 0; i < kinds.length; i++) {
    const [name, dir, video] = kinds[i];
    const c = { name, ok: false, ice: null, heldS: 0, grew: 0, endedBy: null, note: '' };
    result.calls.push(c);
    try {
      if (dir === 'in') {
        log(name + ': жду входящий');
        const inc = await wait(`(function(){var s=${stateJs};return s.state==='incoming'?s:null})()`, (i === 0 ? FIRST_WAIT_S : 600) * 1000, 'входящего звонка');
        c.note = (inc.audioOnly ? 'аудио' : 'видео');
        if (!!inc.audioOnly === video) step(name + ': тип звонка', false, 'пришёл ' + c.note); else step(name + ': тип звонка', true, c.note);
        await sleep(1500); await shot(i + '-incoming');
        await ev(`(function(){if(window.L2Call&&window.L2Call.accept())return true;var b=document.querySelector('.incoming-call button.positive');if(b){b.click();return true}return false})()`);
      } else {
        // Даём iOS закончить проверки предыдущего звонка и вернуться на главный экран.
        await sleep(40000);
        const uid = process.env.L2_IOS_UID;
        if (!uid) throw new Error('нет L2_IOS_UID');
        let answered = false;
        for (let t = 1; t <= DIAL_TRIES && !answered; t++) {
          log(name + ': звоню, попытка ' + t);
          await ev(`window.L2Call.start(${JSON.stringify(uid)}, {video: ${video}})`);
          try { await wait(`(function(){var s=${stateJs};return s.state!=='idle'})()`, 15000, 'начала звонка'); } catch (e) { log('звонок не начался: ' + e.message); await sleep(5000); continue; }
          // Ждём ответа iOS (active) или сброса (idle — пропущен).
          const end = Date.now() + 45000;
          for (;;) {
            const s = await ev(stateJs).catch(() => ({ state: 'idle' }));
            if (s.state === 'active') { answered = true; break; }
            if (s.state === 'idle' || Date.now() > end) break;
            await sleep(500);
          }
          if (!answered) { await ev(`window.L2Call.hangup()`).catch(() => {}); await sleep(10000); }
        }
        if (!step(name + ': iOS принял', answered, '')) { c.note = 'iOS не ответил'; continue; }
      }
      c.ice = await wait(`(async function(){var s=await ${statsJs};var c=s.find(function(x){return x.ice==='connected'||x.ice==='completed'});return c?c.ice:null})()`, 30000, 'ICE connected');
      step(name + ': ICE', true, c.ice);
      await sleep(1500); await shot(i + '-active');
      const t0 = Date.now(); let prev = -1;
      for (;;) {
        const st = await ev(statsJs).catch(() => []), b = st.reduce((s, x) => s + x.bytes, 0);
        if (prev >= 0 && b > prev) c.grew++; prev = b;
        const cs = await ev(stateJs).catch(() => ({ state: 'idle' }));
        if (cs.state === 'idle') { c.endedBy = 'ios'; break; }
        if (Date.now() - t0 > (MIN_HOLD_S + END_WAIT_S) * 1000) { c.endedBy = 'timeout'; await ev(`window.L2Call.hangup()`).catch(() => {}); break; }
        await sleep(1000);
      }
      c.heldS = Math.round((Date.now() - t0) / 1000);
      await shot(i + '-ended');
      const okHold = step(name + ': держался ≥ ' + MIN_HOLD_S + ' с', c.heldS >= MIN_HOLD_S - 3, c.heldS + ' с');
      const okBytes = step(name + ': медиатрафик идёт', c.grew >= 10, 'приростов bytesReceived: ' + c.grew);
      const okEnd = step(name + ': трубку положил iOS, у веба завершилось', c.endedBy === 'ios', c.endedBy || '');
      c.ok = okHold && okBytes && okEnd;
    } catch (e) {
      await shot(i + '-fail');
      step(name, false, e.message);
      await ev(`window.L2Call && window.L2Call.hangup()`).catch(() => {});
    }
  }
  result.ok = result.calls.every(c => c.ok) && result.steps.every(s => s.ok);
  finish(result.ok ? 0 : 1);
}
main().catch(e => { result.error = String(e && e.message || e); log('ОШИБКА', result.error); finish(2); });
