import HubKit
import SwiftUI
import UIKit

// The fixed set of parts the server's screens are built from (schema v1, `docs/log/C27.md`), drawn
// as today's Add tab drew them (D30, D67, D72, D77). Every text comes from the server; accessibility
// identifiers are `hub-<id>`, built from the server's ids at run time.

/// A section's parts, top to bottom. Consecutive buttons share a line; consecutive rows have no gap.
struct HubPartsView: View {
    let parts: [HubPart]
    let page: HubPage

    private enum Item {
        case part(HubPart)
        case buttons([HubButton])

        var isRow: Bool { if case .part(.row) = self { true } else { false } }
        var gap: Double? {
            switch self {
            case .part(let part): part.gap
            case .buttons(let buttons): buttons.first?.gap
            }
        }
    }

    private var items: [Item] {
        var items: [Item] = []
        for part in parts {
            if case .button(let button) = part {
                if case .buttons(let line) = items.last {
                    items[items.count - 1] = .buttons(line + [button])
                } else {
                    items.append(.buttons([button]))
                }
            } else {
                items.append(.part(part))
            }
        }
        return items
    }

    var body: some View {
        let items = items
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                itemView(item).padding(.top, gap(at: index, in: items))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gap(at index: Int, in items: [Item]) -> CGFloat {
        guard index > 0 else { return 0 }
        let item = items[index]
        if item.isRow, items[index - 1].isRow { return 0 }
        return item.gap ?? 8
    }

    @ViewBuilder private func itemView(_ item: Item) -> some View {
        switch item {
        case .buttons(let buttons):
            HStack(spacing: 10) {
                ForEach(buttons.indices, id: \.self) { HubButtonView(button: buttons[$0], page: page) }
            }
        case .part(let part):
            switch part {
            case .text(let text): HubTextView(part: text, page: page)
            case .field(let field): HubFieldView(part: field, page: page)
            case .choice(let choice): HubChoiceView(part: choice, page: page)
            case .button(let button): HubButtonView(button: button, page: page)
            case .row(let row): HubRowView(part: row, page: page)
            case .progress(let progress): HubProgressView(part: progress)
            case .image(let image): HubImageView(part: image, page: page)
            }
        }
    }
}

extension HubTint {
    var color: Color {
        switch self {
        case .accent: Palette.accent
        case .secondary: Palette.secondaryText
        case .red: .red
        case .orange: Palette.orange
        case .green: Palette.green
        }
    }
}

extension View {
    /// `hub-<id>`, when the server gave an id.
    @ViewBuilder
    func hubIdentifier(_ id: String?) -> some View {
        if let id { accessibilityIdentifier("hub-\(id)") } else { self }
    }
}

// MARK: - Text

struct HubTextView: View {
    let part: HubText
    let page: HubPage

    private var size: CGFloat {
        switch part.style {
        case .headline, .body: 16
        case .subhead, .strong, .secondary: 14
        case .caption: 12
        }
    }

    private var weight: Font.Weight {
        switch part.style {
        case .headline: .bold
        case .strong: .semibold
        default: .regular
        }
    }

    /// The text's colour: the tint when there's no symbol to carry it, else the style's.
    private var color: Color {
        if part.symbol == nil, let tint = part.tint { return tint.color }
        return part.style == .secondary || part.style == .caption ? Palette.secondaryText : .primary
    }

    var body: some View {
        if part.align == .center {
            centred
        } else if let label = part.label {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(label)
                    .font(.system(size: size))
                    .foregroundStyle(Palette.secondaryText)
                    .frame(width: part.labelWidth ?? 64, alignment: .leading)
                text
            }
            .accessibilityElement(children: .combine)
            .hubIdentifier(part.id)
        } else if part.symbol != nil || part.button != nil {
            HStack(alignment: .top, spacing: 8) {
                symbol(size: size >= 16 ? 20 : 16)
                text.frame(maxWidth: .infinity, alignment: .leading)
                if let button = part.button {
                    HubButtonView(button: button, page: page)
                }
            }
            .accessibilityElement(children: .contain)
            .hubIdentifier(part.id)
        } else {
            text.hubIdentifier(part.id)
        }
    }

