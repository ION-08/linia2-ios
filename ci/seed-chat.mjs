// История переписки для UI-тестов (uitest.yml, шаг «История переписки для теста»).
// A — L2_LOGIN; B — L2_PEER_LOGIN («Собеседник CI»); C — L2_C_LOGIN («Собеседник iOS», звонок iOS ↔ iOS);
// D — L2_D_LOGIN («Дизайн CI», только для job design): отдельный чат для дизайн-контроля —
// длинная история, закреплённое, фото, голосовые, кружок, ответ, реакции (перед каждым видом — «Метка: …»).
// Пишет L2_IOS_UID в $GITHUB_ENV.
import fs from 'node:fs';
import zlib from 'node:zlib';

const API = 'wss://v2.chat-linia.site/v0/channels?apikey=AQEAAAABAAD_rAp4DJh05a1HAwFT3A6K';
function client(login, pass) {
  const ws = new WebSocket(API); let id = 0; const pend = {}; const opened = new Promise(r => ws.onopen = r);
  const c = { req: o => new Promise((res, rej) => { const k = String(++id); const key = Object.keys(o)[0]; o[key].id = k; pend[k] = res; ws.send(JSON.stringify(o)); setTimeout(() => rej(new Error('timeout ' + key)), 15000); }) };
  ws.onmessage = ev => { const m = JSON.parse(ev.data); if (m.ctrl && pend[m.ctrl.id]) { pend[m.ctrl.id](m.ctrl); delete pend[m.ctrl.id]; } };
  c.login = async () => { await opened; await c.req({ hi: { ver: '0.25' } });
    const l = await c.req({ login: { scheme: 'basic', secret: Buffer.from(login + ':' + pass).toString('base64') } }); c.uid = l.params?.user; return l.code; };
  return c;
}
const env = process.env;
const A = client(env.L2_LOGIN, env.L2_PASSWORD);
console.log('вход A', await A.login());
fs.appendFileSync(env.GITHUB_ENV, `L2_IOS_UID=${A.uid}\n`);

if (env.L2_PEER_LOGIN) {
  const B = client(env.L2_PEER_LOGIN, env.L2_PEER_PASSWORD);
  console.log('вход B', await B.login());
  // Имя меняется только после подписки на me (без неё Tinode отвечает 304 и имя остаётся «Тест CI»).
  await B.req({ sub: { topic: 'me' } }).catch(() => {});
  console.log('имя', (await B.req({ set: { topic: 'me', desc: { public: { fn: 'Собеседник CI' } } } }).catch(e => ({ code: String(e) }))).code);
  const sb = await B.req({ sub: { topic: A.uid } }); const topic = sb.topic || A.uid;
  for (let i = 1; i <= 3; i++) { const p = await B.req({ pub: { topic, content: 'История ' + i } }); console.log('pub', p.code); }
  const sa = await A.req({ sub: { topic: B.uid } }); await A.req({ pub: { topic: sa.topic || B.uid, content: 'История ответ' } });
}

if (env.L2_C_LOGIN) {
  const C = client(env.L2_C_LOGIN, env.L2_C_PASSWORD);
  console.log('вход C', await C.login());
  await C.req({ sub: { topic: 'me' } }).catch(() => {});
  console.log('имя C', (await C.req({ set: { topic: 'me', desc: { public: { fn: 'Собеседник iOS' } } } }).catch(e => ({ code: String(e) }))).code);
  const sc = await C.req({ sub: { topic: A.uid } }); await C.req({ pub: { topic: sc.topic || A.uid, content: 'Позвони мне' } });
  const sa2 = await A.req({ sub: { topic: C.uid } }); await A.req({ pub: { topic: sa2.topic || C.uid, content: 'Сейчас позвоню' } });
}

// ---- Дизайн-контроль: отдельный чат A ↔ D ----

function crc32(buf) {
  let c, crc = 0xFFFFFFFF;
  for (let n = 0; n < buf.length; n++) {
    c = (crc ^ buf[n]) & 0xFF;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    crc = (crc >>> 8) ^ c;
  }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}
/** PNG w×h: мягкий градиент (фото-заглушка). */
function png(w, h, r0, g0, b0) {
  const raw = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 3 + 1)] = 0;
    for (let x = 0; x < w; x++) {
      const o = y * (w * 3 + 1) + 1 + x * 3;
      // Без переполнения канала: «& 255» давал фиолетовую полосу внизу постера кружка.
      raw[o] = Math.min(255, r0 + x * 120 / w); raw[o + 1] = Math.min(255, g0 + y * 120 / h); raw[o + 2] = Math.min(255, b0 + (x + y) * 60 / (w + h));
    }
  }
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
    return Buffer.concat([len, td, crc]);
  };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}
