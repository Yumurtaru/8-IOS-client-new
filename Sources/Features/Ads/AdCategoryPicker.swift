import SwiftUI

/*
  Выбор категории объявления — как у крупных площадок объявлений: сначала крупные
  плитки разделов с иконками, затем список подкатегорий раздела (переход в
  NavigationStack), поиск сразу по всем рубрикам с путём «Раздел · Подкатегория».
  Вместо системного Picker со списком из ~50 строк. Шторка — на весь экран.
  Тексты, цвета и порядок — общие с Android (AdCategoryPicker.kt).

  Что выбирается: подкатегория; раздел без подкатегорий — сам раздел (как leaves() в форме).
*/

enum AdCatUI {
    /// Мягкие цвета плиток разделов — по порядку раздела (как на Android).
    private static let tints: [Color] = [
        Color(hex: "#3B82F6"), Color(hex: "#10B981"), Color(hex: "#F59E0B"), Color(hex: "#8B5CF6"),
        Color(hex: "#F43F5E"), Color(hex: "#14B8A6"), Color(hex: "#F97316"), Color(hex: "#6366F1"),
        Color(hex: "#65A30D"), Color(hex: "#EC4899"),
    ]

    static func tint(_ index: Int) -> Color {
        let n = tints.count
        return tints[((index % n) + n) % n]
    }

    /// «1 подкатегория / 2 подкатегории / 5 подкатегорий».
    static func subcatCount(_ n: Int) -> String {
        "\(n) " + plural(n, "подкатегория", "подкатегории", "подкатегорий")
    }

    /// Цена размещения: «49 ₽ · 30 дней» или «Бесплатно · 30 дней».
    static func priceText(_ c: AdCategory) -> String {
        let p = c.priceValue > 0 ? Money.format(c.priceValue) : "Бесплатно"
        let d = c.daysValue
        guard d > 0 else { return p }
        let days = "\(d) " + plural(d, "день", "дня", "дней")
        return "\(p) · \(days)"
    }

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10
        let m100 = n % 100
        if m10 == 1 && m100 != 11 { return one }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
        return many
    }

    static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ё", with: "е").trimmingCharacters(in: .whitespaces)
    }

    /// Раздел, в котором лежит категория id (сама — раздел или его подкатегория).
    static func root(of id: Int?, in cats: [AdCategory]) -> AdCategory? {
        guard let id, id > 0 else { return nil }
        return cats.first { r in r.stableId == id || (r.children ?? []).contains { $0.stableId == id } }
    }

    static func rootIndex(of id: Int?, in cats: [AdCategory]) -> Int {
        guard let r = root(of: id, in: cats) else { return -1 }
        return cats.firstIndex { $0.stableId == r.stableId } ?? -1
    }

    /// Путь для поля формы: «Транспорт · Автомобили» (раздел без подкатегорий — одно имя).
    static func path(of id: Int?, in cats: [AdCategory]) -> String? {
        guard let r = root(of: id, in: cats) else { return nil }
        let rootName = r.name ?? ""
        if r.stableId == id { return rootName }
        guard let leaf = (r.children ?? []).first(where: { $0.stableId == id }) else { return rootName }
        return "\(rootName) · \(leaf.name ?? "")"
    }
}

