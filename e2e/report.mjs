// Отчёт e2e: results.json доски → Markdown (в $GITHUB_STEP_SUMMARY). Код выхода 1, если хоть один сценарий упал или не выполнен.
import fs from 'node:fs';
const [file, out] = process.argv.slice(2);
let d = { scenarios: [] };
try { d = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { console.log('Нет результатов доски: ' + e.message); }
// Один список сценариев для iOS и веба: строка → iOS-сценарии | веб-сценарии (id сценариев доски).
const ROWS = [
  ['Регистрация по коду / по ссылке-приглашению → вход', ['R01'], ['W02']],
  ['Страница приглашения на телефоне', [], ['W01']],
  ['Выход → вход по логину и паролю', ['R02'], ['WR02']],
  ['Перезапуск: PIN / повторное открытие с сохранённой сессией', ['R03'], ['WR03']],
  ['Вход по логину', ['R04'], ['R05']],
  ['Push через FCM', ['P01'], ['WP01']],
  ['Вкладки: Чаты, Звонки, Контакты, Настройки', ['T01'], ['WT01']],
  ['Настройки: каждый пункт открывается', ['S01'], ['WS01']],
  ['Настройки: имя', ['N01'], ['WN01']],
  ['Настройки: аватар', ['N02'], ['WN02']],
  ['Настройки: тема', ['N03'], ['WN03']],
  ['Настройки: цвет акцента', ['N04'], ['WN04']],
  ['Настройки: уведомления', ['N05'], ['WN05']],
  ['Настройки: конфиденциальность', ['N06'], ['WN06']],
  ['Настройки: смена пароля', ['N07'], ['WN07']],
  ['Настройки: смена PIN', ['N08'], ['WN08']],
  ['Контакты: найти по логину', [], ['WO01']],
  ['Новый чат', ['C01', 'C02'], ['C02']],
  ['Доставка iPhone 1 ↔ iPhone 2', ['D01', 'D02'], []],
  ['Доставка iPhone 1 → веб', ['D03'], ['D03']],
  ['Доставка веб → iPhone 1', ['D04'], ['D04']],
  ['Доставка iPhone 2 → веб', ['D05'], ['D05']],
  ['Доставка веб → iPhone 2', ['D06'], ['D06']],
  ['Ответ на сообщение', ['M01'], []],
  ['Реакция', ['M02'], []],
  ['Закрепить / открепить', ['M03'], []],
  ['Изменить сообщение', ['M04'], []],
  ['Удалить сообщение', ['M05'], []],
  ['Переслать', ['M06'], ['M06']],
  ['Фото', ['M07'], ['M07']],
  ['Файл веб → iPhone', ['M08'], ['M08']],
  ['Файл iPhone → веб', ['M09'], ['M09']],
  ['«печатает…» веб → iPhone', ['M10'], ['M10']],
  ['«печатает…» iPhone → веб', ['M11'], ['M11']],
  ['«прочитано»', ['M12'], ['M12']],
  ['Звонок веб → iPhone 1', ['K01'], ['K01']],
  ['Звонок iPhone 1 → iPhone 2', ['K02'], []],
  ['Звонок iPhone 2 → веб', ['K03'], ['K03']],
  ['Отклонённый звонок + «Звонки»', ['K04'], ['K04']],
  ['Пропущенный звонок + «Звонки»', ['K05'], ['K05']],
  ['Гостевая ссылка на звонок', ['G01'], ['G01']],
  ['Обрыв сети на вебе 10 с', ['F01'], ['F01']],
  ['Обрыв сети раннера (iOS) 10 с', ['F02'], ['F02']],
  ['Переключение на резервный адрес', ['F03'], ['F03']],
  ['Удаление аккаунта (отдельный пользователь)', ['X01'], ['X01']],
];
const by = new Map((d.scenarios || []).map(s => [s.id, s]));
const esc = t => String(t || '').replace(/\|/g, '\\|').replace(/\n/g, ' ');
const ICON = { pass: '✅', 'pass*': '✅*', fail: '❌', skip: '⏭', none: '❌' };
function cell(ids, roles) {
  if (!ids.length) return '— нет сценария';
  const parts = [];
  for (const id of ids) {
    const s = by.get(id);
    if (!s) { parts.push(`❌ ${id}: не выполнен`); continue; }
    const rs = roles.filter(r => s.byRole && s.byRole[r]).map(r => s.byRole[r]);
    if (!rs.length) { parts.push(`${ICON[s.status] || s.status} ${id}`); continue; }
    const st = rs.some(x => x.status === 'fail') ? 'fail' : rs.every(x => x.status === 'skip') ? 'skip' : rs.some(x => x.status === 'pass*') ? 'pass*' : 'pass';
    const note = rs.map(x => [x.metric, st !== 'pass' ? x.note : ''].filter(Boolean).join(', ')).filter(Boolean).join('; ');
    const att = s.attempts && s.attempts.length > 1 ? `, попыток ${s.attempts.length}` : '';
    parts.push(`${ICON[st]} ${id} — ${(s.ms / 1000).toFixed(0)} с${att}${note ? ': ' + esc(note).slice(0, 260) : ''}`);
  }
  return parts.join('<br>');
}
let pass = 0, fail = 0, skip = 0;
const seen = new Set(ROWS.flatMap(r => [...r[1], ...r[2]]));
for (const id of seen) { const s = by.get(id); const st = s ? s.status : 'none'; if (st === 'pass') pass++; else if (st === 'skip') skip++; else fail++; }
for (const s of by.values()) if (!seen.has(s.id)) { if (s.status === 'pass') pass++; else if (s.status === 'skip') skip++; else fail++; }
const total = pass + fail + skip;
const rows = ROWS.map(([t, ios, web]) => `| ${esc(t)} | ${cell(ios, ['iphone1', 'iphone2'])} | ${cell(web, ['web'])} |`);
const md = [`## Большой e2e: iPhone + iPhone + Веб`, '', `**Итог: ${pass} из ${total - skip} сценариев прошли** (упало ${fail}, пропущено ${skip})`, '',
  '✅ прошёл · ✅* своя часть прошла, у другого участника — нет · ❌ упал · ⏭ пропущен (причина рядом). Время — длительность сценария.', '',
  '| Сценарий | iOS | Веб |', '|---|---|---|', ...rows, '',
  'Звонки на iOS: входящий, экран звонка, l2.call.state «Идёт звонок»; ICE/bytesReceived — со стороны веба (getStats). ' +
  'Качество звука и видео на iOS в симуляторе не проверяется (нет камеры и микрофона). Время доставки на iOS — опрос XCUITest (+0,1–0,5 с).', ''].join('\n');
// Скриншоты и проверки аккуратности (не влияют на код выхода — эвристики, смотреть глазами).
const NAMES = { cut: 'не обрезано', kb: 'клавиатура', bg: 'фон #0A0E1B', margin: 'отступы', ru: 'по-русски', snapshot: 'дерево' };
const scr = d.screens || [];
let bad = 0;
const srows = scr.map(x => {
  const parts = String(x.checks || '').split(';').filter(Boolean).map(c => { const [k, ...v] = c.split('='); const r = v.join('='); const ok = r === 'ok'; if (!ok) bad++; return `${ok ? '✅' : '❌'} ${NAMES[k] || k}${ok ? '' : ' (' + esc(r.replace(/^fail:/, '')).slice(0, 80) + ')'}`; });
  const dir = x.role === 'web' ? 'web/shots' : `shots-${x.role}`;
  return `| ${x.role} | ${esc(x.name)} | ${parts.join('<br>') || '—'} | \`${dir}/${esc(x.file)}.png\` |`;
});
const smd = ['', `### Скриншоты (${scr.length}; замечаний по аккуратности: ${bad})`, '',
  'Файлы — в артефакте e2e-results-N. Проверки: текст не обрезан краем экрана, поле ввода не под клавиатурой, фон по краям = #0A0E1B ±14, отступы карточек слева = справа (±2 pt), нет латинских слов (кроме логинов, PIN, iPhone и т.п.).', '',
  '| Роль | Экран | Проверки | Файл |', '|---|---|---|---|', ...srows, ''].join('\n');
fs.writeFileSync(out || 'report.md', md + smd);
console.log(md);
process.exit(fail ? 1 : 0);
