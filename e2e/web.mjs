// Роль «web» e2e-теста: веб-клиент «Линия 2.0» в Chromium (Playwright) с поддельными камерой/микрофоном.
// Сценарии и их порядок совпадают с TinodiosUITests/Linia2E2ETests.swift; синхронизация — через доску (board.mjs).
import { chromium } from 'playwright';
import fs from 'node:fs';
import path from 'node:path';
import { loginCode } from './tinode.mjs';

const E = process.env;
const ROLE = 'web';
const BOARD = `http://127.0.0.1:${E.L2_BOARD_PORT || 8765}`;
const BASE = `https://${E.L2_HOST || 'v2.chat-linia.site'}/`;
const RUN = E.L2_RUN || String(Date.now() % 100000);
const OUT = E.L2_WEB_OUT || 'web-out';
const P1_NAME = 'Айфон1 CI', W_NAME = 'Веб CI';
const ALL = ['iphone1', 'iphone2', 'web'];
fs.mkdirSync(path.join(OUT, 'shots'), { recursive: true });

class Fail extends Error {}
class Skip extends Error {}
const sleep = ms => new Promise(r => setTimeout(r, ms));
let shotN = 0, failedAny = false;
const failed = [];

async function bcall(p, q = {}, timeout = 60) {
  const u = new URL(BOARD + p);
  for (const [k, v] of Object.entries(q)) u.searchParams.set(k, String(v));
  try {
    const r = await fetch(u, { signal: AbortSignal.timeout((timeout + 15) * 1000) });
    let j = {}; try { j = await r.json(); } catch {}
    return [r.status, j];
  } catch (e) { return [0, { error: e.message }]; }
}
const blog = m => bcall('/log', { role: ROLE, m });

function ctx(s, a) {
  const tag = `${s}-${a}-${RUN}`;
  const key = (n, r) => `${s}#${a}:${n}@${r}`;
  return {
    s, a, tag,
    sig: (n, v = '1') => bcall('/set', { k: key(n, ROLE), v }),
    wait: async (n, from, t = 120) => {
      const [c, j] = await bcall('/wait', { k: key(n, from), t }, t);
      if (c === 200) return [String(j.v ?? ''), j.ts || 0];
      if (c === 409) throw new Fail(`попытка прервана: у другого участника шаг не прошёл (ждали «${n}» от ${from})`);
      if (c === 410) throw new Fail(`${from} уже завершил работу (ждали «${n}»)`);
      throw new Fail(`не дождались «${n}» от ${from} за ${t} с`);
    },
  };
}

let page, context, browser;

async function shot(name) {
  shotN++;
  const file = `web-${String(shotN).padStart(3, '0')}-${name}`;
  try { await page.screenshot({ path: path.join(OUT, 'shots', file + '.png') }); } catch { return; }
  // Проверки аккуратности: текст не обрезан краем окна, нет латинских слов, фон тёмный по краям.
  const checks = await page.evaluate(allowed => {
    const out = [], W = innerWidth, H = innerHeight, cut = [], latin = new Set();
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n; (n = walker.nextNode());) {
      const t = n.textContent.trim(); if (!t) continue;
      const el = n.parentElement; if (!el) continue;
      const cs = getComputedStyle(el); if (cs.visibility === 'hidden' || cs.display === 'none' || el.closest('[hidden],script,style,noscript')) continue;
      const r = el.getBoundingClientRect(); if (r.width < 1 || r.height < 1 || r.bottom < 0 || r.top > H || r.right < 0 || r.left > W) continue;
      if ((r.left < -1 || r.right > W + 1) && cs.overflow !== 'hidden') cut.push(t.slice(0, 30));
      if (el.closest('#scroller, .l2-quote, input, textarea')) continue;   // сообщения — пользовательский текст
      for (const w of t.split(/[^A-Za-z\u0400-\u04FF0-9]+/)) if (/^[A-Za-z]{2,}$/.test(w) && !allowed.some(a => a === w || a.includes(w))) latin.add(w);
    }
    out.push(cut.length ? 'cut=fail:' + cut.slice(0, 3).join(', ') : 'cut=ok');
    out.push(latin.size ? 'ru=fail:' + [...latin].slice(0, 5).join(' ') : 'ru=ok');
    return out.join(';');
  }, ['PIN', 'ID', 'iPhone', 'iOS', 'OK', 'CI', 'Email', 'Telegram', 'e2e', 'file', 'txt', E.L2_W_LOGIN || '', E.L2_P2_LOGIN || '', E.L2_P1_LOGIN || '', E.L2_INV_LOGIN || '']).catch(() => 'checks=fail:страница недоступна');
  await bcall('/screen', { role: ROLE, name, file, checks });
}