/// Поле «Категория» в форме: иконка раздела, путь, цена размещения, стрелка.
struct AdCategoryFieldRow: View {
    let cats: [AdCategory]
    let chosen: AdCategory?
    /// П-26.6: закрытая рубрика — её название текстом вместо пути (в списке выбора её нет).
    var overrideText: String? = nil
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        let root = AdCatUI.root(of: chosen?.stableId, in: cats)
        let tint = root != nil ? AdCatUI.tint(AdCatUI.rootIndex(of: chosen?.stableId, in: cats)) : YMColor.muted
        let path = overrideText ?? AdCatUI.path(of: chosen?.stableId, in: cats)
        Button(action: action) {
            HStack(spacing: YMSpace.md) {
                Image(systemName: root.map { adCategorySymbol($0.icon, $0.name ?? "") } ?? "square.grid.2x2")
                    .ymIcon(18, weight: .semibold)
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(tint.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Категория").font(YMFont.caption).foregroundStyle(YMColor.muted)
                    Text(path ?? "Выберите категорию")
                        .font(path != nil ? YMFont.styled(.body, .semibold) : YMFont.body)
                        .foregroundStyle(path != nil ? YMColor.text : YMColor.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let c = chosen, overrideText == nil {
                        Text("Размещение: \(AdCatUI.priceText(c))")
                            .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    }
                }
                Spacer(minLength: 0)
                if enabled {
                    Image(systemName: "chevron.right")
                        .ymIcon(13, weight: .semibold)
                        .foregroundStyle(YMColor.muted)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(path.map { "Категория: \($0)" } ?? "Выберите категорию")
    }
}

/// Шторка выбора категории на весь экран.
struct AdCategoryPicker: View {
    let cats: [AdCategory]
    let selectedId: Int?
    let onPick: (AdCategory) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var path: [Int]

    init(cats: [AdCategory], selectedId: Int?, onPick: @escaping (AdCategory) -> Void) {
        self.cats = cats
        self.selectedId = selectedId
        self.onPick = onPick
        // Уже выбрана подкатегория — сразу открываем её раздел: обычно меняют на соседнюю.
        let r = AdCatUI.root(of: selectedId, in: cats)
        let start: [Int] = (r != nil && !(r?.children ?? []).isEmpty) ? [r?.stableId ?? 0] : []
        _path = State(initialValue: start)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if AdCatUI.norm(query).isEmpty { rootsGrid } else { searchResults }
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle("Выберите категорию")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск по категориям")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .navigationDestination(for: Int.self) { rootId in
                subcatList(rootId)
            }
        }
        .tint(YMColor.accent)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func pick(_ c: AdCategory) {
        Haptics.selection()
        onPick(c)
        dismiss()
    }

    // MARK: Разделы — плитки

    private var rootsGrid: some View {
        let selectedRoot = AdCatUI.root(of: selectedId, in: cats)?.stableId
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: YMSpace.md)], spacing: YMSpace.md) {
                ForEach(Array(cats.enumerated()), id: \.element.stableId) { pair in
                    rootTile(pair.element, index: pair.offset, selected: pair.element.stableId == selectedRoot)
                }
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxl)
        }
    }

    private func rootTile(_ root: AdCategory, index: Int, selected: Bool) -> some View {
        let tint = AdCatUI.tint(index)
        let kids = root.children ?? []
        let caption = kids.isEmpty ? AdCatUI.priceText(root) : AdCatUI.subcatCount(kids.count)
        return Button {
            if kids.isEmpty { pick(root) } else { Haptics.selection(); path.append(root.stableId) }
        } label: {
            VStack(alignment: .leading, spacing: YMSpace.sm) {
                Image(systemName: adCategorySymbol(root.icon, root.name ?? ""))
                    .ymIcon(22, weight: .semibold)
                    .foregroundStyle(tint)
                    .frame(width: 48, height: 48)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(root.name ?? "")
                    .font(YMFont.headline)
                    .foregroundStyle(YMColor.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(caption)
                    .font(YMFont.caption)
                    .foregroundStyle(YMColor.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
            .padding(YMSpace.md)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                    .strokeBorder(selected ? YMColor.accent : YMColor.hairline, lineWidth: selected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selected ? "\(root.name ?? ""), выбрано" : (root.name ?? ""))
    }

    // MARK: Подкатегории раздела

    private func subcatList(_ rootId: Int) -> some View {
        let index = cats.firstIndex { $0.stableId == rootId } ?? 0
        let root = cats.first { $0.stableId == rootId }
        let symbol = adCategorySymbol(root?.icon, root?.name ?? "")
        return ScrollView {
            LazyVStack(spacing: YMSpace.sm) {
                ForEach(root?.children ?? [], id: \.stableId) { leaf in
                    row(title: Text(leaf.name ?? ""), subtitle: AdCatUI.priceText(leaf), symbol: symbol,
                        tint: AdCatUI.tint(index), selected: leaf.stableId == selectedId) { pick(leaf) }
                }
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.vertical, YMSpace.sm)
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle(root?.name ?? "Категория")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Поиск

    private struct Hit: Identifiable {
        let leaf: AdCategory
        let root: AdCategory?
        let index: Int
        var id: Int { leaf.stableId }
    }

    private var hits: [Hit] {
        let q = AdCatUI.norm(query)
        var out: [Hit] = []
        for (i, root) in cats.enumerated() {
            let kids = root.children ?? []
            let rootHit = AdCatUI.norm(root.name ?? "").contains(q)
            if kids.isEmpty {
                if rootHit { out.append(Hit(leaf: root, root: nil, index: i)) }
            } else {
                for k in kids where rootHit || AdCatUI.norm(k.name ?? "").contains(q) {
                    out.append(Hit(leaf: k, root: root, index: i))
                }
            }
        }
        // Сначала начинающиеся с запроса, затем содержащие, затем найденные по разделу.
        func rank(_ h: Hit) -> Int {
            let n = AdCatUI.norm(h.leaf.name ?? "")
            if n.hasPrefix(q) { return 0 }
            return n.contains(q) ? 1 : 2
        }
        return out.enumerated()
            .sorted { a, b in rank(a.element) == rank(b.element) ? a.offset < b.offset : rank(a.element) < rank(b.element) }
            .map { $0.element }
    }

    @ViewBuilder
    private var searchResults: some View {
        let list = hits
        if list.isEmpty {
            VStack(spacing: YMSpace.sm) {
                Image(systemName: "magnifyingglass")
                    .ymIcon(36, weight: .regular)
                    .foregroundStyle(YMColor.muted)
                Text("Ничего не нашлось").font(YMFont.headline).foregroundStyle(YMColor.text)
                Text("Попробуйте другое слово или выберите раздел из списка.")
                    .font(YMFont.callout).foregroundStyle(YMColor.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.xxxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView {
                LazyVStack(spacing: YMSpace.sm) {
                    ForEach(list) { h in
                        let owner = h.root ?? h.leaf
                        let sub = h.root.map { "\($0.name ?? "") · \(AdCatUI.priceText(h.leaf))" } ?? AdCatUI.priceText(h.leaf)
                        row(title: Text(highlight(h.leaf.name ?? "")), subtitle: sub,
                            symbol: adCategorySymbol(owner.icon, owner.name ?? ""),
                            tint: AdCatUI.tint(h.index), selected: h.leaf.stableId == selectedId) { pick(h.leaf) }
                    }
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.vertical, YMSpace.sm)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    /// Подсветка найденного куска (без учёта регистра и «ё»).
    private func highlight(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        let q = AdCatUI.norm(query)
        guard !q.isEmpty else { return a }
        let lower = AdCatUI.norm(text)
        guard let r = lower.range(of: q) else { return a }
        let start = lower.distance(from: lower.startIndex, to: r.lowerBound)
        let len = lower.distance(from: r.lowerBound, to: r.upperBound)
        guard start + len <= text.count else { return a }
        let s = a.index(a.startIndex, offsetByCharacters: start)
        let e = a.index(s, offsetByCharacters: len)
        a[s..<e].foregroundColor = YMColor.accent
        a[s..<e].font = YMFont.styled(.body, .bold)
        return a
    }

    private func row(title: Text, subtitle: String, symbol: String, tint: Color, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: YMSpace.md) {
                Image(systemName: symbol)
                    .ymIcon(16, weight: .semibold)
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    title
                        .font(YMFont.styled(.body, .semibold))
                        .foregroundStyle(YMColor.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(YMFont.caption)
                        .foregroundStyle(YMColor.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark" : "chevron.right")
                    .ymIcon(13, weight: .semibold)
                    .foregroundStyle(selected ? YMColor.accent : YMColor.muted)
            }
            .padding(.horizontal, YMSpace.md)
            .padding(.vertical, 10)
            .frame(minHeight: 60)
            .background(selected ? YMColor.accent.opacity(0.10) : YMColor.surface,
                        in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                    .strokeBorder(selected ? YMColor.accent : YMColor.hairline, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
