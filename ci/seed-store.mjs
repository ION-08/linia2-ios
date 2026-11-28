// Демо-данные для скриншотов App Store (uitest.yml, job «store», запуск вручную с store_shots=true).
// Только вымышленные люди и переписка — никаких реальных данных и тестовых меток.
// A — L2_LOGIN (владелец телефона, «Алексей Иванов»); S1..S4 — L2_S<n>_LOGIN / L2_S<n>_PASSWORD:
// S1 «Анна Смирнова» (основной чат: текст, фото, голосовое, реакции, звонок), S2 «Михаил Петров» (видеозвонок),
// S3 «Елена Козлова» (пропущенный звонок), S4 «Дмитрий Орлов» (входящий звонок); группа «Команда проекта» (S1, S2, S3, A).
import zlib from 'node:zlib';

const API = 'wss://v2.chat-linia.site/v0/channels?apikey=AQEAAAABAAD_rAp4DJh05a1HAwFT3A6K';
function client(login, pass) {
  const ws = new WebSocket(API); let id = 0; const pend = {}; const opened = new Promise(r => ws.onopen = r);
  const c = {
    req: o => new Promise((res, rej) => { const k = String(++id); const key = Object.keys(o)[0]; o[key].id = k; pend[k] = res; ws.send(JSON.stringify(o)); setTimeout(() => rej(new Error('timeout ' + key)), 15000); }),
    send: o => ws.send(JSON.stringify(o)),
  };
  ws.onmessage = ev => { const m = JSON.parse(ev.data); if (m.ctrl && pend[m.ctrl.id]) { pend[m.ctrl.id](m.ctrl); delete pend[m.ctrl.id]; } };
  c.login = async () => { await opened; await c.req({ hi: { ver: '0.25' } });
    const l = await c.req({ login: { scheme: 'basic', secret: Buffer.from(login + ':' + pass).toString('base64') } }); c.uid = l.params?.user; return l.code; };
  c.rename = async fn => { await c.req({ sub: { topic: 'me' } }).catch(() => {});
    return (await c.req({ set: { topic: 'me', desc: { public: { fn } } } }).catch(e => ({ code: String(e) }))).code; };
  return c;
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

function crc32(buf) {
  let c, crc = 0xFFFFFFFF;
  for (let n = 0; n < buf.length; n++) {
    c = (crc ^ buf[n]) & 0xFF;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    crc = (crc >>> 8) ^ c;
  }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}
function encodePng(w, h, px) {
  const raw = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0; y < h; y++) { raw[y * (w * 3 + 1)] = 0; px.copy(raw, y * (w * 3 + 1) + 1, y * w * 3, (y + 1) * w * 3); }
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
    return Buffer.concat([len, td, crc]);
  };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]);
}
/** Пейзаж: закатное небо, солнце, две гряды гор, озеро с отражением. */
function landscape(w, h) {
  const px = Buffer.alloc(w * h * 3);
  const mix = (a, b, t) => a + (b - a) * t;
  const ridge = (x, base, amp, f1, f2) => base - amp * (0.55 * Math.sin(x * f1) + 0.45 * Math.sin(x * f2 + 1.3));
  const horizon = Math.round(h * 0.68), sx = w * 0.66, sy = h * 0.42, sr = h * 0.11;
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    let yy = y, water = false;
    if (y > horizon) { yy = 2 * horizon - y; water = true; }
    const t = yy / horizon;
    let r = mix(46, 252, t), g = mix(42, 160, t * t), b = mix(110, 120, t);
    const d = Math.hypot(x - sx, yy - sy);
    if (d < sr) { r = 255; g = 226; b = 150; } else if (d < sr * 2.4) { const k = 1 - (d - sr) / (sr * 1.4); r = mix(r, 255, k * 0.5); g = mix(g, 210, k * 0.5); b = mix(b, 150, k * 0.4); }
    if (yy > ridge(x, h * 0.56, h * 0.08, 0.019, 0.047)) { r = 92; g = 64; b = 108; }
    if (yy > ridge(x, h * 0.64, h * 0.05, 0.031, 0.011)) { r = 44; g = 36; b = 70; }
    if (water) { const k = 0.62 + 0.06 * Math.sin(y * 0.9); r *= k; g *= k; b = b * k + 18; }
    const o = (y * w + x) * 3; px[o] = Math.min(255, r); px[o + 1] = Math.min(255, g); px[o + 2] = Math.min(255, b);
  }
  return encodePng(w, h, px);
}
/** WAV 8 кГц 8 бит моно — тишина (длительность и «волна» в preview). */
function wav(seconds) {
  const n = 8000 * seconds, b = Buffer.alloc(44 + n, 0x80);
  b.write('RIFF', 0); b.writeUInt32LE(36 + n, 4); b.write('WAVE', 8); b.write('fmt ', 12); b.writeUInt32LE(16, 16);
  b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22); b.writeUInt32LE(8000, 24); b.writeUInt32LE(8000, 28); b.writeUInt16LE(1, 32); b.writeUInt16LE(8, 34);
  b.write('data', 36); b.writeUInt32LE(n, 40);
  return b;
}
const bars = () => Buffer.from(Array.from({ length: 48 }, (_, i) => Math.round(30 + 60 * Math.abs(Math.sin(i * 0.45) * Math.cos(i * 0.13))))).toString('base64');
const drafty = { mime: 'text/x-drafty' };
const call = (state, ms) => ({ txt: ' ', fmt: [{ at: 0, len: 1, key: 0 }], ent: [{ tp: 'VC', data: { state, ...(ms ? { duration: ms } : {}) } }] });
const callHead = (state, ms, audio) => ({ ...drafty, webrtc: state, ...(ms ? { 'webrtc-duration': ms } : {}), ...(audio ? { aonly: true } : {}) });