    private var text: some View {
        Text(part.text)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .lineLimit(part.lines)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func symbol(size: CGFloat) -> some View {
        if let name = part.symbol {
            Image(systemName: name)
                .font(.system(size: size))
                .foregroundStyle(part.tint?.color ?? color)
                .accessibilityHidden(true)
        }
    }

    /// A hint or an empty state: centred, with its symbol above it.
    @ViewBuilder private var centred: some View {
        if part.symbol != nil {
            VStack(spacing: 12) {
                symbol(size: 34)
                text.multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .hubIdentifier(part.id)
        } else {
            text
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .padding(.horizontal, 8)
                .hubIdentifier(part.id)
        }
    }
}

// MARK: - Field

struct HubFieldView: View {
    let part: HubField
    let page: HubPage
    @Environment(HubModel.self) private var model
    @FocusState private var focused: Bool

    private var text: Binding<String> {
        Binding(get: { page.text(part.id) }, set: { page.texts[part.id] = $0 })
    }

    private var trimmed: String { page.text(part.id).trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                TextField(
                    part.label ?? part.placeholder, text: text,
                    prompt: Text(part.placeholder).foregroundStyle(Palette.secondaryText)
                )
                .font(.system(size: 17))
                .focused($focused)
                .keyboardType(part.keyboard == .url ? .URL : .default)
                .textContentType(part.keyboard == .url ? .URL : nil)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(part.returnKey == .search ? .search : .go)
                .onSubmit(submit)
                .hubIdentifier(part.id)
                if !page.text(part.id).isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill", action: clear)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 17))
                        .foregroundStyle(Palette.secondaryText)
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(focused ? Palette.accent : Color.primary.opacity(0.8), lineWidth: focused ? 2 : 1)
            }
            .contentShape(.rect)
            .onTapGesture { focused = true }

            if part.paste {
                HStack {
                    // The system's paste control: it reads the clipboard without iOS's "Allow Paste"
                    // question on every tap (D67). Its wording is the system's.
                    PasteButton(payloadType: String.self) { strings in
                        guard let pasted = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !pasted.isEmpty else { return }
                        page.texts[part.id] = pasted
                    }
                    .buttonBorderShape(.capsule)
                    .tint(Palette.accent)
                    .hubIdentifier("\(part.id)-paste")
                    Spacer(minLength: 10)
                    if let button = part.button {
                        HubButtonView(button: button, page: page, before: { focused = false })
                    }
                }
            } else if let button = part.button {
                HStack {
                    Spacer(minLength: 10)
                    HubButtonView(button: button, page: page, before: { focused = false })
                }
            }
        }
    }

    private func submit() {
        // The post is refused while another action is on its way: then nothing changes here.
        guard let action = part.submit, !trimmed.isEmpty, !page.isSending else { return }
        focused = false
        Task { await model.post(action, from: page, control: part.button?.id ?? action.id) }
    }

    private func clear() {
        guard let action = part.clear else {
            page.texts[part.id] = ""
            return
        }
        // Refused while another action is on its way: keep the text, it wasn't cleared on the server.
        guard !page.isSending else { return }
        let before = page.text(part.id)
        page.texts[part.id] = ""
        Task {
            if await !model.post(action, from: page), page.text(part.id).isEmpty { page.texts[part.id] = before }
        }
    }
}

// MARK: - Choice

struct HubChoiceView: View {
    let part: HubChoice
    let page: HubPage
    @Environment(HubModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Picker(selection: Binding(
                get: { page.value(of: part) },
                set: { option in Task { await model.pick(option, in: part, on: page) } }
            )) {
                ForEach(part.options) { Text($0.label).tag($0.id) }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(part.large ? .large : .regular)
            .hubIdentifier(part.id)
            if let button = part.button {
                HubButtonView(button: button, page: page)
            }
        }
    }
}

// MARK: - Buttons

