#!/usr/bin/env python3
"""Линия 2.0: отчёт по тестам из xcresult (JSON `xcresulttool get test-results tests`).

Печатает Markdown: сколько прошло/упало/пропущено, какие тесты прошли только после перезапуска
(нестабильные — не скрываются), причины падений и где лежат скриншоты.
Использование: test-report.py <папка с unit-tests.json / ui-tests.json>
"""
import json
import os
import sys

out = sys.argv[1] if len(sys.argv) > 1 else "."


def walk(node, suite=""):
    t = node.get("nodeType", "")
    if t == "Test Case":
        yield suite, node
        return
    name = node.get("name", "") if t == "Test Suite" else suite
    for c in node.get("children", []) or []:
        yield from walk(c, name)


def failures(node):
    res = []
    for c in node.get("children", []) or []:
        if c.get("nodeType") == "Failure Message":
            res.append(c.get("name", "").strip())
        res.extend(failures(c))
    return res


total = {"passed": 0, "failed": 0, "skipped": 0, "flaky": 0}
lines = []
for kind, title in (("unit", "Юнит-тесты"), ("ui", "UI-тесты (XCUITest)")):
    p = os.path.join(out, f"{kind}-tests.json")
    if not os.path.exists(p) or os.path.getsize(p) == 0:
        lines.append(f"\n### {title}\nРезультатов нет (не собралось или не запускалось — см. лог).\n")
        total["failed"] += 1
        continue
    try:
        data = json.load(open(p))
    except Exception as e:  # noqa: BLE001
        lines.append(f"\n### {title}\nНе удалось прочитать результаты: {e}\n")
        total["failed"] += 1
        continue
    rows = []
    for root in data.get("testNodes", []):
        for suite, tc in walk(root):
            result = tc.get("result", "?")
            reps = [c for c in tc.get("children", []) or [] if c.get("nodeType") == "Repetition"]
            tries = max(1, len(reps))
            failed_tries = sum(1 for r in reps if r.get("result") == "Failed")
            name = tc.get("name", "?").replace("()", "")
            if result == "Passed" and failed_tries:
                status = f"✅ прошёл с {tries}-й попытки (нестабильный)"
                total["flaky"] += 1
                total["passed"] += 1
            elif result == "Passed":
                status = "✅ прошёл"
                total["passed"] += 1
            elif result == "Skipped":
                status = "⏭ пропущен"
                total["skipped"] += 1
            else:
                status = f"❌ упал ({tries} попытки)" if tries > 1 else "❌ упал"
                total["failed"] += 1
            why = "; ".join(dict.fromkeys(failures(tc)))[:300]
            rows.append(f"| {suite}.{name} | {status} | {why} |")
    lines.append(f"\n### {title}\n| Тест | Итог | Причина |\n|---|---|---|")
    if not rows:
        total["failed"] += 1
        rows = ["| — | ❌ тестов не найдено (сборка тестов не прошла — см. лог) | |"]
    lines.extend(rows)

head = (f"## Итог тестов: прошло {total['passed']}, упало {total['failed']}, пропущено {total['skipped']}"
        + (f", нестабильных (прошли после перезапуска) {total['flaky']}" if total["flaky"] else ""))
print(head)
print("\nЗагрузка в TestFlight — только если упавших 0. "
      "Скриншоты падений: артефакт `test-results-*` → `failures/`, все экраны → `shots/`.")
print("\n".join(lines))
with open(os.path.join(out, "totals.json"), "w") as f:
    json.dump(total, f)