async function scenario(s, title, roles, body, timeout = 240) {
  if (!roles.includes(ROLE)) return;
  const r = roles.join(',');
  for (let a = 1; a <= 3; a++) {
    await bcall('/barrier', { n: `${s}#${a}`, role: ROLE, roles: r, t: 1500 }, 1500);
    await bcall('/start', { s, a, title, roles: r, role: ROLE });
    let ok = 'true', note = '', metric = '';
    try { metric = (await body(ctx(s, a))) || ''; }
    catch (e) {
      if (e instanceof Skip) { ok = 'skip'; note = e.message; }
      else { ok = 'false'; note = e.message || String(e); }
    }
    await shot(`${s}-a${a}-${ok === 'false' ? 'ПАДЕНИЕ' : 'итог'}`);
    if (ok === 'false') {
      try { fs.writeFileSync(path.join(OUT, `ПАДЕНИЕ-${s}-a${a}.txt`), note + '\n\n' + (await page.evaluate(() => document.body.innerText)).slice(0, 20000)); } catch {}
    }
    await bcall('/part', { s, a, title, roles: r, role: ROLE, ok, note: note.slice(0, 400), metric });
    const [, v] = await bcall('/verdict', { s, a, roles: r, t: timeout }, timeout);
    if (v.final !== false) { if (v.status === 'fail') { failed.push(s); failedAny = true; } return v.status; }
    await blog(`${s}: повтор (попытка ${a + 1})`);
    await recover();
  }
}
const solo = (s, title, body) => scenario(s, title, [ROLE], body, 30);

// ---------- Помощники страницы ----------
const INIT = () => {
  // Все RTCPeerConnection — в window.__pcs (для getStats).
  const N = window.RTCPeerConnection;
  if (N && !window.__pcs) {
    window.__pcs = [];
    const W = function (...a) { const pc = new N(...a); window.__pcs.push(pc); return pc; };
    W.prototype = N.prototype; Object.setPrototypeOf(W, N);
    window.RTCPeerConnection = W;
  }
  window.__l2 = {
    root() {
      const n = document.getElementById('app-container'); if (!n) return null;
      let f = null; for (const k in n) if (k.startsWith('__reactFiber$')) f = n[k];
      for (let d = 0; f && d < 80; d++, f = f.return) if (f.stateNode && f.stateNode.tinode && f.stateNode.handleStartAudioCall) return f.stateNode;
      return null;
    },
    tn() { const r = this.root(); return r && r.tinode; },
    topicByName(fn) {
      const t = this.tn(); if (!t) return null; let found = null;
      try { t.getMeTopic().contacts(c => { if (!found && c.public && c.public.fn && c.public.fn.includes(fn)) found = c.topic || c.name; }); } catch (e) {}
      return found;
    },
    text() { const s = document.getElementById('scroller'); return (s || document.body).textContent || ''; },
    findSeq(topic, text) {
      const t = this.tn(); const tp = t && t.getTopic(topic); let seq = 0;
      try { tp.messages(m => { const c = typeof m.content === 'string' ? m.content : (m.content && m.content.txt) || ''; if (c.includes(text)) seq = m.seq; }); } catch (e) {}
      return seq;
    },
    readCount(topic, seq) { const t = this.tn(); const tp = t && t.getTopic(topic); try { return tp.msgReadCount(seq); } catch (e) { return -1; } },
    async rtc() {
      const pcs = window.__pcs || []; const pc = pcs[pcs.length - 1]; if (!pc) return { n: 0 };
      const st = await pc.getStats(); let pair = 0, rtp = 0, sel = '';
      st.forEach(r => {
        if (r.type === 'candidate-pair' && (r.nominated || r.selected) && r.state === 'succeeded') { pair = Math.max(pair, r.bytesReceived || 0); sel = r.localCandidateId; }
        if (r.type === 'inbound-rtp') rtp += r.bytesReceived || 0;
      });
      let kind = ''; st.forEach(r => { if (r.id === sel) kind = r.candidateType; });
      return { n: pcs.length, ice: pc.iceConnectionState, conn: pc.connectionState, pair, rtp, kind };
    },
  };
};

async function rootReady(ms = 30000) {
  await page.waitForFunction(() => { const t = window.__l2.tn(); return t && t.isAuthenticated && t.isAuthenticated(); }, null, { timeout: ms });
}

async function webLogin(login, pw) {
  await page.goto(BASE, { waitUntil: 'domcontentloaded' });
  const authed = await page.waitForFunction(() => { const t = window.__l2 && window.__l2.tn(); return !!(t && t.isAuthenticated && t.isAuthenticated()); }, null, { timeout: 6000 }).then(() => true).catch(() => false);
  if (authed) return;
  // «Добро пожаловать» → «Войти» → логин/пароль.
  const enter = page.locator('button:has-text("Войти")').first();
  await enter.waitFor({ timeout: 30000 });
  await enter.click();
  const lf = page.locator('input[autocomplete="username"]').first();
  await lf.waitFor({ timeout: 15000 });
  await lf.fill(login);
  await page.locator('input[type="password"]').first().fill(pw);
  await shot('login-filled');
  await page.locator('button.btn.primary:has-text("Войти")').first().click();
  await rootReady(40000);
}

async function openTopic(name) {
  if (!name) throw new Fail('не найден чат');
  await page.evaluate(n => { if (window.__l2.root().state.topicSelected !== n) location.hash = '#/' + n; }, name);
  await page.waitForFunction(n => { const r = window.__l2.root(); return r && r.state.topicSelected === n; }, name, { timeout: 15000 })
    .catch(() => { throw new Fail('не открылся чат ' + name); });
  await page.locator('#send-message-input').waitFor({ timeout: 15000 }).catch(() => {});
  const acc = page.locator('#topic-view button:has-text("Принять"), .accept-invite-panel button:has-text("Принять")').first();
  if (await acc.isVisible().catch(() => false)) { await acc.click(); await sleep(1000); }
  await sleep(800);
}