/// A button posting its action; a spinner while the server works on it or its post is on its way.
struct HubButtonView: View {
    let button: HubButton
    let page: HubPage
    /// Runs before the post (a field's button closes the keyboard).
    var before: () -> Void = {}
    @Environment(HubModel.self) private var model

    private var control: String { button.id ?? button.action.id }
    private var spinning: Bool { button.busy || page.sending == control }
    private var disabled: Bool { !button.enabled || spinning || page.isMissing(button.needs) || page.isSending }

    var body: some View {
        switch button.style {
        case .pill:
            HubPill(button: button, page: page, size: .large)
        case .prominent:
            plain.buttonStyle(.borderedProminent)
        case .bordered:
            plain.buttonStyle(.bordered)
        case .plain:
            plain.buttonStyle(.borderless)
        }
    }

    private var plain: some View {
        Button {
            before()
            Task { await model.post(button.action, from: page, control: control) }
        } label: {
            HStack(spacing: 8) {
                if let symbol = button.symbol {
                    Image(systemName: symbol)
                }
                Text(button.label)
            }
            .opacity(spinning ? 0 : 1)
            .overlay { if spinning { ProgressView().controlSize(.small) } }
        }
        .disabled(disabled)
        .accessibilityLabel(button.label)
        .hubIdentifier(button.id)
    }
}

/// A section title's icon-only button (Requests' refresh).
struct HubIconButton: View {
    let button: HubButton
    let page: HubPage
    @Environment(HubModel.self) private var model

    private var control: String { button.id ?? button.action.id }
    private var spinning: Bool { button.busy || page.sending == control }

    var body: some View {
        Button(button.label, systemImage: button.symbol ?? HubSymbol.fallback) {
            Task { await model.post(button.action, from: page, control: control) }
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 18))
        .buttonStyle(.borderless)
        .opacity(spinning ? 0 : 1)
        .overlay { if spinning { ProgressView().controlSize(.small) } }
        .disabled(!button.enabled || spinning || page.isSending)
        .hubIdentifier(button.id)
    }
}

/// The clear-glass capsule with black text (D77): on a picture (large) or on a row's cover (small).
struct HubPill: View {
    enum Size { case large, small(width: CGFloat) }

    let button: HubButton
    let page: HubPage
    let size: Size
    /// Read out after the label (the row's title).
    var hint: String?
    @Environment(HubModel.self) private var model

    private var control: String { button.id ?? button.action.id }
    private var spinning: Bool { button.busy || page.sending == control }
    private var tappable: Bool { button.enabled && !spinning && !page.isSending && !page.isMissing(button.needs) }

