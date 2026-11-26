// «Доска» e2e-теста: маленький HTTP-сервер на 127.0.0.1 раннера.
// Участники (iphone1, iphone2 — XCUITest в симуляторах; web — Playwright) через неё:
//   * ставят и ждут сигналы (/set, /wait) — «я открыл чат», «отправил msg#3 в момент T»;
//   * отчитываются о своей части сценария (/part) и ждут общего вердикта (/verdict) —
//     если хоть у одного участника часть не прошла, сценарий повторяют все вместе (до 3 попыток);
//   * просят «сломать»/«починить» сеть раннера (/net) — pfctl и /etc/hosts (нужен sudo без пароля).
// Итог — results.json (его читает report.mjs).
import http from 'node:http';
import fs from 'node:fs';
import { execSync } from 'node:child_process';
import dns from 'node:dns/promises';

const PORT = +(process.env.L2_BOARD_PORT || 8765);
const OUT = process.env.L2_BOARD_OUT || 'results.json';
const LOG = process.env.L2_BOARD_LOG || 'board.log';
const HOST = process.env.L2_HOST || 'v2.chat-linia.site';
const MAX_ATTEMPTS = 3;

const signals = new Map();        // key -> {v, ts}
const waiters = new Map();        // key -> [fn]
const gone = new Set();           // участники, которые уже завершились
const parts = new Map();          // "s#a" -> {role -> {ok, note, metric, ts}}
const starts = new Map();         // "s#a" -> ts первого старта
const verdicts = new Map();       // "s#a" -> {status, notes}
const scen = new Map();           // s -> {id, title, roles, attempts:[...], status, ms, notes, metrics}
const aborted = new Set();        // "s#a" — кто-то уже отчитался о провале: ожидания сигналов этой попытки сразу отпускаются
const order = [];
const screens = [];        // скриншоты и проверки аккуратности: {role, name, file, checks}
let netState = 'ok';

const log = (...a) => { const l = new Date().toISOString().slice(11, 23) + ' ' + a.join(' '); fs.appendFileSync(LOG, l + '\n'); };
const save = () => {
  const list = order.map(s => scen.get(s));
  fs.writeFileSync(OUT, JSON.stringify({ host: HOST, finished: new Date().toISOString(), scenarios: list, screens, gone: [...gone] }, null, 1));
};

function setSignal(k, v) {
  signals.set(k, { v, ts: Date.now() });
  const ws = waiters.get(k) || []; waiters.delete(k);
  ws.forEach(fn => fn());
}

function prefixOf(k) { const i = k.indexOf(':'); return i > 0 ? k.slice(0, i) : ''; }

function waitSignal(k, ms) {
  return new Promise(res => {
    if (signals.has(k)) return res({ code: 200, body: signals.get(k) });
    let done = false;
    const fin = r => { if (!done) { done = true; clearTimeout(t); clearInterval(iv); res(r); } };
    const t = setTimeout(() => fin({ code: 408, body: { error: 'timeout', k } }), ms);
    // Попытка уже провалена у кого-то или нужный участник завершился — не ждём зря.
    const iv = setInterval(() => {
      const p = prefixOf(k);
      if (p && aborted.has(p)) fin({ code: 409, body: { error: 'aborted', k } });
      const m = /@(iphone1|iphone2|web)$/.exec(k);
      if (m && gone.has(m[1])) fin({ code: 410, body: { error: 'gone', role: m[1], k } });
    }, 250);
    const arr = waiters.get(k) || []; arr.push(() => fin({ code: 200, body: signals.get(k) })); waiters.set(k, arr);
  });
}

function scenario(s, title, roles) {
  if (!scen.has(s)) {
    scen.set(s, { id: s, title: title || s, roles, attempts: [], status: 'running', ms: 0, notes: [], metrics: [] });
    order.push(s);
  } else if (title && scen.get(s).title === s) scen.get(s).title = title;
  return scen.get(s);
}