async function topicOf(fn, ms = 90000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const t = await page.evaluate(f => window.__l2.topicByName(f), fn).catch(() => null);
    if (t) return t;
    await sleep(500);
  }
  throw new Fail(`в списке чатов нет «${fn}»`);
}
const p1Topic = () => topicOf(P1_NAME);
const p2Topic = async () => E.L2_P2_UID || topicOf('Айфон2');

async function waitText(text, ms = 30000) {
  const h = await page.waitForFunction(t => window.__l2.text().includes(t) ? Date.now() : 0, text, { timeout: ms, polling: 25 })
    .catch(() => { throw new Fail(`не пришло «${text}» за ${ms / 1000} с`); });
  return await h.jsonValue();
}

async function sendText(text) {
  const inp = page.locator('#send-message-input');
  await inp.click();
  await inp.fill(text);
  const t0 = Date.now();
  await inp.press('Enter');
  return t0;
}

const metric = (t0, t1) => { const ms = Math.round(t1 - t0); return `доставка ${ms} мс (цель < 1000 мс: ${ms < 1000 ? 'да' : 'нет'})`; };

async function startCall() {
  await page.evaluate(() => window.__l2.root().handleStartAudioCall());
  await page.waitForFunction(() => window.__l2.root().state.callState > 0, null, { timeout: 15000 }).catch(() => { throw new Fail('звонок не начался'); });
  await sleep(500);
}
async function hangUp() {
  const b = page.locator('#controls button.danger').first();
  if (await b.isVisible().catch(() => false)) await b.click();
  else await page.evaluate(() => { const r = window.__l2.root(); r.handleCallHangup && r.handleCallHangup(r.state.callTopic, r.state.callSeq); });
  await page.waitForFunction(() => window.__l2.root().state.callState === 0, null, { timeout: 20000 }).catch(() => {});
}
async function waitConnected(ms = 40000) {
  const end = Date.now() + ms; let a = null;
  while (Date.now() < end) {
    a = await page.evaluate(() => window.__l2.rtc());
    if (a.ice === 'connected' || a.ice === 'completed') break;
    await sleep(500);
  }
  if (!a || !(a.ice === 'connected' || a.ice === 'completed')) throw new Fail(`ICE не соединился: ${JSON.stringify(a)}`);
  await sleep(3000);
  const b = await page.evaluate(() => window.__l2.rtc());
  if (!(b.pair > a.pair)) throw new Fail(`bytesReceived не растёт: ${a.pair} → ${b.pair}`);
  return `ICE ${b.ice} (${b.kind || '?'}), bytesReceived ${a.pair}→${b.pair}, RTP-аудио ${a.rtp}→${b.rtp}${b.rtp > a.rtp ? '' : ' (звук из симулятора не идёт — нет микрофона)'}`;
}

async function recover() {
  try {
    if (await page.evaluate(() => window.__l2.root() && window.__l2.root().state.callState > 0)) await hangUp();
    await context.setOffline(false);
    await page.locator('#send-message-input').fill('').catch(() => {});
  } catch {
    try { await page.reload(); await rootReady(); } catch {}
  }
}

