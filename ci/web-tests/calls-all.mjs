#!/usr/bin/env node
// Линия 2.0 — тест ВСЕХ звонков веба (обязательная часть выпуска). Playwright, ОДИН браузер, несколько контекстов.
//
//   npm i playwright && npx playwright install --with-deps chromium
//   CI_TOKEN=… OUT_DIR=./calls-shots node ci/web-tests/calls-all.mjs
//
// Варианты (VARIANTS=через запятую, по умолчанию все):
//   chat-audio, chat-video, contacts-video, calls-audio — обычный звонок веб↔веб (из чата, «Контактов», «Звонков»);
//   relay-audio, relay-video — из чата, у ОБОИХ iceTransportPolicy:'relay' (как два пользователя за NAT — проверка TURN);
//   decline             — B нажимает «Отклонить» одним кликом → у A экран закрыт ≤ 3 с;
//   noanswer            — B не отвечает → у A через 45 с «Не удалось дозвониться» и экран закрыт;
//   nodevice-audio      — то же, у принимающего нет камеры и микрофона (getUserMedia отклоняется) — звонок не должен обрываться;
//   link-auth           — звонок по ссылке вошедшим пользователем («Позвонить как <имя>», обычный звонок Tinode);
//   link-guest          — звонок по ссылке гостем без регистрации (через шлюз).
// В каждом: гудки/входящий → «Принять» → HOLD_S (60) с: ICE connected и растущий bytesReceived у обоих каждые 5 с →
// звук в обе стороны (audio bytes, audioLevel>0, элемент собеседника играет), выбранная пара кандидатов в итоге →
// микрофон (и камера в видео) выкл/вкл у каждой стороны: track.enabled=false/true, видео у собеседника перестаёт/снова растёт →
// «Положить трубку» у одного → завершилось у обоих → запись в истории «Звонки» у обоих (и в «Мои ссылки» для link-*).
// Выход 0 — только если все варианты прошли. stdout (последняя строка) — JSON {ok, table:[{variant, ok, seconds, error}], …};
// скриншоты — $OUT_DIR. Все запросы к v2.chat-linia.site несут X-L2-CI (CONTRACTS.md «Пропуск автотестов»).
// LITE=1 — облегчённый режим для слабой машины (1 CPU): видео 320×240@10, без анимаций.
// Пользователи — POST /invite/api/ci/setup, в конце удаляются вместе с чатами (как del.mjs). Локально: CDP_URL=http://127.0.0.1:9778.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

let pw;
try { pw = await import('playwright'); } catch { pw = await import('playwright-core'); }
const { chromium } = pw.default || pw;

const BASE = (process.env.BASE || 'https://v2.chat-linia.site').replace(/\/$/, '');
const HOST = new URL(BASE).host;
const OUT = process.env.OUT_DIR || 'calls-all-shots';
const CI = process.env.CI_TOKEN || '';
const HOLD_S = +(process.env.HOLD_S || 60);
const APIKEY = 'AQEAAAABAAD_rAp4DJh05a1HAwFT3A6K';
const ALL = ['chat-audio', 'relay-audio', 'chat-video', 'relay-video', 'contacts-video', 'calls-audio', 'nodevice-audio', 'decline', 'noanswer', 'link-auth', 'link-guest'];
const VARIANTS = process.env.VARIANTS ? process.env.VARIANTS.split(',').map(s => s.trim()).filter(Boolean) : ALL;
fs.mkdirSync(OUT, { recursive: true });
if (!CI) { console.log(JSON.stringify({ ok: false, error: 'нет CI_TOKEN' })); process.exit(2); }
if (typeof WebSocket === 'undefined') { console.log(JSON.stringify({ ok: false, error: 'нужен Node 22+ (встроенный WebSocket)' })); process.exit(2); }

const ciHeader = () => crypto.createHmac('sha256', CI).update('linia2-ci:' + new Date().toISOString().slice(0, 10).replace(/-/g, '')).digest('hex');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const log = (...a) => console.error(new Date().toISOString().slice(11, 19), ...a);
class Fail extends Error {}
const skipped = [];   // пропущенные шаги (с причиной) — в итог
function must(cond, what, detail = '') { if (!cond) throw new Fail(what + (detail ? ' — ' + String(detail).slice(0, 300) : '')); log('  ok', what, detail ? '— ' + String(detail).slice(0, 160) : ''); }