const env = process.env;
const A = client(env.L2_LOGIN, env.L2_PASSWORD);
console.log('вход A', await A.login(), 'имя', await A.rename('Алексей Иванов'));
const names = ['Анна Смирнова', 'Михаил Петров', 'Елена Козлова', 'Дмитрий Орлов'];
const S = [];
for (let i = 1; i <= 4; i++) {
  const c = client(env[`L2_S${i}_LOGIN`], env[`L2_S${i}_PASSWORD`]);
  console.log('вход S' + i, await c.login(), 'имя', await c.rename(names[i - 1]));
  S.push(c);
}

/** Чат A ↔ peer: возвращает pub(who, content, head) → seq. */
async function dialog(peer) {
  const tp = (await peer.req({ sub: { topic: A.uid } })).topic || A.uid;
  const ta = (await A.req({ sub: { topic: peer.uid } })).topic || peer.uid;
  const pub = async (who, content, head) => {
    const me = who === 'A';
    const r = await (me ? A : peer).req({ pub: { topic: me ? ta : tp, noecho: true, content, ...(head ? { head } : {}) } }).catch(e => ({ code: String(e) }));
    if ((r.code || 500) >= 300) console.log('pub', who, r.code);
    await sleep(250);
    return r.params?.seq;
  };
  const read = seq => { if (seq) { peer.send({ note: { topic: tp, what: 'recv', seq } }); peer.send({ note: { topic: tp, what: 'read', seq } }); } };
  return { pub, read };
}

const step = async (name, fn) => { try { await fn(); console.log('готово:', name); } catch (e) { console.log('ошибка:', name, String(e)); } };
// Порядок — снизу вверх в списке чатов (последний написанный — выше).
await step('Дмитрий: входящий звонок, доку', async () => { // Дмитрий: входящий звонок, документы.
  const d = await dialog(S[3]);
  await d.pub('A', 'Дмитрий, документы по договору отправил на почту');
  await d.pub('D', call('finished', 312000), callHead('finished', 312000, true));
  const s = await d.pub('D', 'Документы получил, всё в порядке ✅');
  const s2 = await d.pub('A', 'Отлично, спасибо!');
  d.read(s2 || s);
});
await step('Елена: пропущенный звонок.', async () => { // Елена: пропущенный звонок.
  const e = await dialog(S[2]);
  const s = await e.pub('A', 'Лена, во сколько завтра встречаемся?');
  e.read(s);
  await e.pub('E', 'В 11:00 у входа 🙂');
  await e.pub('E', call('missed'), callHead('missed', 0, true));
  await e.pub('E', 'Перезвони, когда будет минутка');
});
await step('Михаил: видеозвонок.', async () => { // Михаил: видеозвонок.
  const m = await dialog(S[1]);
  await m.pub('M', 'Можем созвониться по видео? Покажу прототип');
  await m.pub('A', call('finished', 754000), callHead('finished', 754000, false));
  await m.pub('M', 'Спасибо за звонок! Отчёт пришлю вечером');
});
await step('Группа «Команда проекта».', async () => { // Группа «Команда проекта».
  const [an, mi, el] = S;
  const g = (await an.req({ sub: { topic: 'new', set: { desc: { public: { fn: 'Команда проекта' }, defacs: { auth: 'JRWPS', anon: 'N' } } } } })).topic;
  console.log('группа', g);
  for (const c of [mi, el, A]) await c.req({ sub: { topic: g } }).catch(e => console.log('sub grp', String(e)));
  const gp = async (c, content) => { await c.req({ pub: { topic: g, noecho: true, content } }).catch(e => console.log('pub grp', String(e))); await sleep(250); };
  await gp(A, 'Коллеги, как дела с релизом?');
  await gp(an, 'Всем привет! Дизайн утверждён 🎉');
  await gp(mi, 'Тесты зелёные, сборка готова');
  await gp(el, 'Отлично! Выпускаем в пятницу 🚀');
});
await step('Анна: основной чат для скриншо', async () => { // Анна: основной чат для скриншота.
  const a = await dialog(S[0]);
  await a.pub('A', call('finished', 185000), callHead('finished', 185000, true));
  await a.pub('N', 'Привет! Ты видел новые макеты?');
  await a.pub('A', 'Да, только что. Тёмная тема — огонь 🔥');
  const img = landscape(480, 320);
  console.log('фото', img.length, 'байт');
  await a.pub('N', { txt: ' Вот главный экран в финальной версии', fmt: [{ at: 0, len: 1, key: 0 }], ent: [{ tp: 'IM', data: { mime: 'image/png', val: img.toString('base64'), width: 480, height: 320, name: 'photo.png', size: img.length } }] }, drafty);
  await a.pub('A', 'Красота! Отправлю команде');
  await a.pub('N', { txt: ' ', fmt: [{ at: 0, len: 1, key: 0 }], ent: [{ tp: 'AU', data: { mime: 'audio/wav', name: 'voice.wav', duration: 12000, val: wav(12).toString('base64'), preview: bars() } }] }, drafty);
  const q = await a.pub('A', 'Созвонимся в 15:00 и всё обсудим?');
  for (const e of ['👍', '❤️']) await a.pub('N', e, { reply: String(q ?? 0), 'linia2-react': e });
  const last = await a.pub('N', 'Давай, наберу по видео 👋');
  a.read(last);
});
await sleep(1500);
console.log('демо-данные готовы');
process.exit(0);
