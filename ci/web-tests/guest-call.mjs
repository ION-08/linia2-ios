#!/usr/bin/env node
// Линия 2.0 — браузерный тест «Гостевые ссылки на звонок» для GitHub Actions (ubuntu, Playwright Chromium).
//
//   npm i playwright && npx playwright install --with-deps chromium
//   CI_TOKEN=… OUT_DIR=./shots node ci/web-tests/guest-call.mjs
//
// Сценарий: владелец (POST /invite/api/ci/setup) входит в веб → «Звонки» → кнопка 🔗 «Ссылка на звонок» → «Создать» → гость (другой контекст)
// открывает /call/<token> → «Позвонить» → у владельца входящий «<имя> звонит по ссылке «<название>»» → «Принять» →
// ICE connected + растущий bytesReceived у обоих → микрофон и камера гостя выкл/вкл (видео снова идёт к владельцу) →
// положить трубку → запись в истории ссылки (API и «Мои ссылки») → удалить ссылку и пользователя (как del.mjs).
// Выход 0 — только если все шаги прошли. JSON-итог по шагам — в stdout (последней строкой), скриншоты — в $OUT_DIR.
// Все запросы к v2.chat-linia.site несут X-L2-CI (CONTRACTS.md, «Пропуск автотестов»).
// Локально можно подключиться к уже запущенному Chrome: CDP_URL=http://127.0.0.1:9778.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

let pw;
try { pw = await import('playwright'); } catch { pw = await import('playwright-core'); }
const { chromium } = pw.default || pw;

const BASE = (process.env.BASE || 'https://v2.chat-linia.site').replace(/\/$/, '');
const HOST = new URL(BASE).host;
const OUT = process.env.OUT_DIR || 'guest-call-shots';
const CI = process.env.CI_TOKEN || '';
const APIKEY = 'AQEAAAABAAD_rAp4DJh05a1HAwFT3A6K';
const RUN = String(process.env.RUN || (Date.now() % 1e8)).replace(/\D/g, '').slice(-8).padStart(6, '6');
const GUEST_NAME = 'Гость CI ' + RUN.slice(-3);
const LINK_TITLE = 'CI ссылка ' + RUN.slice(-4);
fs.mkdirSync(OUT, { recursive: true });
if (!CI) { console.log(JSON.stringify({ ok: false, error: 'нет CI_TOKEN' })); process.exit(2); }

const ciHeader = () => crypto.createHmac('sha256', CI).update('linia2-ci:' + new Date().toISOString().slice(0, 10).replace(/-/g, '')).digest('hex');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const steps = [];
const t0 = Date.now();
function step(name, ok, detail = '') {
  steps.push({ step: name, ok: !!ok, detail: String(detail).slice(0, 300), t: Math.round((Date.now() - t0) / 100) / 10 });
  console.error((ok ? 'OK   ' : 'FAIL ') + name + (detail ? ' — ' + String(detail).slice(0, 200) : ''));
  if (!ok) throw new Error('шаг не прошёл: ' + name);
}