// ---------- Пьеса ----------
async function play() {
  browser = await chromium.launch({
    headless: true,
    args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream', '--autoplay-policy=no-user-gesture-required'],
  });
  context = await browser.newContext({
    viewport: { width: 1280, height: 860 }, locale: 'ru-RU',
    permissions: ['microphone', 'camera', 'notifications'],
    recordVideo: { dir: path.join(OUT, 'video'), size: { width: 1280, height: 860 } },
  });
  await context.addInitScript(INIT);
  await context.tracing.start({ screenshots: true, snapshots: false }).catch(() => {});
  page = await context.newPage();
  page.on('console', m => { if (m.type() === 'error') fs.appendFileSync(path.join(OUT, 'console.log'), m.text() + '\n'); });

  // Регистрация по ссылке-приглашению (отдельный пользователь, свои вкладки браузера).
  const invUrl = BASE + 'invite/' + (E.L2_INV_CODE || '');
  await solo('W01', 'Страница приглашения на телефоне: «Скопировать код», «Продолжить в браузере»', async () => {
    if (!E.L2_INV_CODE) throw new Fail('нет кода приглашения');
    const m = await browser.newContext({ viewport: { width: 402, height: 874 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true, locale: 'ru-RU',
      userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1' });
    const mp = await m.newPage();
    try {
      await mp.goto(invUrl, { waitUntil: 'networkidle' });
      await sleep(1500);
      await mp.screenshot({ path: path.join(OUT, 'shots', 'web-invite-mobile.png'), fullPage: true });
      const txt = await mp.evaluate(() => document.body.innerText);
      const miss = ['Скопировать код', 'Продолжить в браузере'].filter(t => !txt.includes(t));
      if (miss.length) throw new Fail('на мобильной странице приглашения нет: ' + miss.map(t => `«${t}»`).join(', '));
    } finally { await m.close(); }
  });
  await solo('W02', 'Регистрация по ссылке-приглашению в вебе', async () => {
    if (!E.L2_INV_CODE) throw new Fail('нет кода приглашения');
    const ic = await browser.newContext({ viewport: { width: 1280, height: 860 }, locale: 'ru-RU' });
    const ip = await ic.newPage();
    const ishot = n => ip.screenshot({ path: path.join(OUT, 'shots', `web-invite-${n}.png`) }).catch(() => {});
    try {
      await ip.goto(invUrl, { waitUntil: 'networkidle' });
      await sleep(1500);
      await ishot('1-open');
      const info = await ip.evaluate(code => {
        const t = document.body.innerText, html = document.documentElement.outerHTML;
        const bg = getComputedStyle(document.body).backgroundColor.match(/\d+/g).map(Number);
        const vals = [...document.querySelectorAll('input')].map(i => i.value).join('');
        return { tinode: /tinode/i.test(t) || /tinode/i.test(document.title), oldUi: !!document.querySelector('#login-form, #sidepanel, .tinode-logo'),
          logo: /Линия 2\.0/.test(t) || !!document.querySelector('img[alt*="Линия"], .logo, .l2-logo, svg'), dark: bg.length >= 3 && (bg[0] + bg[1] + bg[2]) / 3 < 80,
          code: vals.replace(/\D/g, '').includes(code) || t.replace(/\D/g, '').includes(code) };
      }, E.L2_INV_CODE);
      const bad = [];
      if (info.tinode) bad.push('есть слово «Tinode»');
      if (info.oldUi) bad.push('элементы старого интерфейса Tinode');
      if (!info.logo) bad.push('нет логотипа «Линия 2.0»');
      if (!info.dark) bad.push('фон не тёмный');
      if (!info.code) bad.push('код не подставлен');
      if (bad.length) throw new Fail('страница приглашения: ' + bad.join(', '));
      await ip.locator('button:has-text("Продолжить"), a:has-text("Продолжить"), input[type=submit][value*="Продолжить"]').first().click();
      await sleep(1500);
      await ishot('2-form');
      const texts = ip.locator('input:visible:not([type=password]):not([type=hidden]):not([type=checkbox])');
      const n = await texts.count();
      const vals = ['Приглашённый CI', E.L2_INV_LOGIN];
      let k = 0;
      for (let i = 0; i < n && k < 2; i++) { const el = texts.nth(i); if ((await el.inputValue()).replace(/\D/g, '') === E.L2_INV_CODE) continue; await el.fill(vals[k++]); }
      const pws = ip.locator('input[type=password]:visible');
      for (let i = 0; i < await pws.count(); i++) await pws.nth(i).fill(E.L2_INV_PASSWORD);
      const terms = ip.locator('input[type=checkbox]:visible');
      for (let i = 0; i < await terms.count(); i++) if (!(await terms.nth(i).isChecked())) await terms.nth(i).check().catch(() => {});
      await ishot('3-filled');
      await ip.locator('button:visible:has-text("Зарегистр"), button:visible:has-text("Создать"), button:visible:has-text("Продолжить"), button[type=submit]:visible').first().click();
      // Вход в веб-версию: видна вкладка «Чаты» (возможно, после «Войти» с теми же данными).
      const chats = ip.locator('text=Чаты').first();
      if (!(await chats.isVisible({ timeout: 20000 }).catch(() => false))) {
        const go = ip.locator('a:has-text("Перейти"), a:has-text("Войти"), button:has-text("Войти")').first();
        if (await go.isVisible().catch(() => false)) {
          await go.click(); await sleep(2000);
          const lf = ip.locator('input[autocomplete="username"]').first();
          if (await lf.isVisible().catch(() => false)) {
            await lf.fill(E.L2_INV_LOGIN); await ip.locator('input[type=password]').first().fill(E.L2_INV_PASSWORD);
            await ip.locator('button.btn.primary:has-text("Войти")').first().click();
          }
        }
        await chats.waitFor({ timeout: 40000 }).catch(() => { throw new Fail('после регистрации не видна вкладка «Чаты»'); });
      }
      await ishot('4-chats');
      const code = await loginCode(E.L2_INV_LOGIN, E.L2_INV_PASSWORD);
      if (code !== 200) throw new Fail('новый аккаунт не входит (код ' + code + ')');
    } finally { await ic.close(); }
  });

  await solo('R05', 'Вход (веб)', async () => {
    await webLogin(E.L2_W_LOGIN, E.L2_W_PASSWORD);
    await shot('logged-in');
  });

  // ---------- Веб-аналоги iOS-сценариев (тот же список, колонка «Веб» в отчёте) ----------
  const tabBtn = id => page.locator(`#l2-tabs button[data-tab="${id}"]`).first();
  const srow = t => page.locator('#l2-settings button.l2-srow').filter({ has: page.locator(`.t:text-is("${t}")`) }).first();
  const openTab = async id => { await tabBtn(id).click(); await sleep(800); };
  const settingsRoot = async () => { await openTab('settings'); for (let i = 0; i < 3 && await page.locator('#l2-settings .l2-back').first().isVisible().catch(() => false); i++) { await page.locator('#l2-settings .l2-back').first().click(); await sleep(500); } };
  const modalBtn = t => page.locator('.l2-modal button').filter({ hasText: t }).first();

  await solo('WP01', 'Push через FCM (веб)', async () => {
    const [, j] = await bcall('/push-check', { login: E.L2_W_LOGIN }, 40);
    if (j.http === 404) throw new Skip('пропущен: нет endpoint /invite/api/ci/push-check на сервере');
    if (j.http !== 200) throw new Fail(`push-check: HTTP ${j.http} ${j.error || ''}`);
    if (!(j.tokens >= 1)) throw new Skip('пропущен: в headless Chromium нет push-сервиса браузера — веб-токен FCM не регистрируется');
    if (j.ok !== j.tokens) throw new Fail(`Firebase принял ${j.ok} из ${j.tokens}: ${(j.errors || []).join('; ')}`);
    return `токенов ${j.tokens}, принято ${j.ok}`;
  });
  await solo('WT01', 'Вкладки: Чаты, Звонки, Контакты, Настройки (веб)', async () => {
    for (const [id, sel] of [['calls', '#l2-calls'], ['contacts', '#l2-contacts'], ['settings', '#l2-settings'], ['chats', '#sidepanel']]) {
      await tabBtn(id).waitFor({ timeout: 10000 }).catch(() => { throw new Fail('нет вкладки ' + id); });
      await openTab(id);
      if (!(await page.locator(sel).first().isVisible().catch(() => false))) throw new Fail('не открылась вкладка ' + id);
      await shot('tab-' + id);
    }
  });
  await solo('WS01', 'Настройки: каждый пункт открывается (веб)', async () => {
    for (const item of ['Уведомления', 'Конфиденциальность', 'Внешний вид', 'О приложении', 'Поддержка']) {
      await settingsRoot();
      const r = srow(item);
      if (!(await r.isVisible().catch(() => false))) throw new Fail(`нет пункта «${item}»`);
      await r.click(); await sleep(1200);
      await shot('settings-' + item);
    }
    await settingsRoot();
    await page.locator('#l2-settings button.l2-profile').first().click(); await sleep(1200);
    await shot('profile');
    await settingsRoot();
  });
  await solo('WN01', 'Настройки: имя (веб)', async () => {
    await settingsRoot();
    await page.locator('#l2-settings button.l2-profile').first().click(); await sleep(1500);
    // Профиль Tinode: имя — редактирование по месту (клик по имени → поле → Enter).
    const nameEl = page.locator(`text="${W_NAME}"`).last();
    if (!(await nameEl.isVisible().catch(() => false))) throw new Fail('в профиле не найдено имя');
    await nameEl.click(); await sleep(500);
    const inp = page.locator('input:focus').first();
    if (!(await inp.isVisible().catch(() => false))) throw new Fail('имя не редактируется');
    await inp.fill(W_NAME + ' ✓'); await inp.press('Enter'); await sleep(1500);
    const fn = await page.evaluate(() => window.__l2.tn().getMeTopic().public.fn);
    // Вернуть исходное (по нему iPhone находят чат).
    await page.evaluate(n => window.__l2.tn().getMeTopic().setMeta({ desc: { public: { fn: n } } }), W_NAME);
    await settingsRoot();
    if (fn !== W_NAME + ' ✓') throw new Fail(`имя не сохранилось на сервере: «${fn}»`);
  });
  await solo('WN02', 'Настройки: аватар (веб)', async () => {
    await settingsRoot();
    await page.locator('#l2-settings button.l2-profile').first().click(); await sleep(1500);
    const fi = page.locator('input[type=file][accept*="image"]').first();
    if (!(await fi.count())) throw new Fail('нет выбора фото в профиле');
    await fi.setInputFiles(E.L2_AVATAR || 'ios-chat.png');
    await sleep(1500);
    await shot('avatar-crop');
    const ok = page.locator('button:has(i:text("check")), button:has-text("Готово"), button:has-text("Сохранить"), a:has(i:text("check"))').last();
    if (await ok.isVisible().catch(() => false)) await ok.click();
    const done = await page.waitForFunction(() => { const p = window.__l2.tn().getMeTopic().public; return !!(p && p.photo); }, null, { timeout: 30000 }).then(() => true).catch(() => false);
    await settingsRoot();
    if (!done) throw new Fail('фото профиля не сохранилось');
  });
  const appearanceOpen = async () => { await settingsRoot(); await srow('Внешний вид').click(); await sleep(800); };
  await solo('WN03', 'Настройки: тема (светлая → тёмная, веб)', async () => {
    await appearanceOpen();
    const b = n => page.locator('#l2-settings .l2-seg button').filter({ hasText: n }).first();
    await b('Светлая').click(); await sleep(800);
    if ((await b('Светлая').getAttribute('aria-pressed')) !== 'true') throw new Fail('светлая тема не выбралась');
    await shot('theme-light');
    await b('Тёмная').click(); await sleep(800);
    if ((await b('Тёмная').getAttribute('aria-pressed')) !== 'true') throw new Fail('тёмная тема не вернулась');
  });
  await solo('WN04', 'Настройки: цвет акцента (веб)', async () => {
    await appearanceOpen();
    const b = n => page.locator(`#l2-settings .l2-accents button[title="${n}"]`).first();
    await b('Фиолетовый').click(); await sleep(800);
    if ((await b('Фиолетовый').getAttribute('aria-pressed')) !== 'true') throw new Fail('цвет не выбрался');
    await shot('accent-violet');
    await b('Мятный').click(); await sleep(800);
    if ((await b('Мятный').getAttribute('aria-pressed')) !== 'true') throw new Fail('мятный не вернулся');
  });
  await solo('WN05', 'Настройки: уведомления (веб)', async () => {
    await settingsRoot();
    await srow('Уведомления').click(); await sleep(1500);
    const cb = page.locator('input[type=checkbox]:visible, .switch:visible, [role=switch]:visible').first();
    if (!(await cb.isVisible().catch(() => false))) throw new Fail('нет переключателей в «Уведомлениях»');
    await shot('notifications');
    await settingsRoot();
  });
  await solo('WN06', 'Настройки: конфиденциальность (веб)', async () => {
    await settingsRoot();
    await srow('Конфиденциальность').click(); await sleep(800);
    for (const t of ['Заблокированные пользователи', 'Пароль и безопасность']) {
      const r = srow(t);
      if (!(await r.isVisible().catch(() => false))) throw new Fail(`нет «${t}»`);
    }
    await srow('Пароль и безопасность').click(); await sleep(1500);
    await shot('security');
    await settingsRoot();
  });
  await solo('WN07', 'Настройки: смена пароля (веб)', async () => { throw new Skip('пропущен: веб-сценарий смены пароля ещё не написан'); });
  await solo('WN08', 'Настройки: смена PIN (веб)', async () => { throw new Skip('пропущен: в веб-версии нет PIN-кода (только iOS)'); });
  await solo('WO01', 'Контакты: найти по логину, открыть чат (веб)', async () => {
    await openTab('contacts');
    const inp = page.locator('#l2-contacts input[type=search]').first();
    await inp.fill(E.L2_P2_LOGIN); await page.locator('#l2-contacts button:has-text("Найти")').first().click();
    const f = page.locator('#l2-contacts .l2-found li, #l2-contacts .l2-found button').first();
    await f.waitFor({ timeout: 20000 }).catch(() => { throw new Fail('поиск по логину ничего не нашёл'); });
    await shot('contacts-found');
    await openTab('chats');
  });
  await solo('WR02', 'Выход → вход по логину и паролю (веб)', async () => {
    await settingsRoot();
    await srow('Выйти').click();
    await modalBtn('Выйти').click().catch(() => { throw new Fail('нет подтверждения выхода'); });
    await page.locator('button:has-text("Войти")').first().waitFor({ timeout: 20000 }).catch(() => { throw new Fail('после выхода нет экрана входа'); });
    await shot('logged-out');
    await webLogin(E.L2_W_LOGIN, E.L2_W_PASSWORD);
  });
  await solo('WR03', 'Повторное открытие → вход по сохранённой сессии (веб)', async () => {
    await page.reload({ waitUntil: 'domcontentloaded' });
    await rootReady(40000).catch(() => { throw new Fail('после перезагрузки страницы сессия не восстановилась'); });
    await shot('relogin');
  });

  await bcall('/barrier', { n: 'chats', role: ROLE, roles: ALL.join(','), t: 1500 }, 1500);

  const IW = ['iphone1', 'web'], I2W = ['iphone2', 'web'];

  await scenario('C02', 'Новый чат iPhone 1 → веб', IW, async c => {
    const [v] = await c.wait('sent', 'iphone1', 180);
    const t = await p1Topic();
    await openTopic(t);
    const t1 = await waitText(`Привет, веб! ${c.tag}`, 30000);
    await c.sig('seen');
    return `чат открыт, сообщение через ${Math.round(t1 - +v)} мс после отправки (включая поиск чата)`;
  });

  // Доставка iPhone 1 → веб, веб → iPhone 1.
  await scenario('D03', 'Доставка iPhone 1 → веб', IW, async c => {
    await openTopic(await p1Topic());
    await c.sig('ready');
    const t1 = await waitText(`Доставка ${c.tag}`, 60000);
    const [v] = await c.wait('sent', 'iphone1', 10);
    await c.sig('seen');
    return metric(+v, t1);
  });
  await scenario('D04', 'Доставка веб → iPhone 1', IW, async c => {
    await openTopic(await p1Topic());
    await c.wait('ready', 'iphone1');
    const t0 = await sendText(`Доставка ${c.tag}`);
    await c.sig('sent', String(t0));
    await c.wait('seen', 'iphone1', 60);
  });
  await scenario('D05', 'Доставка iPhone 2 → веб', I2W, async c => {
    await openTopic(await p2Topic());
    await c.sig('ready');
    const t1 = await waitText(`Доставка ${c.tag}`, 60000);
    const [v] = await c.wait('sent', 'iphone2', 10);
    await c.sig('seen');
    return metric(+v, t1);
  });
  await scenario('D06', 'Доставка веб → iPhone 2', I2W, async c => {
    await openTopic(await p2Topic());
    await c.wait('ready', 'iphone2');
    const t0 = await sendText(`Доставка ${c.tag}`);
    await c.sig('sent', String(t0));
    await c.wait('seen', 'iphone2', 60);
  });

  await scenario('M06', 'Переслать из чата с iPhone 2 в чат с вебом', IW, async c => {
    await openTopic(await p1Topic());
    await c.wait('sent', 'iphone1', 180);
    await waitText(`Переслать ${c.tag}`, 30000);
    await c.sig('seen');
  });
  await scenario('M07', 'Фото iPhone 1 → веб', IW, async c => {
    await openTopic(await p1Topic());
    const n0 = await page.locator('#scroller img').count();
    await c.sig('ready');
    await c.wait('sent', 'iphone1', 180);
    await page.waitForFunction(n => document.querySelectorAll('#scroller img').length > n, n0, { timeout: 60000 })
      .catch(() => { throw new Fail('фото не появилось в чате на вебе'); });
    await shot('photo-received');
    await c.sig('seen');
  });
  await scenario('M08', 'Файл веб → iPhone 1', IW, async c => {
    await openTopic(await p1Topic());
    await c.wait('ready', 'iphone1');
    const name = `e2e-file-${c.tag}.txt`;
    const file = path.join(OUT, name);
    fs.writeFileSync(file, 'Линия 2.0 e2e ' + new Date().toISOString() + '\n');
    const inputs = page.locator('#send-message-panel input[type=file], #send-message-wrapper input[type=file]');
    const n = await inputs.count();
    let target = null;
    for (let i = 0; i < n; i++) { const acc = await inputs.nth(i).getAttribute('accept'); if (!acc || !acc.includes('image')) { target = inputs.nth(i); break; } }
    if (!target) throw new Fail('не найдено поле выбора файла');
    await target.setInputFiles(file);
    await sleep(1500);
    await shot('file-preview');
    // Предпросмотр документа: кнопка отправки (иконка send) или Enter.
    const sendBtn = page.locator('.doc-card ~ * button, #send-message-panel a:has(i:text("send")), button:has(i:text("send")), a:has(i:text("send"))').last();
    if (await sendBtn.isVisible().catch(() => false)) await sendBtn.click(); else await page.keyboard.press('Enter');
    await c.sig('sent', name.replace('.txt', ''));
    await waitText('e2e-file', 30000).catch(() => {});
  });
  await scenario('M09', 'Файл iPhone 1 → веб (из «Файлов»)', IW, async c => {
    await openTopic(await p1Topic());
    await c.sig('ready');
    await c.wait('sent', 'iphone1', 180);
    await waitText('e2e-doc', 60000);
    await c.sig('seen');
  });
  await scenario('M10', '«печатает…» веб → iPhone 1', IW, async c => {
    await openTopic(await p1Topic());
    await c.wait('ready', 'iphone1');
    const inp = page.locator('#send-message-input');
    await inp.click();
    let seen = false;
    (async () => { await c.wait('seen', 'iphone1', 40).then(() => { seen = true; }).catch(() => {}); })();
    const end = Date.now() + 40000;
    while (!seen && Date.now() < end) { await inp.type('печатаю ', { delay: 120 }); await sleep(500); }
    await inp.fill('');
    if (!seen) throw new Fail('iPhone 1 не увидел «печатает…»');
  });
  await scenario('M11', '«печатает…» iPhone 1 → веб', IW, async c => {
    await openTopic(await p1Topic());
    await c.sig('ready');
    await page.waitForFunction(() => !!document.querySelector('#topic-last-seen[data-l2-typing="1"], #topic-caption-panel .typing'), null, { timeout: 30000, polling: 100 })
      .catch(() => { throw new Fail('на вебе не показано «печатает…»'); });
    await shot('typing-web');
    await c.sig('seen');
  });
  await scenario('M12', '«прочитано»: веб видит, что iPhone 1 прочитал', IW, async c => {
    const t = await p1Topic();
    await openTopic(t);
    await c.wait('ready', 'iphone1');
    const text = `Прочитай ${c.tag}`;
    await sendText(text);
    await c.sig('sent', text);
    await c.wait('read', 'iphone1', 60);
    const ok = await page.waitForFunction(([tp, tx]) => { const s = window.__l2.findSeq(tp, tx); return s && window.__l2.readCount(tp, s) > 0; }, [t, text], { timeout: 25000 })
      .then(() => true).catch(() => false);
    await shot('read');
    if (!ok) throw new Fail('на вебе нет отметки «прочитано» (msgReadCount = 0)');
    await c.sig('checked');
  });

  // ---------- Звонки ----------
  await scenario('K01', 'Звонок веб → iPhone 1: входящий, принять, соединение, завершить', IW, async c => {
    await openTopic(await p1Topic());
    await c.wait('ready', 'iphone1');
    await startCall();
    await c.sig('calling');
    await c.wait('answered', 'iphone1', 90);
    const m = await waitConnected();
    await shot('call-web-i1');
    await c.sig('connected');
    await sleep(2000);
    await hangUp();
    await c.sig('hungup');
    return m;
  }, 300);
  await scenario('K03', 'Звонок iPhone 2 → веб: принять, соединение, завершить', I2W, async c => {
    await c.sig('ready');
    const acc = page.locator('.incoming-call button.positive').first();
    await acc.waitFor({ timeout: 90000 }).catch(() => { throw new Fail('на вебе не появился входящий звонок'); });
    await shot('incoming-web');
    await acc.click();
    const m = await waitConnected();
    await c.sig('connected');
    await c.wait('hungup', 'iphone2', 60);
    await page.waitForFunction(() => window.__l2.root().state.callState === 0, null, { timeout: 20000 })
      .catch(() => { throw new Fail('на вебе звонок не завершился после отбоя iPhone 2'); });
    await c.sig('ended');
    return m;
  }, 300);
  await scenario('K04', 'Отклонённый звонок веб → iPhone 2 + вкладка «Звонки»', I2W, async c => {
    await openTopic(await p2Topic());
    await c.wait('ready', 'iphone2');
    await startCall();
    await c.sig('calling');
    await c.wait('declined', 'iphone2', 90);
    await page.waitForFunction(() => window.__l2.root().state.callState === 0, null, { timeout: 25000 })
      .catch(async () => { await hangUp(); throw new Fail('веб не получил отказ от iPhone 2'); });
    await c.sig('ended');
  }, 300);
  await scenario('K05', 'Пропущенный звонок веб → iPhone 1 + вкладка «Звонки»', IW, async c => {
    await openTopic(await p1Topic());
    await c.wait('ready', 'iphone1');
    await startCall();
    await c.sig('calling');
    await sleep(15000);
    await hangUp();
    await c.sig('hungup');
  }, 300);

  await scenario('G01', 'Гостевая ссылка на звонок: создать, гость звонит, принять, история, отключить', IW, async c => {
    const [url] = await c.wait('url', 'iphone1', 180);
    if (!url || url === 'none') throw new Skip('пропущен: нет функции (кнопки создания ссылки)');
    const g = await browser.newContext({ viewport: { width: 1280, height: 860 }, locale: 'ru-RU', permissions: ['microphone', 'camera'] });
    await g.addInitScript(INIT);
    const gp = await g.newPage();
    try {
      const r = await gp.goto(url, { waitUntil: 'networkidle' });
      if (!r || r.status() === 404) { await c.sig('opened', '404'); throw new Skip('пропущен: нет функции (/call/<token> → 404)'); }
      await gp.screenshot({ path: path.join(OUT, 'shots', 'web-guest-1-open.png') });
      const name = gp.locator('input[placeholder*="имя" i], input[name*="name" i]').first();
      await name.waitFor({ timeout: 15000 }).catch(() => { throw new Fail('на странице гостя нет поля «Ваше имя»'); });
      await name.fill('Гость e2e');
      await gp.locator('button:has-text("Позвонить"), a:has-text("Позвонить")').first().click();
      await c.sig('opened', 'ok');
      await c.wait('answered', 'iphone1', 90);
      const end = Date.now() + 40000; let a = null;
      while (Date.now() < end) { a = await gp.evaluate(() => window.__l2.rtc()); if (a.ice === 'connected' || a.ice === 'completed') break; await sleep(500); }
      if (!a || !(a.ice === 'connected' || a.ice === 'completed')) throw new Fail('гость: ICE не соединился ' + JSON.stringify(a));
      await sleep(3000);
      const b = await gp.evaluate(() => window.__l2.rtc());
      if (!(b.pair > a.pair)) throw new Fail(`гость: bytesReceived не растёт ${a.pair}→${b.pair}`);
      await gp.screenshot({ path: path.join(OUT, 'shots', 'web-guest-2-call.png') });
      await c.sig('connected');
      await c.wait('hungup', 'iphone1', 60);
      await c.wait('deactivated', 'iphone1', 120);
      await gp.goto(url, { waitUntil: 'networkidle' });
      await sleep(1500);
      await gp.screenshot({ path: path.join(OUT, 'shots', 'web-guest-3-deactivated.png') });
      const txt = await gp.evaluate(() => document.body.innerText);
      if (!/больше не действует/i.test(txt)) throw new Fail('после отключения нет «Ссылка больше не действует»');
      await c.sig('checked');
      return `гость: ICE ${b.ice}, bytesReceived ${a.pair}→${b.pair}`;
    } finally { await g.close(); }
  }, 400);

  // ---------- Сеть ----------
  await scenario('F01', 'Обрыв сети на вебе 10 с → очередь ушла', IW, async c => {
    await openTopic(await p1Topic());
    await c.wait('ready', 'iphone1');
    await context.setOffline(true);
    await sleep(1000);
    const text = `Офлайн веб ${c.tag}`;
    await sendText(text);
    await c.sig('queued', text);
    await shot('offline');
    await sleep(10000);
    await context.setOffline(false);
    await c.sig('online');
  }, 300);
  await scenario('F02', 'Обрыв сети раннера (iOS) 10 с → очередь ушла', IW, async c => {
    await openTopic(await p1Topic());
    await c.sig('ready');
    const [text] = await c.wait('online', 'iphone1', 120);
    const t = Date.now();
    await waitText(text, 120000);
    await c.sig('seen');
    return `на вебе через ${Math.round((Date.now() - t) / 1000)} с после восстановления`;
  }, 300);
  await scenario('F03', 'Переключение на резервный адрес', ALL, async c => {
    const [, info] = await bcall('/net', { op: 'backup-info' });
    if (!info.usable || !info.usable.length) throw new Skip(`пропущен: нет DNS резервного адреса (servers.hosts=${JSON.stringify(info.hosts || [])})`);
    const [text] = await c.wait('sent', 'iphone1', 200);
    await page.reload(); await rootReady(60000);
    await openTopic(await p1Topic());
    await waitText(text, 90000);
    await c.sig('seen');
    return 'резервный: ' + info.usable.join(', ');
  }, 300);

  await scenario('X01', 'Удаление аккаунта (отдельный тест-пользователь)', IW, async c => {
    await c.wait('deleted', 'iphone1', 200);
    const code = await loginCode(E.L2_D_LOGIN, E.L2_D_PASSWORD);
    if (code === 200) throw new Fail('удалённый аккаунт всё ещё входит');
    await c.sig('checked');
    return `вход удалённым аккаунтом: код ${code}`;
  }, 200);
}

try { await play(); }
catch (e) { console.error('web: сбой', e); failedAny = true; await shot('СБОЙ'); }
finally {
  await bcall('/gone', { role: ROLE });
  try { await context.tracing.stop({ path: path.join(OUT, 'trace.zip') }); } catch {}
  const v = page && page.video();
  try { await context.close(); await browser.close(); } catch {}
  // Видео — только если были падения (retain-on-failure).
  if (!failedAny) { try { fs.rmSync(path.join(OUT, 'video'), { recursive: true, force: true }); fs.rmSync(path.join(OUT, 'trace.zip'), { force: true }); } catch {} }
  console.log('web: упали', failed.join(', ') || 'нет');
  process.exit(0);
}