function decide(s, a, roles, timedOut) {
  const key = s + '#' + a;
  if (verdicts.has(key)) return verdicts.get(key);
  const p = parts.get(key) || {};
  const missing = roles.filter(r => !p[r]);
  if (missing.length && !timedOut && !missing.every(r => gone.has(r))) return null;
  const notes = [];
  let status = 'pass';
  for (const r of roles) {
    const x = p[r];
    if (!x) { status = 'fail'; notes.push(`${r}: ${gone.has(r) ? 'участник уже завершился' : 'нет ответа (таймаут)'}`); continue; }
    if (x.ok === 'skip') { if (status === 'pass') status = 'skip'; if (x.note) notes.push(`${r}: ${x.note}`); continue; }
    if (!x.ok) status = 'fail';
    if (x.note) notes.push(`${r}: ${x.note}`);
  }
  const sc = scen.get(s);
  const t0 = starts.get(key) || Date.now();
  const anyGone = roles.some(r => gone.has(r));
  const final = status !== 'fail' || a >= MAX_ATTEMPTS || anyGone;
  const v = { status, final, notes, attempt: a };
  verdicts.set(key, v);
  sc.attempts.push({ a, status, notes, ms: Date.now() - t0 });
  for (const r of roles) if (p[r] && p[r].metric) sc.metrics.push(`${r}: ${p[r].metric}`);
  // Результат по каждому участнику (для колонок «iOS | Веб» в отчёте).
  sc.byRole = {};
  for (const r of roles) {
    const x = p[r];
    sc.byRole[r] = !x ? { status: 'fail', note: gone.has(r) ? 'участник завершился' : 'нет ответа' }
      : { status: x.ok === 'skip' ? 'skip' : (x.ok ? (status === 'fail' ? 'pass*' : 'pass') : 'fail'), note: x.note || '', metric: x.metric || '' };
  }
  if (final) {
    sc.status = status; sc.ms = sc.attempts.reduce((x, y) => x + y.ms, 0); sc.notes = notes;
    log('ИТОГ', s, status, 'попытка', a, notes.join(' | '));
    save();
  } else log('попытка не прошла', s, a, notes.join(' | '));
  return v;
}

// ---- Сеть раннера ----
function sh(cmd) { try { return execSync(cmd, { stdio: ['ignore', 'pipe', 'pipe'], timeout: 20000 }).toString(); } catch (e) { return 'ERR ' + (e.stderr || e.message); } }
async function ips(host) {
  const out = new Set();
  try { (await dns.resolve4(host)).forEach(x => out.add(x)); } catch {}
  try { (await dns.resolve6(host)).forEach(x => out.add(x)); } catch {}
  return [...out];
}
let blocked = [];
async function net(op) {
  const flush = 'sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder';
  if (op === 'block') {
    blocked = await ips(HOST);
    const rules = blocked.map(ip => `block drop quick from any to ${ip}\nblock drop quick from ${ip} to any`).join('\n') + '\n';
    fs.writeFileSync('/tmp/l2e2e.pf', rules);
    let r = sh('sudo pfctl -E 2>&1; sudo pfctl -a com.apple/l2e2e -f /tmp/l2e2e.pf 2>&1');
    for (const ip of blocked) r += sh(`sudo pfctl -k 0.0.0.0/0 -k ${ip} 2>&1; sudo pfctl -k ${ip} 2>&1`);
    netState = 'blocked'; return { ok: true, ips: blocked, out: r.slice(-400) };
  }
  if (op === 'unblock') {
    const r = sh('sudo pfctl -a com.apple/l2e2e -F all 2>&1');
    netState = 'ok'; return { ok: true, out: r.slice(-300) };
  }
  if (op === 'hosts-break') {
    // Основной адрес → «чёрная дыра» (таймаут подключения), резервные адреса не трогаем.
    sh(`sudo cp /etc/hosts /tmp/l2e2e.hosts.bak; echo "10.255.255.1 ${HOST}" | sudo tee -a /etc/hosts >/dev/null; ${flush}`);
    netState = 'hosts'; return { ok: true, resolved: sh(`dscacheutil -q host -a name ${HOST}`).slice(0, 300) };
  }
  if (op === 'hosts-restore') {
    sh(`[ -f /tmp/l2e2e.hosts.bak ] && sudo cp /tmp/l2e2e.hosts.bak /etc/hosts; ${flush}`);
    netState = 'ok'; return { ok: true };
  }
  if (op === 'backup-info') {
    // Есть ли резервный адрес: servers.hosts в app-config.json и DNS у второго адреса.
    let hosts = [];
    try { const r = await fetch(`https://${HOST}/app-config.json?t=${Date.now()}`); const j = await r.json(); hosts = (j.servers && j.servers.hosts) || []; } catch {}
    const backup = hosts.filter(h => h !== HOST);
    const res = [];
    for (const h of backup) res.push({ host: h, ips: await ips(h) });
    const usable = res.filter(x => x.ips.length);
    return { ok: true, hosts, backup: res, usable: usable.map(x => x.host) };
  }
  return { ok: false, error: 'unknown op' };
}

function restoreNet() {
  if (netState === 'blocked') sh('sudo pfctl -a com.apple/l2e2e -F all');
  if (netState === 'hosts') sh('[ -f /tmp/l2e2e.hosts.bak ] && sudo cp /tmp/l2e2e.hosts.bak /etc/hosts; sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder');
  netState = 'ok';
}