    var body: some View {
        Button {
            Task { await model.post(button.action, from: page, control: control) }
        } label: {
            label
                // Dark on the clear glass, always (D77): a plain colour, since glass lightens `.primary`.
                .foregroundStyle(.black)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .appGlass(in: .capsule, interactive: tappable, staysClear: true)
        .allowsHitTesting(tappable)
        .accessibilityLabel(button.label)
        .accessibilityHint(hint ?? "")
        .hubIdentifier(button.id)
    }

    @ViewBuilder private var label: some View {
        switch size {
        case .large:
            ZStack {
                Text(button.label)
                    .font(.system(size: 14, weight: .bold))
                    .opacity(spinning ? 0 : 1)
                if spinning {
                    ProgressView().tint(.black).frame(width: 22, height: 22)
                }
            }
            .frame(height: 44)
            .padding(.horizontal, 18)
        case .small(let width):
            Group {
                if spinning {
                    ProgressView().controlSize(.small).tint(.black)
                } else {
                    HStack(spacing: 4) {
                        if let symbol = button.symbol {
                            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                        }
                        Text(button.label).font(.system(size: 12, weight: .bold))
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                }
            }
            .padding(.horizontal, 8)
            .frame(width: width, height: 30)
        }
    }
}

// MARK: - Row

struct HubRowView: View {
    let part: HubRow
    let page: HubPage
    @Environment(HubModel.self) private var model

    private var coverSize: CGFloat? { part.imageSize.map { CGFloat($0) } }
    private var big: Bool { (coverSize ?? 0) >= 72 }
    private var pill: HubButton? { part.button?.style == .pill && coverSize != nil ? part.button : nil }
    private var hasStatus: Bool { part.symbol != nil || part.busy }

    var body: some View {
        if let action = part.action {
            Button {
                Task { await model.post(action, from: page, control: part.id ?? action.id) }
            } label: {
                content.contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(page.isSending)
            .accessibilityElement(children: .combine)
            .hubIdentifier(part.id)
        } else if part.button != nil {
            content
                .accessibilityElement(children: .contain)
                .hubIdentifier(part.id)
        } else {
            content
                .accessibilityElement(children: .combine)
                .hubIdentifier(part.id)
        }
    }

    private var content: some View {
        HStack(alignment: pill == nil ? .center : .top, spacing: pill == nil ? 12 : 14) {
            if coverSize == nil, hasStatus {
                status(size: 20).frame(width: 22)
            }
            if let coverSize {
                HubCover(url: part.image.flatMap(URL.init(string:)), size: coverSize)
                    .overlay(alignment: .bottom) {
                        if let pill {
                            HubPill(
                                button: pill, page: page, size: .small(width: max(coverSize - 16, 0)),
                                hint: [part.title, part.subtitle].compactMap { $0 }.joined(separator: ", ")
                            )
                            .padding(.bottom, 6)
                        }
                    }
            }
            texts.frame(maxWidth: .infinity, alignment: .leading)
            if coverSize != nil, hasStatus {
                status(size: 22)
            }
            if let button = part.button, pill == nil {
                HubButtonView(button: button, page: page)
            }
        }
        .padding(.vertical, 8)
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(part.title)
                .font(.system(size: big ? 16 : 14, weight: coverSize == nil ? .semibold : .bold))
                .lineLimit(part.lines ?? 1)
            if let subtitle = part.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: big ? 14 : 12))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(part.lines ?? 1)
                    .padding(.top, pill != nil ? 2 : (coverSize == nil ? 1 : 0))
            }
            if let progress = part.progress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.accent.opacity(0.22))
                        Capsule().fill(Palette.accent).frame(width: geometry.size.width * progress)
                    }
                }
                .frame(height: 4)
                .padding(.top, 6)
            }
            if let note = part.note, !note.isEmpty {
                if let symbol = part.noteSymbol {
                    HStack(spacing: 6) {
                        Image(systemName: symbol)
                            .font(.system(size: 18))
                            .foregroundStyle(part.noteTint?.color ?? .primary)
                        Text(note).font(.system(size: 14))
                    }
                    .padding(.top, 6)
                } else {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(part.noteStyle == .error ? Color.red : Palette.secondaryText)
                        .padding(.top, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func status(size: CGFloat) -> some View {
        Group {
            if part.busy {
                ProgressView().controlSize(.small)
            } else if let symbol = part.symbol {
                Image(systemName: symbol)
                    .font(.system(size: size))
                    .foregroundStyle(part.tint?.color ?? .primary)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Progress and picture

struct HubProgressView: View {
    let part: HubProgress

    var body: some View {
        if let label = part.label {
            VStack(alignment: .leading, spacing: 12) {
                Text(label).font(.system(size: 16, weight: .bold))
                HubProgressBar(value: part.value)
            }
            .accessibilityElement(children: .combine)
            .hubIdentifier(part.id)
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .hubIdentifier(part.id)
        }
    }
}

/// A picture with its pill: it stands outside a card, so the pill's glass isn't glass in glass.
struct HubImageView: View {
    let part: HubImage
    let page: HubPage

    var body: some View {
        HubPicture(url: part.url.flatMap(URL.init(string:)), aspect: CGFloat(part.aspect))
            .overlay(alignment: .bottomTrailing) {
                if let button = part.button {
                    if button.style == .pill {
                        HubPill(button: button, page: page, size: .large).padding(12)
                    } else {
                        HubButtonView(button: button, page: page).padding(12)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .hubIdentifier(part.id)
    }
}
