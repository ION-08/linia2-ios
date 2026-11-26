// Подготовка: имена тестовых пользователей, переписка iPhone2 ↔ веб. Печатает KEY=VALUE для $GITHUB_ENV.
// Вход каждым пользователем заодно привязывает его к аккаунту Tinode (тогда /ci/cleanup чужого прогона его не удалит).
import { client } from './tinode.mjs';
const E = process.env;
const users = [
  ['P2', E.L2_P2_LOGIN, E.L2_P2_PASSWORD, E.L2_P2_SEEDNAME],
  ['W', E.L2_W_LOGIN, E.L2_W_PASSWORD, E.L2_W_NAME],
  ['D', E.L2_D_LOGIN, E.L2_D_PASSWORD, E.L2_D_NAME],
];
const cs = {};
for (const [k, login, pass, fn] of users) {
  const c = client();
  const code = await c.login(login, pass);
  console.error(k, 'вход', code);
  if (code !== 200) { console.error('::error::не удалось войти тестовым пользователем', k); process.exit(1); }
  await c.req({ sub: { topic: 'me' } }).catch(() => {});
  await c.req({ set: { topic: 'me', desc: { public: { fn } } } }).catch(e => console.error('fn', e.message));
  cs[k] = c;
  console.log(`L2_${k}_UID=${c.uid}`);
}
// Чат iPhone2 ↔ веб уже есть (новые чаты создаются в тесте с iPhone1).
const a = await cs.P2.req({ sub: { topic: cs.W.uid, get: { what: 'desc sub' } } });
await cs.P2.req({ pub: { topic: a.topic || cs.W.uid, content: 'Привет от iPhone 2 (подготовка)' } });
const b = await cs.W.req({ sub: { topic: cs.P2.uid } });
await cs.W.req({ pub: { topic: b.topic || cs.P2.uid, content: 'Привет от веба (подготовка)' } });
console.error('переписка P2↔W', a.code, b.code);
Object.values(cs).forEach(c => c.close());
process.exit(0);
