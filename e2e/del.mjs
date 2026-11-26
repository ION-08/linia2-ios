// Удаление тестового пользователя: node del.mjs <логин> <пароль1> [пароль2 …] — пробует пароли по очереди.
import { client } from './tinode.mjs';
const [login, ...pws] = process.argv.slice(2);
for (const pw of pws.filter(Boolean)) {
  const c = client();
  try {
    const code = await c.login(login, pw);
    if (code !== 200) { c.close(); continue; }
    const me = await new Promise(res => {
      const subs = [];
      c.on(m => { if (m.meta && m.meta.sub) subs.push(...m.meta.sub); });
      c.req({ sub: { topic: 'me', get: { what: 'sub' } } }).then(() => setTimeout(() => res(subs), 800)).catch(() => res(subs));
    });
    for (const s of me) if (s.topic && s.topic !== 'me') await c.req({ del: { topic: s.topic, what: 'topic', hard: true } }).catch(() => {});
    const d = await c.req({ del: { what: 'user', hard: true } }).catch(e => ({ code: e.message }));
    console.log(login, 'удалён', d.code);
    c.close(); process.exit(0);
  } catch (e) { c.close(); }
}
console.log(login, 'не удалось войти (уже удалён или не создан)');
process.exit(0);