// ---------------- сервер ----------------
async function ciSetup(run) {
  const r = await fetch(BASE + '/invite/api/ci/setup', { method: 'POST', headers: { Authorization: 'Bearer ' + CI, 'Content-Type': 'application/json', 'X-L2-CI': ciHeader() }, body: JSON.stringify({ run }) });
  const j = await r.json(); if (!j.ok) throw new Error('ci/setup: ' + r.status + ' ' + JSON.stringify(j)); return j;
}
// login → params; act.to/text — ещё и отправить сообщение; act === 'del' — удалить пользователя с чатами (как del.mjs).
function tinode(login, pass, act) {
  return new Promise((res, rej) => {
    const ws = new WebSocket(BASE.replace(/^http/, 'ws') + '/v0/channels?apikey=' + APIKEY, { headers: { 'X-L2-CI': ciHeader() } });
    const send = o => ws.send(JSON.stringify(o)); let params;
    const timer = setTimeout(() => { try { ws.close(); } catch {} act === 'del' ? res(false) : rej(new Error('таймаут Tinode')); }, 20000);
    const done = v => { clearTimeout(timer); try { ws.close(); } catch {} res(v); };
    ws.onopen = () => send({ hi: { id: '1', ver: '0.25' } });
    ws.onerror = () => { clearTimeout(timer); act === 'del' ? res(false) : rej(new Error('ошибка WebSocket')); };
    ws.onmessage = ev => {
      const m = JSON.parse(ev.data);
      if (act === 'del' && m.meta && m.meta.sub) for (const s of m.meta.sub) if (s.topic && s.topic !== 'me') send({ del: { id: 't' + s.topic, topic: s.topic, what: 'topic', hard: true } });
      if (!m.ctrl) return;
      if (m.ctrl.id === '1') send({ login: { id: '2', scheme: 'basic', secret: Buffer.from(login + ':' + pass).toString('base64') } });
      else if (m.ctrl.id === '2') {
        if (m.ctrl.code >= 300) { clearTimeout(timer); ws.close(); return act === 'del' ? res(false) : rej(new Error('вход ' + m.ctrl.code)); }
        params = m.ctrl.params;
        if (!act) return done(params);
        if (act === 'del') send({ sub: { id: '4', topic: 'me', get: { what: 'sub' } } });
        else send({ sub: { id: '5', topic: act.to } });
      } else if (m.ctrl.id === '5') send({ pub: { id: '6', topic: act.to, content: act.text } });
      else if (m.ctrl.id === '6') done(params);
      else if (m.ctrl.id === '4') setTimeout(() => send({ del: { id: '3', what: 'user', hard: true } }), 1500);
      else if (m.ctrl.id === '3') done(m.ctrl.code < 300);
    };
  });
}
async function api(token, method, p, body) {
  const r = await fetch(BASE + '/call/api' + p, { method, headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json', 'X-L2-CI': ciHeader() }, body: body ? JSON.stringify(body) : undefined });
  return r.json();
}

// ---------------- браузер ----------------
const PC_HOOK = `(function(){var N=window.RTCPeerConnection;if(!N||window.__pcs)return;window.__pcs=[];var P=function(c){var pc=new N(c);window.__pcs.push(pc);return pc};P.prototype=N.prototype;window.RTCPeerConnection=P;})();`;
// LITE=1 — для слабой машины (сервер, 1 CPU): камера 320×240 @10 к/с, без анимаций/размытий (их рисует программный GPU).
const LITE = process.env.LITE === '1';
const LITE_JS = `(function(){var md=navigator.mediaDevices;if(md&&md.getUserMedia){var o=md.getUserMedia.bind(md);md.getUserMedia=function(c){try{if(c&&c.video){var v=typeof c.video==='object'?Object.assign({},c.video):{};v.width={max:320};v.height={max:240};v.frameRate={max:10};c=Object.assign({},c,{video:v})}}catch(e){}return o(c)}}
document.addEventListener('DOMContentLoaded',function(){var s=document.createElement('style');s.textContent='*,*:before,*:after{animation:none!important;transition:none!important;backdrop-filter:none!important;-webkit-backdrop-filter:none!important;filter:none!important;box-shadow:none!important}';document.head.appendChild(s)})})();`;
const RELAY_JS = `(function(){var N=window.RTCPeerConnection;if(!N)return;var P=function(c,o){c=Object.assign({},c||{},{iceTransportPolicy:'relay'});return new N(c,o)};P.prototype=N.prototype;window.RTCPeerConnection=P;})();`;
const NO_DEVICES = `(function(){var md=navigator.mediaDevices;if(!md)return;md.getUserMedia=function(){return Promise.reject(new DOMException('Requested device not found','NotFoundError'))};})();`;
let browser;
async function newCtx(opts = {}, noDevices = false, relay = false) {
  const ctx = await browser.newContext({ locale: 'ru-RU', bypassCSP: true, permissions: ['microphone', 'camera'], viewport: { width: 1024, height: 700 }, ...opts });
  await ctx.route('**/*', route => {
    const u = new URL(route.request().url());
    if (u.host !== HOST) return route.continue();
    return route.continue({ headers: { ...route.request().headers(), 'x-l2-ci': ciHeader() } });
  });
  if (relay) await ctx.addInitScript(RELAY_JS);   // до PC_HOOK: каждый RTCPeerConnection страницы — только через TURN
  await ctx.addInitScript(PC_HOOK);
  if (noDevices) await ctx.addInitScript(NO_DEVICES);
  else if (LITE) await ctx.addInitScript(LITE_JS);
  return ctx;
}
// Headless Chrome душит неактивные вкладки (event loop стоял по 30+ с) — держим каждую страницу «в фокусе и активной».
async function keepActive(page) {
  try {
    const cdp = await page.context().newCDPSession(page);
    await cdp.send('Emulation.setFocusEmulationEnabled', { enabled: true });
    await cdp.send('Page.enable'); await cdp.send('Page.setWebLifecycleState', { state: 'active' });
  } catch {}
}
// На слабой машине клики и getStats идут медленно — даём действиям до 90 с (TIMEOUT_MS).
const TIMEOUT_MS = +(process.env.TIMEOUT_MS || 90000);
async function newPage(ctx) { const page = await ctx.newPage(); page.setDefaultTimeout(TIMEOUT_MS); await keepActive(page); return page; }
async function webLogin(ctx, params) {
  const page = await newPage(ctx);
  page.on('dialog', d => d.accept().catch(() => {}));
  // Окно «Включить уведомления?» перекрывает интерфейс — отвечаем «Позже».
  if (page.addLocatorHandler) await page.addLocatorHandler(page.locator('.l2-modal:not(.l2g-modal)').filter({ hasText: 'Включить уведомления' }),
    async () => { await page.locator('.l2-modal:not(.l2g-modal) button').filter({ hasText: 'Позже' }).first().click().catch(() => {}); });
  await page.goto(BASE + '/invite/');
  await page.evaluate(([t, e]) => { localStorage.setItem('keep-logged-in', 'true'); localStorage.setItem('auth-token', JSON.stringify({ token: t, expires: e })); }, [params.token, params.expires]);
  await page.goto(BASE + '/');
  try { await page.locator('button[data-tab="calls"]').first().waitFor({ timeout: 45000 }); }
  catch (e) { await shot(page, 'login-fail-' + Date.now()); throw new Error('веб не открылся после входа: ' + (await page.evaluate(() => document.body.innerText.slice(0, 200)).catch(() => ''))); }
  await page.waitForFunction(() => !!window.L2Call, null, { timeout: 20000 });
  return page;
}
const shot = async (page, name) => { try { await page.screenshot({ path: path.join(OUT, name + '.png') }); } catch {} };

// Сторона звонка: веб (Tinode web, window.L2Call) или страница гостя (/call/<token>, window.__gc).
function webSide(page, name) {
  return {
    name, page, kind: 'web',
    stats: () => page.evaluate(async () => {
      // L2Call.pc() бывает null при живом соединении — берём последний незакрытый RTCPeerConnection страницы (перехват PC_HOOK).
      const live = (window.__pcs || []).slice(window.__pcMark || 0).filter(p => p.signalingState !== 'closed');   // только pc текущего звонка
      const withAudio = live.filter(p => p.getReceivers().some(r => r.track && r.track.kind === 'audio'));
      const pc = withAudio.filter(p => p.connectionState === 'connected').pop() || withAudio.pop() || live.pop() || (window.L2Call && window.L2Call.pc()); if (!pc) return null;
      var __rx = (pc.getReceivers().find(r => r.track && r.track.kind === 'audio') || {}).track;
      const o = { ice: pc.iceConnectionState, bytes: 0, vbytes: 0, abytes: 0, alevel: 0, audioOn: null, videoOn: null, pair: '' };
      const rep = await pc.getStats(), byId = {}; rep.forEach(s => { byId[s.id] = s; });
      rep.forEach(s => {
        if (s.type === 'inbound-rtp') { o.bytes += s.bytesReceived || 0; if (s.kind === 'video') o.vbytes += s.bytesReceived || 0; if (s.kind === 'audio') { o.abytes += s.bytesReceived || 0; o.alevel = Math.max(o.alevel, s.audioLevel || 0); o.aenergy = (o.aenergy || 0) + (s.totalAudioEnergy || 0); o.adur = (o.adur || 0) + (s.totalSamplesDuration || 0); } }
        if (s.type === 'candidate-pair' && s.nominated && s.state === 'succeeded') { const l = byId[s.localCandidateId], r = byId[s.remoteCandidateId]; o.pair = (l && l.candidateType) + '/' + (r && r.candidateType); }
        if (s.type === 'media-source' && s.kind === 'audio') o.micLevel = Math.max(o.micLevel || 0, s.audioLevel || 0);
        if (s.type === 'outbound-rtp' && s.kind === 'audio') o.atx = (o.atx || 0) + (s.bytesSent || 0);
      });
      for (const s of pc.getSenders()) if (s.track) { const on = s.track.enabled && s.track.readyState === 'live'; if (s.track.kind === 'audio') o.audioOn = on; else o.videoOn = (o.videoOn || false) || on; }
      const el = document.querySelector('#video-container .call-party.peer video, #video-container .call-party.peer audio');
      const ea = el && el.srcObject && el.srcObject.getAudioTracks ? el.srcObject.getAudioTracks()[0] : null;
      o.el = el ? { src: !!el.srcObject, muted: el.muted, paused: el.paused, vol: el.volume, sameTrack: !!(ea && __rx && ea.id === __rx.id) } : null;
      return o;
    }),
    state: () => page.evaluate(() => window.L2Call.state().state),
    // Кнопки экрана звонка: видимая кнопка с подписью (title / data-label / aria-label). Клик через DOM — без ожидания
    // «стабильности» (на слабой машине анимации/перерисовки задерживали обычный клик на 90+ с).
    // Свои кнопки Линии (.l2-cb.mic2/.cam2, «Завершить» data-l2r=end); в старых версиях — по подписи.
    async mic() { if (!(await domClick(page, '.l2-cb.mic2'))) await clickLabel(page, /^Микрофон/); },
    async cam() { if (!(await domClick(page, '.l2-cb.cam2'))) await clickLabel(page, /^Камера/); },
    async hangup() { if (!(await domClick(page, '#controls > button[data-l2r="end"]'))) await clickLabel(page, /^Завершить$/); },
  };
}
function guestSide(page, name) {
  return {
    name, page, kind: 'guest',
    stats: () => page.evaluate(async () => {
      const pc = window.__gc && window.__gc.pc; if (!pc) return null;
      const o = { ice: pc.iceConnectionState, bytes: 0, vbytes: 0, abytes: 0, alevel: 0, audioOn: null, videoOn: null, pair: '' };
      const rep = await pc.getStats(), byId = {}; rep.forEach(s => { byId[s.id] = s; });
      rep.forEach(s => {
        if (s.type === 'inbound-rtp') { o.bytes += s.bytesReceived || 0; if (s.kind === 'video') o.vbytes += s.bytesReceived || 0; if (s.kind === 'audio') { o.abytes += s.bytesReceived || 0; o.alevel = Math.max(o.alevel, s.audioLevel || 0); o.aenergy = (o.aenergy || 0) + (s.totalAudioEnergy || 0); o.adur = (o.adur || 0) + (s.totalSamplesDuration || 0); } }
        if (s.type === 'candidate-pair' && s.nominated && s.state === 'succeeded') { const l = byId[s.localCandidateId], r = byId[s.remoteCandidateId]; o.pair = (l && l.candidateType) + '/' + (r && r.candidateType); }
        if (s.type === 'media-source' && s.kind === 'audio') o.micLevel = Math.max(o.micLevel || 0, s.audioLevel || 0);
        if (s.type === 'outbound-rtp' && s.kind === 'audio') o.atx = (o.atx || 0) + (s.bytesSent || 0);
      });
      const st = window.__gc.stream; if (st) { const a = st.getAudioTracks()[0]; o.audioOn = !!(a && a.enabled); o.videoOn = st.getVideoTracks().some(t => t.enabled && t.readyState === 'live'); }
      const el = document.getElementById('c-remote'), __rx = (pc.getReceivers().find(r => r.track && r.track.kind === 'audio') || {}).track;
      const ea = el && el.srcObject ? el.srcObject.getAudioTracks()[0] : null;
      o.el = el ? { src: !!el.srcObject, muted: el.muted, paused: el.paused, vol: el.volume, sameTrack: !!(ea && __rx && ea.id === __rx.id) } : null;
      return o;
    }),
    state: () => page.evaluate(() => (document.getElementById('s-call').hidden ? (document.getElementById('s-end').hidden ? 'wait' : 'idle') : 'active')),
    async mic() { await page.click('#c-mic'); },
    async cam() { await page.click('#c-cam'); },
    async hangup() { await page.click('#c-hang'); },
  };
}
async function domClick(page, sel) { return page.evaluate(q => { const b = [...document.querySelectorAll(q)].find(x => x.offsetParent); if (!b) return false; b.click(); return true; }, sel).catch(() => false); }
// Микрофон звонка до ответа: CallPanel.state.localStream (React fiber #video-container).
async function localMic(page) {
  return page.evaluate(() => { try { let f = null; const n = document.getElementById('video-container'); for (const k in n) if (k.startsWith('__reactFiber$')) f = n[k];
    for (let d = 0; f && d < 12; d++, f = f.return) if (f.stateNode && f.stateNode.handleToggleMicClick) { const st = f.stateNode.state.localStream; const t = st && st.getAudioTracks()[0]; return t ? t.enabled : null; } } catch (e) {} return null; }).catch(() => null);
}
// Слежение в странице: когда звонок стал idle (мс, Date.now) и какие тосты показывались.
async function watchIdle(page) {
  await page.evaluate(() => { window.__idleAt = 0; clearInterval(window.__idleW); window.__idleW = setInterval(() => { try { if (!window.__idleAt && window.L2Call.state().state === 'idle') window.__idleAt = Date.now(); } catch (e) {} }, 50);
    // Тосты: опрос текста страницы (тост может появиться пустым и получить текст позже).
    if (!window.__toastPoll) { window.__toasts = []; window.__toastPoll = setInterval(() => { const t = document.getElementById('l2-toast'); const x = t ? (t.textContent || '').trim() : ''; if (x && window.__toasts[window.__toasts.length - 1] !== x) window.__toasts.push(x.slice(0, 80)); }, 100); } }).catch(() => {});
}
async function idleAt(page) { return page.evaluate(() => window.__idleAt || 0).catch(() => 0); }
async function clickLabel(page, re) {
  const ok = await page.evaluate(src => {
    const r = new RegExp(src);
    const b = [...document.querySelectorAll('button')].find(x => x.offsetParent && r.test(x.getAttribute('title') || x.getAttribute('data-label') || x.getAttribute('aria-label') || ''));
    if (!b) return false; b.click(); return true;
  }, re.source);
  if (!ok) throw new Fail('нет кнопки ' + re.source);
}
// Отметка начала звонка: дальше меряем только RTCPeerConnection, созданные после неё.
async function markCall(...pages) { for (const p of pages) await p.evaluate(() => { window.__pcMark = (window.__pcs || []).length; }).catch(() => {}); }
// После отбоя у страницы не должно остаться открытых RTCPeerConnection (иначе копятся выделения TURN).
async function openPcs(page) { return page.evaluate(() => (window.__pcs || []).filter(p => p.connectionState !== 'closed' && p.signalingState !== 'closed').length).catch(() => -1); }
const connected = s => !!s && /connected|completed/.test(s.ice);

async function waitConnected(sides, ms = 90000) {
  const t0 = Date.now();
  for (;;) {
    const st = await Promise.all(sides.map(s => s.stats().catch(() => null)));
    if (st.every(connected)) return st;
    if (Date.now() - t0 > ms) throw new Fail('нет ICE connected: ' + JSON.stringify(st));
    await sleep(500);
  }
}
// Держим звонок: каждые 5 с у обеих сторон ICE connected, растут bytesReceived и аудио-байты; звук слышен (audioLevel > 0
// хотя бы раз — fake-audio Chrome даёт тон), элемент собеседника: srcObject есть, muted=false, paused=false.
// silent[i] = собеседник стороны i шлёт тишину (у него нет микрофона) — audioLevel у i не проверяем.
async function hold(sides, secs, silent = []) {
  let prev = await Promise.all(sides.map(s => s.stats()));
  const t0 = Date.now(); let n = 0; const lvl = sides.map(() => 0);
  while (Date.now() - t0 < secs * 1000) {
    await sleep(5000);
    const cur = await Promise.all(sides.map(s => s.stats().catch(() => null)));
    const at = Math.round((Date.now() - t0) / 1000);
    sides.forEach((s, i) => {
      const c = cur[i], p = prev[i];
      if (!connected(c)) throw new Fail(`${s.name}: соединение пропало на ${at} с (${c && c.ice})`);
      if (!(c.bytes > p.bytes)) throw new Fail(`${s.name}: bytesReceived не растёт на ${at} с (${p.bytes} → ${c.bytes}); собеседник: ${JSON.stringify(cur[1 - i])}`);
      if (!(c.abytes > p.abytes)) throw new Fail(`${s.name}: не приходит звук (audio bytesReceived ${p.abytes} → ${c.abytes}) на ${at} с`);
      if (!c.el || !c.el.src || c.el.muted || c.el.paused || !c.el.sameTrack) throw new Fail(`${s.name}: элемент собеседника не играет поток собеседника: ${JSON.stringify(c.el)}`);
      lvl[i] = Math.max(lvl[i], c.alevel);
    });
    prev = cur; n++;
  }
  sides.forEach((s, i) => { if (!silent[i] && !(lvl[i] > 0)) throw new Fail(`${s.name}: собеседника не слышно (audioLevel ≤ ${lvl[i]} всё время; уровень своего микрофона у собеседника ${prev[1 - i] && prev[1 - i].micLevel})`); });
  return { checks: n, bytes: prev.map(x => x.bytes), audioLevel: lvl.map(x => Math.round(x * 1000) / 1000), micLevel: prev.map(x => x.micLevel), audioSent: prev.map(x => x.atx), pair: prev.map(x => x.pair) };
}
// Громкость входящего звука за ms: средняя энергия (Δ totalAudioEnergy / Δ totalSamplesDuration) — не зависит от того,
// попал ли замер на паузу тона fake-audio. 0 — тишина.
async function levelMax(side, ms = 10000) { const a = await side.stats(); await sleep(ms); const b = await side.stats(); const d = (b.adur || 0) - (a.adur || 0); return d > 0 ? +(((b.aenergy || 0) - (a.aenergy || 0)) / d).toPrecision(3) : 0; }
async function videoGrows(side, ms = 3000) { const a = await side.stats(); await sleep(ms); const b = await side.stats(); return b.vbytes > a.vbytes; }
// Микрофон и камера выкл/вкл у стороны `me`; собеседник `peer` должен перестать/снова получать видео.
async function toggles(me, peer, video) {
  const before = await levelMax(peer);
  await me.mic(); await sleep(1500);
  must((await me.stats()).audioOn === false, me.name + ': микрофон выключен (track.enabled=false)');
  const off = await levelMax(peer);
  if (me.sound !== false) must(before > 1e-7 && off < before / 10, peer.name + ': звук от ' + me.name + ' пропал (энергия ' + before + ' → ' + off + ')');
  await me.mic(); await sleep(1500);
  must((await me.stats()).audioOn === true, me.name + ': микрофон включён (track.enabled=true)');
  // «Вернулся»: энергия выше тишины (off) минимум в 100 раз и > 1e-7. Тон fake-audio + АРУ дают разную громкость,
  // поэтому сравниваем с тишиной, а не с громкостью до выключения; если мало — ещё один замер 15 с.
  const back = x => x > Math.max(off * 100, 1e-7);
  let on = await levelMax(peer);
  if (!back(on)) on = Math.max(on, await levelMax(peer, 15000));
  if (me.sound !== false) must(back(on), peer.name + ': звук от ' + me.name + ' вернулся (энергия ' + on + ', тишина ' + off + ')');
  if (!video) return;
  // «Плохая связь» в вебе сама отключает видео (остаётся звук) — на слабой машине это бывает; тогда видео-шаги пропускаем.
  const weak = await Promise.all([me.page, peer.page].map(p => p.evaluate(() => !!((window.L2Call && window.L2Call.state().weak) || document.getElementById('l2-weak'))).catch(() => false)));
  if (weak[0] || weak[1]) { log('  skip видео-шаги: веб включил режим «Плохая связь — только звук»', JSON.stringify(weak)); skipped.push(me.name + ': видео (плохая связь)'); return; }
  must(await videoGrows(peer), peer.name + ': видео от ' + me.name + ' идёт');
  await me.cam(); await sleep(1500);
  must((await me.stats()).videoOn === false, me.name + ': камера выключена');
  must(!(await videoGrows(peer, 2500)), peer.name + ': видео от ' + me.name + ' перестало расти');
  await me.cam();
  const t0 = Date.now(); while (!(await me.stats()).videoOn && Date.now() - t0 < 10000) await sleep(300);
  must((await me.stats()).videoOn === true, me.name + ': камера включена');
  await sleep(1500);
  must(await videoGrows(peer, 3000), peer.name + ': видео от ' + me.name + ' снова растёт');
}
async function endCall(caller, callee, byCaller) {
  const who = byCaller ? caller : callee, other = byCaller ? callee : caller;
  await watchIdle(who.page); await watchIdle(other.page);
  const tClick = await who.page.evaluate(() => Date.now());
  await who.hangup();
  if (who.kind === 'web' && other.kind === 'web') {
    const t0 = Date.now(); let a = 0, b = 0;
    while ((!a || !b) && Date.now() - t0 < 15000) { a = a || await idleAt(who.page); b = b || await idleAt(other.page); if (!a || !b) await sleep(200); }
    must(a && a - tClick <= 1000, `«Завершить» одним кликом: экран у ${who.name} закрыт за ${a ? a - tClick : '>15000'} мс (≤ 1000)`);
    must(b && b - tClick <= 3000, `у ${other.name} закрыт за ${b ? b - tClick : '>15000'} мс (≤ 3000)`);
  }
  const t0 = Date.now();
  for (;;) {
    const [a, b] = [await caller.state().catch(() => '?'), await callee.state().catch(() => '?')];
    if (a === 'idle' && b === 'idle') break;
    if (Date.now() - t0 > 15000) throw new Fail(`после «Положить трубку» у ${who.name} не завершилось у обоих: ${caller.name}=${a}, ${callee.name}=${b}`);
    await sleep(400);
  }
  must(true, `«Положить трубку» у ${who.name} — завершилось у обоих (${other.name} тоже)`);
}
// Запись в «Звонках»: строка с собеседником (data-topic) и длительностью разговора.
async function historyHas(page, peerTopic, label) {
  await page.locator('button[data-tab="calls"]').first().click();
  const row = page.locator(`#l2-calls li.l2-call[data-topic="${peerTopic}"]`).first();
  await row.waitFor({ timeout: 20000 });
  const t = (await row.textContent()).trim();
  must(/\d+:\d\d/.test(t), label + ': звонок в истории «Звонки»', t);
  await page.locator('button[data-tab="chats"]').first().click().catch(() => {});
}

// Начать звонок из раздела веба.
async function startFrom(page, how, peer, video) {
  await page.locator(how === 'contacts' ? 'button[data-tab="contacts"]' : how === 'calls' ? 'button[data-tab="calls"]' : 'button[data-tab="chats"]').first().click();
  if (how === 'chat') {
    await page.goto(BASE + '/#/' + peer);
    // Шапка чата: отдельные кнопки «Аудиозвонок» (#l2-hcall-a) и «Видеозвонок» (#l2-hcall-v); в старой версии — #l2-hcall и меню ⋮.
    const btn = page.locator(video ? '#l2-hcall-v:visible' : '#l2-hcall-a:visible, #l2-hcall:visible').first();
    try { await btn.waitFor({ timeout: 45000 }); await btn.click(); return; } catch (e) { if (!video) throw e; }
    await page.locator('#topic-caption-panel i[data-l2i="more_vert"]').first().click();
    await page.locator('ul.menu li').filter({ hasText: /^Видеозвонок$/ }).first().click({ timeout: 10000 });
    return;
  }
  if (how === 'contacts') {
    await page.locator(`#l2-contacts li[data-topic="${peer}"]`).first().click();
    await page.locator('button').filter({ hasText: new RegExp('^' + (video ? 'Видео' : 'Аудио') + '$') }).first().click({ timeout: 10000 });
    return;
  }
  // В «Звонках» у строки нет своих кнопок: нажатие на строку = перезвонить тем же типом звонка.
  const rows = page.locator(`#l2-calls li.l2-call[data-topic="${peer}"]`);
  const row = video ? rows.filter({ hasText: /видеозвонок/i }).first() : rows.filter({ hasNotText: /видеозвонок/i }).first();
  await row.waitFor({ timeout: 20000 });
  await row.click();
}

// ---------------- сценарий ----------------
async function main() {
  const t0 = Date.now(), table = [], run = String(Date.now() % 1e7).padStart(7, '3');
  let A, B, pa, pb, code = 1;
  const linkIds = [];
  try {
    A = await ciSetup(run + '1'); B = await ciSetup(run + '2');
    // Прервали (Ctrl+C / timeout / отмена в CI) — всё равно удалить тестовых пользователей.
    let stopping = false;
    for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, async () => {
      if (stopping) return; stopping = true;   // повторный сигнал не мешает уборке
      log('прервано — удаляю тестовых пользователей');
      await Promise.race([Promise.all([tinode(A.login, A.password, 'del').catch(() => {}), tinode(B.login, B.password, 'del').catch(() => {})]), sleep(20000)]);
      try { if (browser) await Promise.race([browser.close(), sleep(5000)]); } catch {}
      process.exit(130);
    });
    pb = await tinode(B.login, B.password);
    pa = await tinode(A.login, A.password, { to: pb.user, text: 'Привет! Это автотест звонков.' }); // общий личный чат
    log('пользователи', A.login, pa.user, B.login, pb.user);
    // IntensiveWakeUpThrottling: без него headless «усыпляет» одну из страниц на 30+ с (звонок не успевает соединиться).
    const args = ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream', '--autoplay-policy=no-user-gesture-required',
      '--disable-background-timer-throttling', '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows',
      '--disable-features=IntensiveWakeUpThrottling,CalculateNativeWinOcclusion', '--disable-ipc-flooding-protection',
      '--force-webrtc-ip-handling-policy=default_public_interface_only'];   // меньше интерфейсов → меньше выделений TURN (квота на имя)
    browser = process.env.CDP_URL ? await chromium.connectOverCDP(process.env.CDP_URL) : await chromium.launch({ headless: true, args });
    const ctxA = await newCtx(), ctxB = await newCtx();
    const a = await webLogin(ctxA, pa), b = await webLogin(ctxB, pb);
    const A_ = webSide(a, 'A'), B_ = webSide(b, 'B');

    for (const v of VARIANTS) {
      const vt = Date.now(); let err = ''; const info = {}; const extra = [];   // контексты варианта — закрываются при любом исходе
      log('=== ' + v);
      try {
        if (!ALL.includes(v)) throw new Fail('неизвестный вариант');
        if (v === 'decline' || v === 'noanswer') {
          await markCall(a, b);
          await startFrom(a, 'chat', pb.user, false);
          await b.waitForFunction(() => window.L2Call.state().state === 'incoming', null, { timeout: 60000 });
          await watchIdle(a); await watchIdle(b);
          if (v === 'decline') {
            const tClick = await b.evaluate(() => Date.now());
            await b.locator('.incoming-call button.danger').click();
            const t0 = Date.now(); let ia = 0, ib = 0;
            while ((!ia || !ib) && Date.now() - t0 < 15000) { ia = ia || await idleAt(a); ib = ib || await idleAt(b); if (!ia || !ib) await sleep(200); }
            must(ib && ib - tClick <= 1000, `«Отклонить» одним кликом: у B закрыто за ${ib ? ib - tClick : '>15000'} мс`);
            must(ia && ia - tClick <= 3000, `у A экран закрыт за ${ia ? ia - tClick : '>15000'} мс (≤ 3000)`);
          } else {
            await a.evaluate(() => { const t = document.getElementById('l2-toast'); if (t) t.textContent = ''; });   // тост хранит последний текст
            const st0 = await a.evaluate(() => window.L2Call.state().state);
            must(st0 === 'outgoing' || st0 === 'connecting', 'A: идёт вызов (' + st0 + '), B не отвечает');
            const t0 = Date.now();
            await a.waitForFunction(() => window.L2Call.state().state === 'idle', null, { timeout: 75000, polling: 500 })
              .catch(async () => { throw new Fail('A: через 75 с звонок всё ещё ' + await a.evaluate(() => window.L2Call.state().state)); });
            const secs = Math.round((Date.now() - t0) / 1000);
            await a.waitForFunction(() => (window.__toasts || []).length > 0, null, { timeout: 5000 }).catch(() => {});   // тост появляется через ≤ 1 с после закрытия
            await a.waitForFunction(() => { const t = document.getElementById('l2-toast'); return t && t.textContent.trim(); }, null, { timeout: 5000 }).catch(() => {});
            const toasts = (await a.evaluate(() => window.__toasts || [])).concat([await a.evaluate(() => { const t = document.getElementById('l2-toast'); return t ? t.textContent.trim() : ''; })]).filter(Boolean);
            const tEl = await a.evaluate(() => { const t = document.getElementById('l2-toast'); return t ? t.outerHTML.slice(0, 200) : 'нет #l2-toast'; });
            log('  тост сейчас:', tEl);
            must(toasts.some(t => /Собеседник не ответил|Не удалось дозвониться|Нет ответа/.test(t)), `без ответа: сообщение звонящему и экран закрыт (через ~${secs} с после входящего)`, toasts.join(' | ') || 'сообщений не было');
            await b.waitForFunction(() => window.L2Call.state().state === 'idle', null, { timeout: 20000 }).catch(() => {});
            must(await b.evaluate(() => window.L2Call.state().state) === 'idle', 'у B входящий закрылся');
          }
        } else if (!v.startsWith('link-')) {
          const video = v.endsWith('-video'), how = v.split('-')[0];
          let callee = B_, bctx = null, caller = A_, rctx = null;
          if (how === 'relay') {   // отдельные сеансы A и B, где RTCPeerConnection только через TURN
            rctx = await newCtx({}, false, true); bctx = await newCtx({}, false, true); extra.push(rctx, bctx);
            caller = webSide(await webLogin(rctx, pa), 'A(relay)'); callee = webSide(await webLogin(bctx, pb), 'B(relay)');
          }
          // Без устройств: второй сеанс B в отдельном контексте, где getUserMedia всегда отклоняется (обычная вкладка B тоже видит входящий).
          if (how === 'nodevice') { bctx = await newCtx({}, true); extra.push(bctx); callee = webSide(await webLogin(bctx, pb), 'B(без устройств)'); }
          const from = (how === 'nodevice' || how === 'relay') ? 'chat' : how;
          const ap = caller.page;
          await markCall(ap, callee.page);
          await startFrom(ap, from, pb.user, video);
          await ap.waitForFunction(() => ['outgoing', 'connecting'].includes(window.L2Call.state().state), null, { timeout: 15000 });
          must(true, 'A: исходящий (гудки) — ' + from + (video ? ', видео' : ', аудио'));
          await callee.page.waitForFunction(() => window.L2Call.state().state === 'incoming', null, { timeout: 30000 });
          await callee.page.waitForFunction(() => /звонит/.test((document.querySelector('.incoming-call') || {}).textContent || ''), null, { timeout: 5000 }).catch(() => {});
          const inc = await callee.page.locator('.incoming-call').textContent().catch(() => '');
          must(/звонит/.test(inc), callee.name + ': входящий «… звонит»', inc.trim().slice(0, 80));
          // Во время гудков: свой микрофон (.l2-cb.mic2) активен и переключает трек. Всё одним вызовом в странице:
          // сервер гасит вызов без ответа через 30 с, а на слабой машине каждый вызов/скриншот — секунды.
          if (how !== 'nodevice') {
            const [m2, m0, m1, m3] = await ap.evaluate(async () => {
              const mic = () => { try { let f = null; const n = document.getElementById('video-container'); for (const k in n) if (k.startsWith('__reactFiber$')) f = n[k];
                for (let d = 0; f && d < 12; d++, f = f.return) if (f.stateNode && f.stateNode.handleToggleMicClick) { const st = f.stateNode.state.localStream; const t = st && st.getAudioTracks()[0]; return t ? t.enabled : null; } } catch (e) {} return null; };
              const btn = () => [...document.querySelectorAll('.l2-cb.mic2')].find(x => x.offsetParent);
              const w = ms => new Promise(r => setTimeout(r, ms));
              const b0 = btn(); if (!b0) return ['нет']; if (b0.disabled) return ['disabled'];
              const a = mic(); btn().click(); await w(300); const b = mic(); btn().click(); await w(300); return ['ok', a, b, mic()];
            });
            if (m2 === 'нет') skipped.push(v + ': нет .l2-cb.mic2 до ответа');
            else {
              must(m2 === 'ok', 'A: «Микрофон» до ответа активна', m2);
              must(m0 === true && m1 === false && m3 === true, 'A: микрофон выкл/вкл во время гудков (трек ' + m0 + ' → ' + m1 + ' → ' + m3 + ')');
            }
          }
          await callee.page.locator('.incoming-call button.positive').click();
          await shot(callee.page, v + '-1-accepted');
          await waitConnected([caller, callee]);
          must(true, 'ICE connected у обоих');
          await shot(ap, v + '-2-call-A'); await shot(callee.page, v + '-2-call-B');
          const h = await hold([caller, callee], HOLD_S, [how === 'nodevice', false]);
          if (how === 'relay') must(h.pair.every(x => /^relay\//.test(x)), 'выбрана пара через TURN (relay)', h.pair.join(', '));
          must(true, `держится ${HOLD_S} с: ICE connected, bytes и звук у обоих (${h.checks} проверок)`, JSON.stringify(h)); info.pair = h.pair; info.audioLevel = h.audioLevel;
          if (how !== 'nodevice') { await toggles(caller, callee, video); await toggles(callee, caller, video); }
          await endCall(caller, callee, v !== 'calls-audio'); // в одном варианте трубку кладёт принимающий
          await sleep(1500);
          const left = [await openPcs(ap), await openPcs(callee.page)];
          must(left[0] === 0 && left[1] === 0, 'после отбоя все RTCPeerConnection закрыты у обоих', JSON.stringify(left));
          await historyHas(ap, pb.user, 'A'); await historyHas(callee.page, pa.user, 'B');
          if (bctx) { await callee.page.close(); await bctx.close(); }
          if (rctx) { await ap.close(); await rctx.close(); }
        } else {
          // Ссылка владельца A.
          const lj = await api(pa.token, 'POST', '/links', { title: 'Автотест ' + v, mode: 'video', ttl: '1h', once: false });
          must(lj.ok, 'ссылка создана', lj.link && lj.link.id); linkIds.push(lj.link.id);
          let gctx = null, gpage;
          if (v === 'link-auth') { gpage = await newPage(ctxB); extra.push({ pages: () => [gpage], close: () => gpage.close() }); } // B вошёл в этом контексте — токен в localStorage
          else { gctx = await newCtx({ viewport: { width: 390, height: 760 }, isMobile: true, hasTouch: true, deviceScaleFactor: 1 }); extra.push(gctx); gpage = await newPage(gctx); }
          gpage.on('dialog', d => d.accept().catch(() => {}));
          await markCall(a);
          await gpage.goto(lj.link.url + '?ci=' + ciHeader());
          await gpage.locator('#s-prep').waitFor({ state: 'visible', timeout: 20000 });
          if (v === 'link-auth') {
            const t = await gpage.locator('#p-callas').textContent({ timeout: 10000 });
            must(await gpage.locator('#p-callas').isVisible() && /^Позвонить как Тест CI/.test(t), 'гость вошёл: «Позвонить как <имя>»', t);
            await shot(gpage, v + '-0-prep'); await gpage.click('#p-callas');
          } else {
            await gpage.fill('#p-name', 'Гость Автотест'); await shot(gpage, v + '-0-prep'); await gpage.click('#p-call');
          }
          await gpage.waitForFunction(() => /Ждём организатора/.test(document.getElementById('w-title').textContent), null, { timeout: 15000 });
          await sleep(400);
          must(await gpage.evaluate(() => window.__gcRingback && window.__gcRingback()), 'гость: «Ждём организатора…» + гудки');
          await a.waitForFunction(() => window.L2Call.state().state === 'incoming', null, { timeout: 30000 })
            .catch(async () => { throw new Fail('A: нет входящего, состояние ' + JSON.stringify(await a.evaluate(() => window.L2Call.state()))); });
          await a.waitForFunction(() => /звонит/.test((document.querySelector('.incoming-call') || {}).textContent || ''), null, { timeout: 5000 }).catch(() => {});
          const inc = (await a.locator('.incoming-call').textContent()).trim();
          const who = v === 'link-auth' ? 'Тест CI' : 'Гость Автотест';
          must(inc.includes(who) && inc.includes('Автотест ' + v), 'A: входящий «<имя> звонит по ссылке «…»»', inc.slice(0, 120));
          await shot(a, v + '-1-incoming');
          await a.locator('.incoming-call button.positive').click();
          const G_ = guestSide(gpage, v === 'link-auth' ? 'B(по ссылке)' : 'гость');
          await waitConnected([A_, G_]);
          must(true, 'ICE connected у обоих');
          await shot(a, v + '-2-call-A'); await shot(gpage, v + '-2-call-guest');
          const h = await hold([A_, G_], HOLD_S);
          must(true, `держится ${HOLD_S} с: ICE connected, bytes и звук у обоих (${h.checks} проверок)`, JSON.stringify(h)); info.pair = h.pair; info.audioLevel = h.audioLevel;
          await toggles(A_, G_, true); await toggles(G_, A_, true);
          await G_.hangup();
          await gpage.locator('#s-end').waitFor({ state: 'visible', timeout: 10000 });
          await a.waitForFunction(() => window.L2Call.state().state === 'idle', null, { timeout: 15000 });
          must(true, '«Положить трубку» у гостя — завершилось у обоих');
          await sleep(2500);
          const lk = await api(pa.token, 'GET', '/links/' + lj.link.id), hh = ((lk.link || {}).history || [])[0];
          must(hh && hh.result === 'accepted' && hh.duration >= HOLD_S && hh.name === who, '«Мои ссылки»: звонок в истории ссылки', JSON.stringify(hh));
          if (v === 'link-auth') { await historyHas(a, pb.user, 'A'); await historyHas(b, pa.user, 'B'); }
          else {
            await a.locator('button[data-tab="calls"]').first().click();
            const row = (await a.locator('#l2-calls li.l2g-call').first().textContent({ timeout: 20000 })).trim();
            must(row.includes(who), 'A: гостевой звонок в «Звонках» (имя + значок ссылки)', row);
          }
          await gpage.close(); if (gctx) await gctx.close();
        }
        table.push({ variant: v, ok: true, seconds: Math.round((Date.now() - vt) / 1000), ...info });
      } catch (e) {
        err = String(e.message || e).split('\n')[0].slice(0, 400);
        log('  FAIL', err);
        await shot(a, v + '-fail-A'); try { await shot(B_.page, v + '-fail-B'); } catch {}
        table.push({ variant: v, ok: false, seconds: Math.round((Date.now() - vt) / 1000), error: err, ...info });
        // привести стороны в исходное состояние: отбой во всех вкладках варианта, закрыть его контексты
        for (const c of extra) for (const p of c.pages()) await p.evaluate(() => { try { window.L2Call && window.L2Call.hangup(); } catch (e) {} try { document.getElementById('c-hang') && document.getElementById('c-hang').click(); } catch (e) {} }).catch(() => {});
        for (const p of [a, B_.page]) await p.evaluate(() => { try { window.L2Call.hangup(); } catch (e) {} }).catch(() => {});
        await sleep(3000);
        for (const p of [a, B_.page]) await p.waitForFunction(() => window.L2Call.state().state === 'idle', null, { timeout: 30000 }).catch(() => {});
      }
      for (const c of extra) await c.close().catch(() => {});
    }
    code = table.every(r => r.ok) && table.length === VARIANTS.length ? 0 : 1;
  } catch (e) {
    table.push({ variant: 'подготовка', ok: false, seconds: Math.round((Date.now() - t0) / 1000), error: String(e.message || e).slice(0, 400) });
    log('ОШИБКА', e.message || e);
  } finally {
    for (const id of linkIds) await api(pa.token, 'DELETE', '/links/' + id).catch(() => {});
    if (browser) await browser.close().catch(() => {});
    const del = [];
    if (A) del.push(await tinode(A.login, A.password, 'del').catch(() => false));
    if (B) del.push(await tinode(B.login, B.password, 'del').catch(() => false));
    if (del.some(x => !x)) { table.push({ variant: 'уборка', ok: false, seconds: 0, error: 'пользователи не удалены' }); code = code || 1; }
  }
  const ok = code === 0;
  const res = { test: 'calls-all', ok, holdS: HOLD_S, seconds: Math.round((Date.now() - t0) / 1000), table, skipped };
  fs.writeFileSync(path.join(OUT, 'result.json'), JSON.stringify(res, null, 1));
  console.log(JSON.stringify(res));
  return ok ? 0 : 1;
}
main().then(c => process.exit(c), e => { console.log(JSON.stringify({ test: 'calls-all', ok: false, error: String(e) })); process.exit(2); });
