// Минимальный клиент Tinode по WebSocket (Node 22 — встроенный WebSocket) для подготовки и уборки.
export const HOST = process.env.L2_HOST || 'v2.chat-linia.site';
export const API_KEY = 'AQEAAAABAAD_rAp4DJh05a1HAwFT3A6K';

export function client(host = HOST) {
  const ws = new WebSocket(`wss://${host}/v0/channels?apikey=${API_KEY}`);
  let id = 0; const pend = {}; const listeners = [];
  const opened = new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
  const c = {
    ws, uid: null,
    on: fn => listeners.push(fn),
    req: o => new Promise((res, rej) => {
      const k = String(++id); const key = Object.keys(o)[0]; o[key].id = k; pend[k] = res;
      ws.send(JSON.stringify(o));
      setTimeout(() => { if (pend[k]) { delete pend[k]; rej(new Error('timeout ' + key)); } }, 15000);
    }),
    close: () => { try { ws.close(); } catch {} },
  };
  ws.onmessage = ev => {
    const m = JSON.parse(ev.data);
    if (m.ctrl && pend[m.ctrl.id]) { pend[m.ctrl.id](m.ctrl); delete pend[m.ctrl.id]; }
    listeners.forEach(fn => { try { fn(m); } catch {} });
  };
  c.login = async (login, pass) => {
    await opened;
    await c.req({ hi: { ver: '0.25', ua: 'Linia2E2E/1.0' } });
    const l = await c.req({ login: { scheme: 'basic', secret: Buffer.from(login + ':' + pass).toString('base64') } });
    c.uid = l.params?.user; return l.code;
  };
  return c;
}

/** Вход: код ответа сервера (200 — успешно, 401 — неверно/удалён, 0 — нет связи). */
export async function loginCode(login, pass) {
  const c = client();
  try { return await c.login(login, pass); } catch { return 0; } finally { c.close(); }
}
