#!/usr/bin/env node
// Линия 2.0 — автотест медиа веба: голосовые, вставка/перетаскивание, повтор отправки, плашка соединения, уведомления.
// Один headless Chromium: L2_CDP=http://127.0.0.1:9566 (уже запущенный) — иначе скрипт сам поднимает
//   docker run --rm --memory=1g --cpus=1 zenika/alpine-chrome:124 (--use-fake-device-for-media-stream) и удаляет его в конце.
// puppeteer-core 22: из node_modules рядом или L2_PUPPETEER (по умолчанию /tmp/l2web/node_modules/puppeteer-core).
// CI_TOKEN — из env или /opt/linia2/.env. Все запросы к v2.chat-linia.site несут X-L2-CI (CONTRACTS.md «Пропуск автотестов»).
// Пользователи — POST /invite/api/ci/setup; в конце удаляются вместе с чатами (как del.mjs). CSP сайта НЕ отключается.
// Проверки (CASES=через запятую, по умолчанию все): voice, paste, drop, retry, net, notify, receipts, viewer.
// Выход 0 — только если всё прошло; последняя строка stdout — JSON {ok, table:[{case, ok, ms, error, detail}], shots}.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';

let puppeteer;
try { puppeteer = (await import('puppeteer-core')).default; }
catch { puppeteer = createRequire(import.meta.url)(process.env.L2_PUPPETEER || '/tmp/l2web/node_modules/puppeteer-core'); }