// ---------------- API / Tinode ----------------
async function ciSetup() {
  const r = await fetch(BASE + '/invite/api/ci/setup', { method: 'POST', headers: { Authorization: 'Bearer ' + CI, 'Content-Type': 'application/json', 'X-L2-CI': ciHeader() }, body: JSON.stringify({ run: RUN }) });
  const j = await r.json(); if (!j.ok) throw new Error('ci/setup: ' + r.status + ' ' + JSON.stringify(j)); return j;
}
function tinode(login, pass, del) {
  return new Promise((res, rej) => {
    const ws = new WebSocket(BASE.replace(/^http/, 'ws') + '/v0/channels?apikey=' + APIKEY, { headers: { 'X-L2-CI': ciHeader() } });
    const send = o => ws.send(JSON.stringify(o));
    const timer = setTimeout(() => { try { ws.close(); } catch {} del ? res(false) : rej(new Error('таймаут Tinode')); }, 20000);
    ws.onopen = () => send({ hi: { id: '1', ver: '0.25' } });
    ws.onerror = () => { clearTimeout(timer); del ? res(false) : rej(new Error('ошибка WebSocket')); };
    ws.onmessage = ev => {
      const m = JSON.parse(ev.data);
      if (del && m.meta && m.meta.sub) for (const s of m.meta.sub) if (s.topic && s.topic !== 'me') send({ del: { id: 't' + s.topic, topic: s.topic, what: 'topic', hard: true } });
      if (!m.ctrl) return;
      if (m.ctrl.id === '1') send({ login: { id: '2', scheme: 'basic', secret: Buffer.from(login + ':' + pass).toString('base64') } });
      else if (m.ctrl.id === '2') {
        if (m.ctrl.code >= 300) { clearTimeout(timer); ws.close(); return del ? res(false) : rej(new Error('вход ' + m.ctrl.code)); }
        if (!del) { clearTimeout(timer); ws.close(); return res(m.ctrl.params); }
        send({ sub: { id: '4', topic: 'me', get: { what: 'sub' } } });
      } else if (m.ctrl.id === '4') setTimeout(() => send({ del: { id: '3', what: 'user', hard: true } }), 1500);
      else if (m.ctrl.id === '3') { clearTimeout(timer); ws.close(); res(m.ctrl.code < 300); }
    };
  });
}
async function api(token, method, p, body) {
  const r = await fetch(BASE + '/call/api' + p, { method, headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json', 'X-L2-CI': ciHeader() }, body: body ? JSON.stringify(body) : undefined });
  return r.json();
}

// ---------------- браузер ----------------
const PC_HOOK = `(function(){var N=window.RTCPeerConnection;if(!N||window.__pcs)return;window.__pcs=[];var P=function(c){var pc=new N(c);window.__pcs.push(pc);return pc};P.prototype=N.prototype;window.RTCPeerConnection=P;})();`;
const STATS = async kind => {
  const out = [];
  for (const pc of (window.__pcs || [])) {
    if (pc.connectionState === 'closed') continue;
    let b = 0; (await pc.getStats()).forEach(s => { if (s.type === 'inbound-rtp' && (!kind || s.kind === kind)) b += s.bytesReceived || 0; });
    out.push({ ice: pc.iceConnectionState, bytes: b });
  }
  return out;
};
const live = a => a.find(x => /connected|completed/.test(x.ice));
async function grows(page, kind, ms = 4000) {
  const a = live(await page.evaluate(STATS, kind)); await sleep(ms); const b = live(await page.evaluate(STATS, kind));
  return { ok: !!(a && b && b.bytes > a.bytes), a: a && a.bytes, b: b && b.bytes, ice: b && b.ice };
}
async function dismissNotifPrompt(page) {
  // Окно «Включить уведомления?» (веб предлагает push после входа) перекрывает интерфейс — отвечаем «Позже».
  if (page.addLocatorHandler) await page.addLocatorHandler(page.locator('.l2-modal:not(.l2g-modal)').filter({ hasText: 'Включить уведомления' }),
    async () => { await page.locator('.l2-modal:not(.l2g-modal) button').filter({ hasText: 'Позже' }).first().click().catch(() => {}); });
}
async function newContext(browser, opts) {
  const ctx = await browser.newContext({ locale: 'ru-RU', permissions: ['microphone', 'camera'], bypassCSP: true, ...opts }); // CSP сайта запрещает eval, нужный waitForFunction
  await ctx.route('**/*', route => {
    const u = new URL(route.request().url());
    if (u.host !== HOST) return route.continue();
    return route.continue({ headers: { ...route.request().headers(), 'x-l2-ci': ciHeader() } });
  });
  await ctx.addInitScript(PC_HOOK);
  return ctx;
}

async function main() {
  let browser, user, token, linkId, code = 1;
  const shot = async (page, name) => { try { await page.screenshot({ path: path.join(OUT, name + '.png') }); } catch {} };
  try {
    user = await ciSetup();
    step('владелец создан (ci/setup)', true, user.login);
    const params = await tinode(user.login, user.password);
    token = params.token;
    step('вход владельца в Tinode', !!token);

    const args = ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream', '--autoplay-policy=no-user-gesture-required',
      '--disable-background-timer-throttling', '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows',
      '--disable-features=IntensiveWakeUpThrottling,CalculateNativeWinOcclusion', '--force-webrtc-ip-handling-policy=default_public_interface_only'];
    browser = process.env.CDP_URL ? await chromium.connectOverCDP(process.env.CDP_URL) : await chromium.launch({ headless: true, args });
    const ownerCtx = await newContext(browser, { viewport: { width: 1280, height: 820 } });
    const guestCtx = await newContext(browser, { viewport: { width: 402, height: 874 }, isMobile: true, hasTouch: true, deviceScaleFactor: 2 });
    const owner = await ownerCtx.newPage(), guest = await guestCtx.newPage();
    await dismissNotifPrompt(owner);
    owner.on('dialog', d => d.accept().catch(() => {})); guest.on('dialog', d => d.accept().catch(() => {}));

    // 1. Веб владельца: вход по токену → «Звонки» → создать ссылку.
    await owner.goto(BASE + '/invite/');
    await owner.evaluate(([t, e]) => { localStorage.setItem('keep-logged-in', 'true'); localStorage.setItem('auth-token', JSON.stringify({ token: t, expires: e })); }, [token, params.expires]);
    await owner.goto(BASE + '/');
    await owner.locator('button[data-tab="calls"]').first().click({ timeout: 45000 });
    const lb = owner.locator('#l2-calls .l2-ptitle #l2g-linkbtn');
    await lb.waitFor({ timeout: 20000 });
    step('веб: кнопка 🔗 «Ссылка на звонок» в шапке «Звонков»', await lb.getAttribute('title') === 'Ссылка на звонок' && await lb.getAttribute('aria-label') === 'Ссылка на звонок');
    step('веб: в пустых «Звонках» — «Создать ссылку на звонок»', (await owner.locator('#l2g-emptylink').textContent({ timeout: 10000 })).trim() === 'Создать ссылку на звонок');
    await shot(owner, '00-owner-calls-empty');
    await lb.click();
    await owner.fill('#l2g-title', LINK_TITLE);
    await owner.click('.l2g-chip[data-v="video"]'); await owner.click('.l2g-chip[data-v="24h"]');
    await owner.click('#l2g-make');
    await owner.locator('#l2g-url').waitFor({ timeout: 20000 });
    const url = (await owner.locator('#l2g-url').inputValue()).trim();
    const hasQr = await owner.locator('.l2g-qr svg').count();
    await shot(owner, '01-owner-link');
    step('веб: ссылка создана (+QR, «Скопировать», «Поделиться»)', /\/call\/[A-Za-z0-9_-]{43}$/.test(url) && hasQr && await owner.locator('#l2g-copy').count() && await owner.locator('#l2g-share').count(), url.replace(/[A-Za-z0-9_-]{43}$/, '<token>'));
    const lj = await api(token, 'GET', '/links');
    const link = (lj.links || []).find(l => l.url === url); linkId = link && link.id;
    step('API: ссылка в «Мои ссылки»', link && link.state === 'active' && link.mode === 'video', linkId);
    await owner.click('#l2g-tab-links');
    await owner.locator(`.l2g-modal [data-link="${linkId}"]`).waitFor({ timeout: 15000 });
    step('веб: ссылка в списке «Мои ссылки»', true);
    await owner.click('.l2g-modal .l2g-x');

    // 2. Гость.
    await guest.goto(url + '?ci=' + ciHeader());
    await guest.locator('#s-prep').waitFor({ state: 'visible', timeout: 20000 });
    const invite = (await guest.locator('#p-title').textContent()) + ' — ' + (await guest.locator('#p-link').textContent());
    step('гость: «Вас приглашает <имя> — <название>»', invite.startsWith('Вас приглашает ') && invite.includes(LINK_TITLE), invite);
    await guest.click('#p-check');
    await guest.waitForFunction(() => /работают|работает/.test(document.getElementById('p-devstate').textContent), null, { timeout: 15000 });
    step('гость: проверка микрофона и камеры', await guest.locator('#p-preview.live').count() === 1, await guest.locator('#p-devstate').textContent());
    await guest.fill('#p-name', GUEST_NAME);
    await shot(guest, '02-guest-prep');
    await guest.click('#p-call');
    await guest.waitForFunction(() => /Ждём организатора/.test(document.getElementById('w-title').textContent), null, { timeout: 15000 });
    await sleep(500);
    step('гость: «Ждём организатора…» + гудки', await guest.evaluate(() => window.__gcRingback && window.__gcRingback()));
    await shot(guest, '03-guest-wait');

    // 3. Входящий у владельца → «Принять».
    const inc = owner.locator('.incoming-call .l2g-caller');
    await inc.waitFor({ timeout: 25000 });
    const incText = (await inc.textContent()).trim();
    await shot(owner, '04-owner-incoming');
    step('веб: входящий «<имя> звонит по ссылке «<название>»»', incText === GUEST_NAME + ' звонит по ссылке «' + LINK_TITLE + '»', incText);
    step('веб: кнопки «Принять»/«Отклонить»', await owner.locator('.incoming-call button.positive').count() === 1 && await owner.locator('.incoming-call button.danger').count() === 1);
    await owner.click('.incoming-call button.positive');

    // 4. Медиа.
    await guest.waitForFunction(() => window.__gc && window.__gc.pc && /connected|completed/.test(window.__gc.pc.iceConnectionState), null, { timeout: 30000 });
    await owner.waitForFunction(() => (window.__pcs || []).some(p => /connected|completed/.test(p.iceConnectionState)), null, { timeout: 20000 });
    const g = await grows(guest), o = await grows(owner);
    await shot(guest, '05-guest-call'); await shot(owner, '06-owner-call');
    step('ICE connected + растёт bytesReceived у гостя', g.ok, JSON.stringify(g));
    step('ICE connected + растёт bytesReceived у владельца', o.ok, JSON.stringify(o));
    step('гость: экран звонка (имя, таймер, кнопки)', await guest.evaluate(() => !document.getElementById('s-call').hidden && /^\d\d:\d\d$/.test(document.getElementById('c-timer').textContent) &&
      ['c-mic', 'c-cam', 'c-flip', 'c-spk', 'c-hang'].every(id => document.getElementById(id))), await guest.locator('#c-timer').textContent());

    // 5. Микрофон и камера выкл/вкл.
    await guest.click('#c-mic');
    step('гость: микрофон выключен', await guest.evaluate(() => window.__gc.stream.getAudioTracks()[0].enabled === false));
    await guest.click('#c-mic');
    step('гость: микрофон включён', await guest.evaluate(() => window.__gc.stream.getAudioTracks()[0].enabled === true));
    await guest.click('#c-cam');
    await sleep(1500);
    const offv = await grows(owner, 'video', 2500);
    step('гость: камера выключена (видео к владельцу не идёт)', await guest.evaluate(() => !window.__gc.stream.getVideoTracks().length) && !offv.ok, JSON.stringify(offv));
    await guest.click('#c-cam');
    await guest.waitForFunction(() => window.__gc.stream.getVideoTracks().some(t => t.readyState === 'live'), null, { timeout: 10000 });
    await sleep(1500);
    const onv = await grows(owner, 'video', 3000);
    step('гость: камера включена (видео к владельцу снова идёт)', onv.ok, JSON.stringify(onv));
    await shot(owner, '07-owner-call-video');

    // 6. Положить трубку → история.
    await guest.click('#c-hang');
    await guest.locator('#s-end').waitFor({ state: 'visible', timeout: 10000 });
    step('гость: «Звонок завершён»', true, await guest.locator('#e-text').textContent());
    await sleep(3000);
    const after = await api(token, 'GET', '/links/' + linkId);
    const h = ((after.link || {}).history || [])[0];
    step('API: звонок в истории ссылки (принят, длительность > 0)', h && h.result === 'accepted' && h.duration > 0 && h.name === GUEST_NAME, JSON.stringify(h));
    await owner.locator('.incoming-call').waitFor({ state: 'detached', timeout: 10000 }).catch(() => {});
    await owner.locator('button[data-tab="calls"]').first().click().catch(() => {});
    await owner.locator('#l2g-linkbtn').click({ timeout: 15000 });
    await owner.click('#l2g-tab-links');
    await owner.locator(`.l2g-modal [data-link="${linkId}"]`).click({ timeout: 15000 });
    const hist = await owner.locator('.l2g-hist').textContent({ timeout: 10000 });
    await shot(owner, '08-owner-history');
    step('веб: история ссылки в «Мои ссылки»', hist.includes(GUEST_NAME) && hist.includes('принят'), hist);
    await owner.click('.l2g-modal .l2g-x');
    const row = await owner.locator('#l2-calls li.l2g-call').first().textContent({ timeout: 15000 }).catch(() => '');
    await shot(owner, '09-owner-calls');
    step('веб: гостевой звонок в истории «Звонки» (имя + значок ссылки)', row.includes(GUEST_NAME), row);
    code = 0;
  } catch (e) {
    if (!steps.length || steps[steps.length - 1].ok) steps.push({ step: 'ошибка', ok: false, detail: String(e.message || e).slice(0, 300) });
    console.error('ОШИБКА:', e.message || e);
  } finally {
    if (linkId && token) { const d = await api(token, 'DELETE', '/links/' + linkId).catch(() => ({})); steps.push({ step: 'уборка: ссылка удалена', ok: !!d.ok }); }
    if (browser) await browser.close().catch(() => {});
    if (user) { const ok = await tinode(user.login, user.password, true).catch(() => false); steps.push({ step: 'уборка: пользователь удалён', ok }); if (!ok) code = code || 1; }
  }
  const ok = code === 0 && steps.every(s => s.ok);
  fs.writeFileSync(path.join(OUT, 'result.json'), JSON.stringify({ ok, steps }, null, 1));
  console.log(JSON.stringify({ test: 'guest-call', ok, passed: steps.filter(s => s.ok).length, failed: steps.filter(s => !s.ok).length, steps }));
  return ok ? 0 : 1;
}
main().then(c => process.exit(c), e => { console.log(JSON.stringify({ test: 'guest-call', ok: false, error: String(e) })); process.exit(2); });
