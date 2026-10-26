#!/usr/bin/env python3
"""
Проверка полноты switch по enum'ам проекта.

Зачем: swiftc -parse проверяет только синтаксис и НЕ ловит «switch must be
exhaustive» — именно на этом свалилась сборка после добавления OrgKind.lodging.
Полноценный тайп-чек без SwiftUI недоступен, поэтому ищем текстом: собираем
все enum и их case'ы, затем для каждого switch смотрим, из какого enum взяты
метки, и сверяем покрытие.
"""
import re, sys, glob, os

root = sys.argv[1] if len(sys.argv) > 1 else '.'
files = sorted(glob.glob(os.path.join(root, '**', '*.swift'), recursive=True))

# ── 1. enum'ы и их case'ы ──
# Ключ — (файл, имя): в разных файлах бывают свои private enum Step,
# и сливать их в один набор нельзя — получаются ложные срабатывания.
enums = []                       # [(файл, имя, set(case))]
enum_re = re.compile(r'\benum\s+(\w+)\b[^{\n]*\{')
# ВАЖНО: без \s в классе — иначе точка с новой строкой съедает следующий
# «case» и половина вариантов enum теряется (так и вышло с BookingSheet).
case_re = re.compile(r'^[ \t]*case[ \t]+([A-Za-z_][^\n]*)$', re.M)

for f in files:
    src = open(f, encoding='utf-8').read()
    for m in enum_re.finditer(src):
        name = m.group(1)
        # тело enum по балансу скобок
        i, depth = m.end() - 1, 0
        while i < len(src):
            if src[i] == '{': depth += 1
            elif src[i] == '}':
                depth -= 1
                if depth == 0: break
            i += 1
        body = src[m.end():i]
        cases = set()
        for cm in case_re.finditer(body):
            decl = cm.group(1)
            # «case a = "x"», «case a, b», «case a(Int)»
            for part in decl.split(','):
                part = part.split('=')[0].split('(')[0].strip()
                if re.fullmatch(r'[A-Za-z_]\w*', part):
                    cases.add(part)
        if cases:
            enums.append((f, name, cases))

# ── 2. switch-блоки ──
sw_re = re.compile(r'^([ \t]*)switch\b([^\n{]*)\{', re.M)
def switch_labels(text):
    """Метки switch: от «case» до двоеточия ВЕРХНЕГО уровня.

    Требовать конец строки нельзя — в SwiftUI сплошь «case .x(let y): view(y)»,
    и такие метки просто не находились. Двоеточие внутри скобок
    («case .x(y: 1):») тоже не считается концом метки.
    """
    out = []
    for line in text.split('\n'):
        st = line.strip()
        if not st.startswith('case ') and not st.startswith('case\t'):
            continue
        rest = st[5:]
        depth = 0
        end = None
        for i, ch in enumerate(rest):
            if ch in '([': depth += 1
            elif ch in ')]': depth -= 1
            elif ch == ':' and depth == 0: end = i; break
        out.append(rest[:end] if end is not None else rest)
    return out

problems = 0
checked = 0
for f in files:
    src = open(f, encoding='utf-8').read()
    lines = src.split('\n')
    for m in sw_re.finditer(src):
        i, depth = m.end() - 1, 0
        while i < len(src):
            if src[i] == '{': depth += 1
            elif src[i] == '}':
                depth -= 1
                if depth == 0: break
            i += 1
        body = src[m.end():i]
        # вложенные switch убираем из рассмотрения меток верхнего уровня грубо:
        # ищем только метки с отступом ровно на один уровень глубже
        labels = set()
        has_default = re.search(r'^\s*default\s*:', body, re.M) is not None
        for lab in switch_labels(body):
            for part in lab.split(','):
                part = part.strip()
                pm = re.match(r'\.([A-Za-z_]\w*)', part)
                if pm: labels.add(pm.group(1))
        if not labels or has_default:
            continue
        # какому enum принадлежат метки: тот, что покрывает их все и имеет
        # больше всего пересечений
        # Кандидаты: enum, чьи case'ы покрывают все метки. Свой файл важнее;
        # среди равных берём самый узкий набор — он и подразумевался.
        cands = [(ef, en, ec) for (ef, en, ec) in enums if labels <= ec]
        same = [c for c in cands if c[0] == f]
        pool = same or cands
        if not pool:
            continue
        ef, best, bcases = min(pool, key=lambda c: len(c[2]))
        checked += 1
        missing = bcases - labels
        # nil-метки (case .none для Optional) и enum'ы с одним элементом не в счёт
        if missing and 'none' not in labels:
            ln = src[:m.start()].count('\n') + 1
            print(f'{f}:{ln}: switch по {best} не покрывает: '
                  + ', '.join('.' + x for x in sorted(missing)))
            problems += 1

print(f'\nenum найдено: {len(enums)}, switch проверено: {checked}, '
      + (f'НЕПОЛНЫХ: {problems}' if problems else 'неполных нет'))
sys.exit(1 if problems else 0)
