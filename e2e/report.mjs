// Отчёт e2e: results.json доски → Markdown (в $GITHUB_STEP_SUMMARY). Код выхода 1, если хоть один сценарий упал или не выполнен.
import fs from 'node:fs';
const [file, out] = process.argv.slice(2);
let d = { scenarios: [] };
try { d = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { console.log('Нет результатов доски: ' + e.message); }
const EXPECTED = [
  ['R01', 'Регистрация по коду → PIN'], ['R02', 'Выход → вход по логину и паролю'], ['R03', 'Перезапуск → PIN (неверный не пускает, верный пускает)'],
  ['R04', 'Вход по логину (iPhone 2)'], ['W01', 'Страница приглашения на телефоне'], ['W02', 'Регистрация по ссылке-приглашению в вебе'], ['R05', 'Вход (веб)'], ['P01', 'Push через FCM (токен iPhone 2 принят Firebase)'],
  ['T01', 'Вкладки: Чаты, Звонки, Контакты, Настройки'], ['S01', 'Настройки: каждый пункт открывается (iPhone 1)'],
  ['N01', 'Настройки: имя'], ['N02', 'Настройки: аватар (фото из галереи)'], ['N03', 'Настройки: тема (светлая → тёмная)'],
  ['N04', 'Настройки: цвет акцента'], ['N05', 'Настройки: уведомления (переключатель туда-обратно)'],
  ['N06', 'Настройки: конфиденциальность (блокировка, безопасность, заблокированные)'], ['N07', 'Настройки: смена пароля → вход с новым паролем'],
  ['N08', 'Настройки: смена PIN → перезапуск с новым PIN'],
  ['C01', 'Новый чат iPhone 1 → iPhone 2'], ['D01', 'Доставка iPhone 1 → iPhone 2'], ['D02', 'Доставка iPhone 2 → iPhone 1'],
  ['C02', 'Новый чат iPhone 1 → веб'], ['D03', 'Доставка iPhone 1 → веб'], ['D04', 'Доставка веб → iPhone 1'],
  ['D05', 'Доставка iPhone 2 → веб'], ['D06', 'Доставка веб → iPhone 2'],
  ['M01', 'Ответ на сообщение'], ['M02', 'Реакция 🔥'], ['M03', 'Закрепить и открепить'], ['M04', 'Изменить сообщение'], ['M05', 'Удалить сообщение'],
  ['M06', 'Переслать в чат с вебом'], ['M07', 'Фото iPhone 1 → веб'], ['M08', 'Файл веб → iPhone 1'], ['M09', 'Файл iPhone 1 → веб'],
  ['M10', '«печатает…» веб → iPhone 1'], ['M11', '«печатает…» iPhone 1 → веб'], ['M12', '«прочитано»'],
  ['K01', 'Звонок веб → iPhone 1'], ['K02', 'Звонок iPhone 1 → iPhone 2'], ['K03', 'Звонок iPhone 2 → веб'],
  ['K04', 'Отклонённый звонок + «Звонки»'], ['K05', 'Пропущенный звонок + «Звонки»'],
  ['F01', 'Обрыв сети на вебе 10 с'], ['F02', 'Обрыв сети раннера (iOS) 10 с'], ['F03', 'Переключение на резервный адрес'],
  ['X01', 'Удаление аккаунта (отдельный тест-пользователь)'],
];
const by = new Map((d.scenarios || []).map(s => [s.id, s]));
const icon = { pass: '✅ прошёл', fail: '❌ упал', skip: '⏭️ пропущен', running: '❌ не завершён', none: '❌ не выполнен' };
const esc = t => String(t || '').replace(/\|/g, '\\|').replace(/\n/g, ' ');
const rows = []; let pass = 0, fail = 0, skip = 0;
for (const [id, title] of EXPECTED) {
  const s = by.get(id); by.delete(id);
  const st = s ? s.status : 'none';
  if (st === 'pass') pass++; else if (st === 'skip') skip++; else fail++;
  const att = s && s.attempts.length > 1 ? ` (попыток: ${s.attempts.length}; ${s.attempts.map(a => `#${a.a} ${a.status}`).join(', ')})` : '';
  const t = s ? (s.ms / 1000).toFixed(1) + ' с' : '—';
  const notes = s ? [...(s.metrics || []), ...(s.status !== 'pass' || att ? (s.notes || []) : [])].join('; ') : 'не дошли до сценария (участник упал или не запустился)';
  rows.push(`| ${id} | ${esc(s ? s.title : title)} | ${icon[st] || st}${att} | ${t} | ${esc(notes).slice(0, 600)} |`);
}
for (const s of by.values()) { rows.push(`| ${s.id} | ${esc(s.title)} | ${icon[s.status]} | ${(s.ms / 1000).toFixed(1)} с | ${esc((s.notes || []).join('; '))} |`); if (s.status === 'fail') fail++; else if (s.status === 'pass') pass++; else skip++; }
const total = pass + fail + skip;
const md = [`## Большой e2e: iPhone + iPhone + Веб`, '', `**Итог: ${pass} из ${total - skip} прошли** (упало ${fail}, пропущено ${skip})`, '',
  '| # | Сценарий | Результат | Время | Замеры / причина |', '|---|---|---|---|---|', ...rows, '',
  'Звонки на iOS: проверены входящий (CallKit), экран звонка, сигнализация; ICE/bytesReceived — со стороны веба (getStats). ' +
  'Качество звука и видео на iOS в симуляторе не проверяется (нет камеры и микрофона). Время доставки на iOS измеряется опросом XCUITest (+0,1–0,5 с).', ''].join('\n');
fs.writeFileSync(out || 'report.md', md);
console.log(md);
process.exit(fail ? 1 : 0);