// ---- HTTP ----
function body(req) {
  return new Promise(res => { let b = ''; req.on('data', c => b += c); req.on('end', () => { try { res(b ? JSON.parse(b) : {}); } catch { res({}); } }); });
}

const srv = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  const q = Object.fromEntries(u.searchParams);
  const b = req.method === 'POST' ? await body(req) : {};
  const p = { ...q, ...b };
  const send = (code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json', Connection: 'close' }); res.end(JSON.stringify(obj)); };
  try {
    switch (u.pathname) {
      case '/ping': return send(200, { ok: true, now: Date.now() });
      case '/set': log('set', p.k, String(p.v ?? '').slice(0, 120)); setSignal(p.k, p.v ?? ''); return send(200, { ok: true });
      case '/get': return signals.has(p.k) ? send(200, signals.get(p.k)) : send(404, { error: 'none' });
      case '/wait': { const r = await waitSignal(p.k, Math.min(+(p.t || 60), 900) * 1000); return send(r.code, r.body); }
      case '/gone': gone.add(p.role); log('завершился', p.role); save(); return send(200, { ok: true });
      case '/start': {
        const sc = scenario(p.s, p.title, (p.roles || p.role || '').split(',').filter(Boolean));
        const key = p.s + '#' + p.a;
        if (!starts.has(key)) { starts.set(key, Date.now()); log('СТАРТ', p.s, 'попытка', p.a, p.role); }
        return send(200, { ok: true, title: sc.title });
      }
      case '/part': {
        const roles = (p.roles || p.role).split(',').filter(Boolean);
        scenario(p.s, p.title, roles);
        const key = p.s + '#' + p.a;
        const m = parts.get(key) || {}; parts.set(key, m);
        const ok = p.ok === 'skip' ? 'skip' : (p.ok === true || p.ok === 'true' || p.ok === '1');
        m[p.role] = { ok, note: p.note || '', metric: p.metric || '', ts: Date.now() };
        if (!ok) aborted.add(key);
        log('часть', p.s, p.a, p.role, ok, p.note || '', p.metric || '');
        return send(200, { ok: true });
      }
      case '/verdict': {
        const roles = (p.roles || p.role).split(',').filter(Boolean);
        const t = Math.min(+(p.t || 120), 900) * 1000, t0 = Date.now();
        let v;
        while (!(v = decide(p.s, +p.a, roles, Date.now() - t0 > t))) await new Promise(r => setTimeout(r, 300));
        return send(200, v);
      }
      case '/barrier': {
        const roles = (p.roles || '').split(',').filter(Boolean);
        setSignal(`bar:${p.n}@${p.role}`, '1');
        const t = Math.min(+(p.t || 300), 1800) * 1000, t0 = Date.now();
        for (;;) {
          const missing = roles.filter(r => r !== p.role && !signals.has(`bar:${p.n}@${r}`) && !gone.has(r));
          if (!missing.length) return send(200, { ok: true, gone: roles.filter(r => gone.has(r)) });
          if (Date.now() - t0 > t) return send(408, { ok: false, missing });
          await new Promise(r => setTimeout(r, 300));
        }
      }
      case '/net': { log('сеть', p.op); const r = await net(p.op); log('сеть', p.op, JSON.stringify(r).slice(0, 300)); return send(200, r); }
      case '/push-check': {
        // Служебная проверка сервера: есть ли у пользователя FCM-токены и принимает ли их Firebase (validate_only).
        try {
          const r = await fetch(`https://${HOST}/invite/api/ci/push-check`, { method: 'POST',
            headers: { Authorization: 'Bearer ' + (process.env.CI_TOKEN || ''), 'Content-Type': 'application/json' },
            body: JSON.stringify({ login: p.login }) });
          let j = {}; try { j = await r.json(); } catch {}
          log('push-check', p.login, r.status, JSON.stringify(j).slice(0, 300));
          return send(200, { http: r.status, ...j });
        } catch (e) { return send(200, { http: 0, error: e.message }); }
      }
      case '/screen': screens.push({ role: p.role, name: p.name, file: p.file, checks: p.checks || '' }); return send(200, { ok: true });
      case '/log': log('[' + (p.role || '?') + ']', p.m || ''); return send(200, { ok: true });
      case '/results': save(); return send(200, { scenarios: order.map(s => scen.get(s)) });
      default: return send(404, { error: 'no route' });
    }
  } catch (e) { log('ошибка', u.pathname, e.message); send(500, { error: e.message }); }
});
srv.keepAliveTimeout = 1000;
srv.requestTimeout = 0;
srv.listen(PORT, '127.0.0.1', () => log('доска слушает', PORT));
const stop = () => { restoreNet(); save(); log('остановлена'); process.exit(0); };
process.on('SIGTERM', stop); process.on('SIGINT', stop);
setInterval(save, 15000);