const BASE = (process.env.BASE || 'https://v2.chat-linia.site').replace(/\/$/, '');
const HOST = new URL(BASE).host;
const APIKEY = 'AQEAAAABAAD_rAp4DJh05a1HAwFT3A6K';
const OUT = process.env.OUT_DIR || '/tmp/l2-media-shots';
fs.mkdirSync(OUT, { recursive: true });
let CI = process.env.CI_TOKEN || '';
if (!CI) try { CI = ((fs.readFileSync('/opt/linia2/.env', 'utf8').match(/^CI_TOKEN=(.*)$/m) || [])[1] || '').trim().replace(/^["']|["']$/g, ''); } catch {}
if (!CI) { console.log(JSON.stringify({ ok: false, error: 'нет CI_TOKEN' })); process.exit(2); }
const ALL = ['voice', 'paste', 'drop', 'retry', 'net', 'notify', 'receipts', 'viewer'];
const CASES = process.env.CASES ? process.env.CASES.split(',').map(s => s.trim()).filter(Boolean) : ALL;

const ciHeader = () => crypto.createHmac('sha256', CI).update('linia2-ci:' + new Date().toISOString().slice(0, 10).replace(/-/g, '')).digest('hex');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const log = (...a) => console.error(new Date().toISOString().slice(11, 19), ...a);
class Fail extends Error {}
function must(c, what, d = '') { if (!c) throw new Fail(what + (d ? ' — ' + String(d).slice(0, 300) : '')); log('  ok', what, d ? '— ' + String(d).slice(0, 160) : ''); }

async function ciSetup(run) {
  const r = await fetch(BASE + '/invite/api/ci/setup', { method: 'POST', headers: { Authorization: 'Bearer ' + CI, 'Content-Type': 'application/json', 'X-L2-CI': ciHeader() }, body: JSON.stringify({ run }) });
  const j = await r.json(); if (!j.ok) throw new Error('ci/setup: ' + r.status); return j;
}
async function pushCheck(login) {
  const r = await fetch(BASE + '/invite/api/ci/push-check', { method: 'POST', headers: { Authorization: 'Bearer ' + CI, 'Content-Type': 'application/json', 'X-L2-CI': ciHeader() }, body: JSON.stringify({ login }) });
  return r.json().catch(() => ({ status: r.status }));
}
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

// ---------------- браузер ----------------
let browser, ownChrome = '';
async function startBrowser() {
  let url = process.env.L2_CDP;
  if (!url) {
    const port = String(9600 + Math.floor(Math.random() * 300));
    ownChrome = 'l2-media-' + Date.now();
    execFileSync('docker', ['run', '-d', '--rm', '--name', ownChrome, '--memory=1g', '--cpus=1', '--network', 'host', '--shm-size', '256m', 'zenika/alpine-chrome:124',
      '--headless', '--no-sandbox', '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=' + port, '--disable-gpu', '--lang=ru-RU',
      '--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream', '--autoplay-policy=no-user-gesture-required', 'about:blank'], { stdio: 'ignore' });
    url = 'http://127.0.0.1:' + port;
    for (let i = 0; i < 40; i++) { try { await (await fetch(url + '/json/version')).json(); break; } catch { await sleep(250); } }
  }
  browser = await puppeteer.connect({ browserURL: url, defaultViewport: null, protocolTimeout: 120000 });
}
function stopBrowser() { if (ownChrome) try { execFileSync('docker', ['rm', '-f', ownChrome], { stdio: 'ignore' }); } catch {} }
const blocked = { upload: false };
async function newPage(name) {
  const ctx = await browser.createBrowserContext();
  await ctx.overridePermissions(BASE, ['microphone', 'camera', 'notifications', 'clipboard-read', 'clipboard-write', 'clipboard-sanitized-write']);
  const p = await ctx.newPage();
  await p.setViewport({ width: 1280, height: 820 });
  await p.setRequestInterception(true);
  p.on('request', rq => {
    let u; try { u = new URL(rq.url()); } catch { return rq.continue(); }
    if (u.host !== HOST) return rq.continue();
    if (blocked.upload && rq.method() === 'POST' && u.pathname.startsWith('/v0/file/u')) return rq.abort('failed');
    rq.continue({ headers: { ...rq.headers(), 'x-l2-ci': ciHeader() } });
  });
  p.logs = []; p.file403 = [];
  p.on('console', m => { const t = m.text(); if (m.type() === 'error' || /CSP|Content Security|Refused/.test(t)) p.logs.push(m.type() + ': ' + t.slice(0, 300)); });
  p.on('pageerror', e => p.logs.push('PAGEERROR: ' + e.message.slice(0, 300)));
  p.on('response', r => { if (/\/v0\/file\/s\//.test(r.url()) && r.status() === 403) p.file403.push(r.url().replace(/\?.*$/, '')); });
  p.ctx = ctx; p.name = name;
  return p;
}
async function webLogin(p, params) {
  await p.goto(BASE + '/invite/', { waitUntil: 'domcontentloaded' });
  await p.evaluate((t, e) => { localStorage.setItem('keep-logged-in', 'true'); localStorage.setItem('auth-token', JSON.stringify({ token: t, expires: e })); localStorage.setItem('l2PushLater', String(Date.now())); }, params.token, params.expires);
  await p.goto(BASE + '/', { waitUntil: 'domcontentloaded' });
  await waitSel(p, 'button[data-tab="calls"]', 45000);
  await p.waitForFunction(() => !!window.L2Media, { timeout: 20000, polling: 250 });
}
async function openChat(p, topic) {
  await p.evaluate(t => { location.hash = '#/' + t; }, topic);
  await waitSel(p, '#send-message-input', 30000);
  await sleep(1200);
}
const shot = async (p, name) => { const f = path.join(OUT, name + '.png'); try { await p.screenshot({ path: f }); shots.push(f); } catch {} return f; };
const shots = [];
// Ожидание без requestAnimationFrame (фоновая вкладка в headless его не крутит).
const waitSel = (p, sel, ms) => p.waitForFunction(s => document.querySelector(s), { timeout: ms, polling: 200 }, sel);
const count = (p, sel) => p.evaluate(s => document.querySelectorAll(s).length, sel);
const infoBox = p => p.evaluate(() => [...document.querySelectorAll('.info-box')].map(e => e.innerText.trim()).filter(Boolean).join(' | '));

// ---------------- сценарии ----------------
async function caseVoice(a, b) {
  await a.bringToFront();
  const before = await count(b, '#scroller .audio-player');
  const r = await a.evaluate(() => { const i = [...document.querySelectorAll('#send-message-panel i')].find(x => x.textContent.trim() === 'mic'); if (!i) return false; i.closest('a').click(); return true; });
  must(r, 'кнопка записи голосового');
  await waitSel(a, '#send-message-panel .audio canvas', 10000);
  await sleep(3500);
  await a.evaluate(() => [...document.querySelectorAll('#send-message-panel .audio i')].find(x => x.textContent.trim() === 'send').closest('a').click());
  await sleep(2500);
  const err = await infoBox(a);
  await b.bringToFront();
  must(!/соединени/i.test(err), 'нет плашки «Нет соединения» после отправки', err);
  must(!a.logs.some(l => /Content Security Policy/.test(l)), 'нет ошибок CSP', a.logs.filter(l => /Content Security/.test(l)).join(' ').slice(0, 200));
  await b.waitForFunction(n => document.querySelectorAll('#scroller .audio-player').length > n, { timeout: 20000, polling: 250 }, before);
  must(true, 'голосовое пришло второму');
  const st = await b.evaluate(async () => {
    const pl = [...document.querySelectorAll('#scroller .audio-player')].pop();
    const fiber = o => { for (const k in o) if (k.startsWith('__reactFiber$')) return o[k]; };
    let f = fiber(pl), inst = null; for (let d = 0; f && d < 10; d++, f = f.return) if (f.stateNode && 'audioPlayer' in f.stateNode) { inst = f.stateNode; break; }
    const play = [...pl.querySelectorAll('i')].find(i => /^play_(arrow|circle)/.test(i.textContent.trim()));
    if (play) (play.closest('a') || play).click();
    await new Promise(r => setTimeout(r, 2000));
    const ap = inst && inst.audioPlayer;
    return { duration: inst ? inst.props.duration : 0, preview: !!(inst && inst.state.preview), canvas: !!pl.querySelector('canvas'), t: ap ? ap.currentTime : -1, err: ap && ap.error ? ap.error.code : 0, text: pl.innerText };
  });
  await shot(b, 'voice-received');
  must(st.duration > 1000, 'длительность голосового > 1 с', JSON.stringify(st));
  must(st.preview && st.canvas, 'волна голосового есть');
  must(st.t > 0.3, 'воспроизводится (currentTime растёт)', st.t);
  return 'длительность ' + st.duration + ' мс, t=' + st.t.toFixed(2);
}
// PNG в браузере → «вставка» в поле сообщения (ClipboardEvent paste с DataTransfer, как Ctrl+V скриншота).
const PASTE_JS = (kind) => `(async () => {
  const c = document.createElement('canvas'); c.width = 640; c.height = 400; const x = c.getContext('2d');
  x.fillStyle = '#2FA987'; x.fillRect(0, 0, 640, 400); x.fillStyle = '#fff'; x.font = '48px sans-serif'; x.fillText('Скриншот ' + Date.now() % 10000, 40, 200);
  const blob = await new Promise(r => c.toBlob(r, 'image/png'));
  const dt = new DataTransfer(); dt.items.add(new File([blob], 'image.png', { type: 'image/png' }));
  if (${JSON.stringify(kind)} === 'drop') {
    const t = document.querySelector('#scroller') || document.querySelector('#topic-view');
    t.dispatchEvent(new DragEvent('dragenter', { bubbles: true, cancelable: true, dataTransfer: dt }));
    t.dispatchEvent(new DragEvent('dragover', { bubbles: true, cancelable: true, dataTransfer: dt }));
    t.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: dt }));
  } else {
    const i = document.getElementById('send-message-input'); i.focus();
    i.dispatchEvent(new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: dt }));
  }
  return true; })()`;
async function caseImage(a, b, kind) {
  await a.bringToFront();
  const before = await count(b, '#scroller img.inline-image');
  const pr = await a.evaluate(PASTE_JS(kind));
  const okTray = await waitSel(a, '#l2-paste .it img', 8000).then(() => true, () => false);
  must(okTray, 'превью появилось (' + kind + ')', okTray ? '' : JSON.stringify(pr) + ' ' + await a.evaluate(() => (document.getElementById('l2-toast') || {}).textContent + ' tray=' + !!document.getElementById('l2-paste') + ' panel=' + !!document.getElementById('send-message-panel')));
  const pos = await a.evaluate(() => { const t = document.getElementById('l2-paste').getBoundingClientRect(), p = document.getElementById('send-message-panel').getBoundingClientRect(); return { tb: t.bottom, pt: p.top, w: document.querySelector('#l2-paste .it img').naturalWidth }; });
  must(pos.tb <= pos.pt + 2 && pos.w > 0, 'превью над полем ввода (' + kind + ')', JSON.stringify(pos));
  const cap = 'Подпись ' + kind;
  await a.type('#l2-paste .cap', cap);
  await shot(a, kind + '-preview');
  await a.click('#l2-paste .l2-btn.send');
  await b.bringToFront();
  await b.waitForFunction(n => document.querySelectorAll('#scroller img.inline-image').length > n, { timeout: 25000, polling: 250 }, before);
  const st = await b.waitForFunction(c => {
    const im = [...document.querySelectorAll('#scroller img.inline-image')].pop();
    return im && im.complete && im.naturalWidth > 0 && document.querySelector('#scroller').innerText.includes(c) ? { w: im.naturalWidth, src: im.src.slice(0, 30) } : false;
  }, { timeout: 20000, polling: 250 }, cap).then(h => h.jsonValue()).catch(() => null);
  await shot(b, kind + '-received');
  must(st, 'у второго картинка видна сразу, с подписью (' + kind + ')', JSON.stringify(st));
  must(!(await a.$('#l2-paste')), 'превью закрылось после отправки');
  return JSON.stringify(st);
}
async function caseRetry(a, b) {
  await a.bringToFront();
  // 3,2 МБ (больше лимита «в сообщении» 4 МБ*0,75) — загрузка файлом; загрузку обрываем → «Файл не загрузился — повторить».
  blocked.upload = true;
  const beforeB = await count(b, '#scroller .attachment, #scroller a[download]');
  await a.evaluate(() => {
    const buf = new Uint8Array(3.2 * 1048576); for (let i = 0; i < buf.length; i += 4096) buf[i] = i & 255;
    const dt = new DataTransfer(); dt.items.add(new File([buf], 'отчёт.bin', { type: 'application/octet-stream' }));
    const i = document.getElementById('send-message-input'); i.focus();
    i.dispatchEvent(new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: dt }));
  });
  await waitSel(a, '#l2-paste .it.file', 5000);
  await a.click('#l2-paste .l2-btn.send');
  const btn = await waitSel(a, '#scroller .l2-retry', 30000).catch(() => null);
  const label = btn ? await btn.evaluate(e => e.textContent) : '';
  const box = await infoBox(a);
  await shot(a, 'retry-failed');
  must(btn && /Файл не загрузился/.test(label), 'у сообщения «Файл не загрузился — повторить»', label);
  must(!/соединени/i.test(box), 'общей плашки «Нет соединения» нет', box);
  blocked.upload = false;
  await btn.click();
  await a.waitForFunction(() => !document.querySelector('#scroller .l2-retry'), { timeout: 40000, polling: 250 });
  await b.waitForFunction(() => /отчёт\.bin/.test(document.querySelector('#scroller').innerText), { timeout: 30000, polling: 250 });
  must(true, 'повтор отправил файл, у второго он есть');
  return label;
}
async function connState(p) { return p.evaluate(() => { const b = document.getElementById('l2-conn'); return b ? (b.classList.contains('off') ? 'red' : 'yellow') + ':' + b.innerText.trim() : ''; }); }
async function caseNet(a) {
  await a.bringToFront();
  await a.evaluate(() => { location.hash = ''; });
  await sleep(1500);
  async function outage(ms) {
    const seen = []; const t0 = Date.now();
    await a.setOfflineMode(true);
    while (Date.now() - t0 < ms) { const s = await connState(a); seen.push([Date.now() - t0, s]); await sleep(250); }
    await a.setOfflineMode(false);
    const t1 = Date.now(); let goneAt = -1;
    while (Date.now() - t1 < 15000) { const s = await connState(a); if (!s) { goneAt = Date.now() - t1; break; } await sleep(100); }
    const box = await infoBox(a);
    return { seen, goneAt, box };
  }
  const o3 = await outage(3000);
  const red3 = o3.seen.filter(s => s[1].startsWith('red'));
  must(o3.seen.some(s => s[1].startsWith('yellow')) && !red3.length, 'обрыв 3 с — только жёлтая «Подключение…»', JSON.stringify(o3.seen.filter((s, i) => i % 4 === 0)));
  must(o3.goneAt >= 0 && o3.goneAt < 2500, 'плашка исчезла после восстановления (3 с)', o3.goneAt + ' мс');
  await sleep(3000);
  const o15 = await outage(15000);
  await shot(a, 'net-after-15s');
  const firstRed = (o15.seen.find(s => s[1].startsWith('red')) || [0])[0];
  must(firstRed >= 9500 && o15.seen.some(s => s[0] < 9000 && s[1].startsWith('yellow')), 'обрыв 15 с — жёлтая, красная после 10 с', 'красная с ' + firstRed + ' мс');
  must(o15.goneAt >= 0 && o15.goneAt < 2500, 'красная исчезла сразу после восстановления', o15.goneAt + ' мс');
  must(!/соединени|связи/i.test(o15.box), 'общей красной плашки Tinode нет', o15.box);
  return 'красная с ' + firstRed + ' мс; исчезла за ' + o15.goneAt + ' мс';
}

// Отметки у отправителя: отправлено (✓) → доставлено (серые ✓✓) → прочитано (красные ✓✓) без перезагрузки — скриншоты.
async function lastMark(a, text) {
  return a.evaluate(t => {
    const li = [...document.querySelectorAll('#scroller > li')].filter(l => l.innerText.includes(t)).pop(); if (!li) return null;
    const i = li.querySelector('.timestamp i'); if (!i) return { icon: '' };
    return { icon: i.getAttribute('data-l2i') || i.textContent.trim(), cls: i.className, color: getComputedStyle(i).color };
  }, text);
}
async function markShot(a, text, name) {
  const li = await a.evaluateHandle(t => [...document.querySelectorAll('#scroller > li')].filter(l => l.innerText.includes(t)).pop(), text);
  const f = path.join(OUT, name + '.png');
  try { await li.asElement().screenshot({ path: f }); shots.push(f); } catch { await shot(a, name); }
  await shot(a, name + '-full');
}
async function caseReceipts(a, b, pb) {
  const text = 'Проверка отметок ' + (Date.now() % 100000);
  await b.goto('about:blank'); // второй не в сети
  await sleep(2000);
  await a.bringToFront();
  await a.type('#send-message-input', text); await a.keyboard.press('Enter');
  await a.waitForFunction(t => { const li = [...document.querySelectorAll('#scroller > li')].filter(l => l.innerText.includes(t)).pop(); const i = li && li.querySelector('.timestamp i'); return i && /^(done|check)$/.test(i.getAttribute('data-l2i') || i.textContent.trim()); }, { timeout: 15000, polling: 250 }, text).catch(() => {});
  const m1 = await lastMark(a, text); await markShot(a, text, 'receipt-1-sent');
  await b.goto(BASE + '/', { waitUntil: 'domcontentloaded' }); // второй в сети, чат не открыт
  await waitSel(b, 'button[data-tab="calls"]', 45000);
  await a.bringToFront();
  await a.waitForFunction(t => { const li = [...document.querySelectorAll('#scroller > li')].filter(l => l.innerText.includes(t)).pop(); const i = li && li.querySelector('.timestamp i'); return i && /done_all|checks/.test((i.getAttribute('data-l2i') || '') + i.textContent); }, { timeout: 20000, polling: 250 }, text).catch(() => {});
  const m2 = await lastMark(a, text); await markShot(a, text, 'receipt-2-delivered');
  await b.bringToFront(); await openChat(b, pb); await sleep(1500);
  await a.bringToFront();
  await a.waitForFunction(t => { const li = [...document.querySelectorAll('#scroller > li')].filter(l => l.innerText.includes(t)).pop(); const i = li && li.querySelector('.timestamp i'); return i && i.classList.contains('blue'); }, { timeout: 20000, polling: 250 }, text).catch(() => {});
  const m3 = await lastMark(a, text); await markShot(a, text, 'receipt-3-read');
  const d = JSON.stringify({ sent: m1, delivered: m2, read: m3 });
  must(m1 && /^(done|check)$/.test(m1.icon), 'отправлено — одна ✓', d);
  must(m2 && /done_all|checks/.test(m2.icon) && !/blue/.test(m2.cls), 'доставлено — ✓✓ без «прочитано»', d);
  must(m3 && /blue/.test(m3.cls), 'прочитано — ✓✓ «прочитано» без перезагрузки', d);
  return d;
}

// ---------------- main ----------------
const table = [];
let A, B, pa, pb, code = 1;
try {
  const run = String(Date.now() % 1e7).padStart(7, '7');
  A = await ciSetup(run + '1'); B = await ciSetup(run + '2');
  pb = await tinode(B.login, B.password);
  pa = await tinode(A.login, A.password, { to: pb.user, text: 'Привет! Это автотест медиа.' });
  log('пользователи', A.login, B.login);
  await startBrowser();
  const a = await newPage('A'), b = await newPage('B');
  await webLogin(a, pa); await webLogin(b, pb);
  await openChat(a, pb.user); await openChat(b, pa.user);
  const run1 = async (name, fn) => {
    if (!CASES.includes(name)) return;
    const t0 = Date.now(); log('==', name);
    try { const d = await fn(); table.push({ case: name, ok: true, ms: Date.now() - t0, detail: d || '' }); }
    catch (e) { log('  FAIL', e.message); await shot(a, 'fail-' + name + '-A'); await shot(b, 'fail-' + name + '-B'); table.push({ case: name, ok: false, ms: Date.now() - t0, error: e.message.slice(0, 400) }); }
  };
  await run1('voice', () => caseVoice(a, b));
  await run1('paste', () => caseImage(a, b, 'paste'));
  await run1('drop', () => caseImage(a, b, 'drop'));
  await run1('retry', () => caseRetry(a, b));
  await run1('receipts', () => caseReceipts(a, b, pa.user));
  await run1('net', () => caseNet(a));
  const f403 = [...new Set([...a.file403, ...b.file403])];
  table.push({ case: 'no-403', ok: !f403.length, detail: f403.join(' ') });
  code = table.every(r => r.ok) ? 0 : 1;
  if (a.logs.length || b.logs.length) log('console:', [...a.logs, ...b.logs].slice(0, 15).join('\n'));
} catch (e) {
  table.push({ case: 'setup', ok: false, error: String(e && e.message || e).slice(0, 300) });
} finally {
  try { if (browser) await browser.disconnect(); } catch {}
  stopBrowser();
  const del = [];
  if (A) del.push(await tinode(A.login, A.password, 'del').catch(() => false));
  if (B) del.push(await tinode(B.login, B.password, 'del').catch(() => false));
  console.log(JSON.stringify({ ok: code === 0, table, deleted: del, shots }));
  process.exit(code);
}