/** WAV 8 кГц 8 бит моно — тишина. */
function wav(seconds) {
  const n = 8000 * seconds, b = Buffer.alloc(44 + n, 0x80);
  b.write('RIFF', 0); b.writeUInt32LE(36 + n, 4); b.write('WAVE', 8); b.write('fmt ', 12); b.writeUInt32LE(16, 16);
  b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22); b.writeUInt32LE(8000, 24); b.writeUInt32LE(8000, 28); b.writeUInt16LE(1, 32); b.writeUInt16LE(8, 34);
  b.write('data', 36); b.writeUInt32LE(n, 40);
  return b;
}
const bars = () => Buffer.from(Array.from({ length: 48 }, (_, i) => 20 + (i * 37) % 80)).toString('base64');

if (env.L2_D_LOGIN) {
  const D = client(env.L2_D_LOGIN, env.L2_D_PASSWORD);
  console.log('вход D', await D.login());
  await D.req({ sub: { topic: 'me' } }).catch(() => {});
  console.log('имя D', (await D.req({ set: { topic: 'me', desc: { public: { fn: env.L2_D_NAME || 'Дизайн CI' } } } }).catch(e => ({ code: String(e) }))).code);
  const sd = await D.req({ sub: { topic: A.uid } }); const td = sd.topic || A.uid;
  const sa = await A.req({ sub: { topic: D.uid } }); const ta = sa.topic || D.uid;
  const drafty = { mime: 'text/x-drafty' };
  const pub = async (who, content, head) => {
    const r = await (who === 'A' ? A : D).req({ pub: { topic: who === 'A' ? ta : td, noecho: true, content, ...(head ? { head } : {}) } }).catch(e => ({ code: String(e) }));
    if ((r.code || 500) >= 300) console.log('pub', who, r.code);
    return r.params?.seq;
  };
  // Длинная переписка; первое — закрепляется.
  const pinned = await pub('D', 'Закреплённое сообщение: правила чата и важные ссылки');
  const phrases = ['Привет! Как дела?', 'Отлично, спасибо. Что по проекту?', 'Макеты почти готовы, осталось пару экранов',
    'Супер. Скинешь сегодня?', 'Да, вечером пришлю ссылку', 'Длинное сообщение, чтобы проверить перенос строк в пузыре: ' +
    'текст должен аккуратно переноситься, не вылезать за край экрана и не наезжать на время и галочки', 'Ок 👍',
    'Созвонимся завтра в 10?', 'Давай', 'Не забудь про презентацию'];
  for (let i = 0; i < 24; i++) await pub(i % 3 === 1 ? 'A' : 'D', `Сообщение ${i + 1}. ${phrases[i % phrases.length]}`);
  if (pinned) console.log('закреп', (await A.req({ set: { topic: ta, aux: { pins: [pinned] } } }).catch(e => ({ code: String(e) }))).code);

  await pub('D', 'Метка: фото');
  const img = png(320, 240, 60, 90, 150);
  await pub('D', { txt: ' ', fmt: [{ at: 0, len: 1, key: 0 }], ent: [{ tp: 'IM', data: { mime: 'image/png', val: img.toString('base64'), width: 320, height: 240, name: 'photo.png', size: img.length } }] }, drafty);
  await pub('A', { txt: ' Вот фото с подписью', fmt: [{ at: 0, len: 1, key: 0 }], ent: [{ tp: 'IM', data: { mime: 'image/png', val: png(240, 320, 150, 70, 60).toString('base64'), width: 240, height: 320, name: 'photo2.png' } }] }, drafty);

  await pub('D', 'Метка: голосовое');
  for (const [who, s] of [['D', 3], ['D', 7], ['A', 4]]) {
    await pub(who, { txt: ' ', fmt: [{ at: 0, len: 1, key: 0 }], ent: [{ tp: 'AU', data: { mime: 'audio/wav', name: 'voice.wav', duration: s * 1000, val: wav(s).toString('base64'), preview: bars() } }] }, drafty);
  }

  await pub('D', 'Метка: кружок');
  const poster = png(192, 192, 90, 140, 110);
  await pub('D', { txt: ' ', fmt: [{ at: 0, len: 1, key: 0 }], ent: [{ tp: 'VD', data: { mime: 'video/mp4', name: 'round.mp4', duration: 12000, width: 384, height: 384, round: true, premime: 'image/png', preview: poster.toString('base64') } }] },
            { ...drafty, 'linia2-round': 1, 'linia2-ttl': 604800 });

  await pub('D', 'Метка: ответ');
  const orig = await pub('D', 'Во сколько встреча?');
  const quote = 'Во сколько встреча?';
  const reply = 'В 10:00, в переговорке';
  await pub('A', { txt: quote + reply, fmt: [{ tp: 'QQ', at: 0, len: quote.length }] }, { ...drafty, reply: String(orig ?? 0) });

  await pub('D', 'Метка: реакции');
  const liked = await pub('A', 'Сообщение с реакциями — нажмите и удерживайте');
  for (const e of ['👍', '❤️', '🔥']) await pub('D', e, { reply: String(liked ?? 0), 'linia2-react': e });
  await pub('D', 'Последнее сообщение: всё готово ✅');
  console.log('дизайн-чат готов', ta);
}
process.exit(0);
