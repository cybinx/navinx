import SwiftUI

/// Flutter `SettingsSectionCard` (`lib/widgets/settings/`): a grey header, then a rounded card.
/// Rows are separated by `SettingsRule`s, as in Flutter.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 13))
                .tracking(0.2)
                .foregroundStyle(Palette.secondaryText)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content }
                .background(Palette.surface)
                .clipShape(.rect(cornerRadius: 12))
                .padding(.horizontal, 16)
        }
    }
}

/// Flutter `SettingsDivider`: 0.5 pt, indented 56 pt.
struct SettingsRule: View {
    var indent: CGFloat = 56

    var body: some View {
        Rectangle()
            .fill(Palette.divider)
            .frame(height: 0.5)
            .padding(.leading, indent)
    }
}

/// Flutter `SettingsIconBadge`: a 32 pt gradient square with a white glyph and a soft shadow.
struct SettingsGlyph: View {
    let systemImage: String
    let colors: [Color]

    init(_ systemImage: String, colors: [Color]) {
        self.systemImage = systemImage
        self.colors = colors
    }

    /// The accent's own gradient, as Flutter's `[accent, accent.withValues(alpha: 0.6)]`.
    static func accent(_ systemImage: String) -> SettingsGlyph {
        SettingsGlyph(systemImage, colors: [Palette.accent, Palette.accent.opacity(0.6)])
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 32, height: 32)
            .shadow(color: (colors.first ?? .clear).opacity(0.25), radius: 3, y: 2)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// A Flutter colour pair as a gradient.
func gradient(_ first: UInt32, _ second: UInt32) -> [Color] {
    [Color(hex: first), Color(hex: second)]
}

/// Flutter `SettingsListTile`: a badge (or a plain icon), the title and subtitle, and whatever goes
/// on the trailing side. Tappable when it has an action.
struct SettingsRow<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    var titleColor: Color = .primary
    var action: (() -> Void)?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        if let action {
            Button(action: action) { content.contentShape(.rect) }
                .buttonStyle(SettingsRowButtonStyle())
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 16) {
            leading
            SettingsLabels(title: title, subtitle: subtitle, titleColor: titleColor)
                .layoutPriority(1)
            Spacer(minLength: 0)
            trailing
                .font(.system(size: 16))
                .foregroundStyle(Palette.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 48)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        titleColor: Color = .primary,
        action: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading
    ) {
        self.init(title: title, subtitle: subtitle, titleColor: titleColor, action: action, leading: leading, trailing: { EmptyView() })
    }
}

/// The row's title (16 pt) and subtitle (13 pt, grey).
struct SettingsLabels: View {
    let title: String
    var subtitle: String?
    var titleColor: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(titleColor)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Flutter `SettingsSwitchTile`: the whole row flips the switch, which is the system's (glass).
struct SettingsSwitchRow<Leading: View>: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var identifier: String?
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: 16) {
            leading
            Toggle(isOn: $isOn) {
                SettingsLabels(title: title, subtitle: subtitle)
            }
            .accessibilityIdentifier(identifier ?? title)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 48)
        .contentShape(.rect)
        .onTapGesture { isOn.toggle() }
    }
}

extension SettingsSwitchRow where Leading == EmptyView {
    init(title: String, subtitle: String? = nil, isOn: Binding<Bool>, identifier: String? = nil) {
        self.init(title: title, subtitle: subtitle, isOn: isOn, identifier: identifier, leading: { EmptyView() })
    }
}

/// A choice opened as a menu next to its row (D30, D63): the system's menu, with a tick on the
/// current choice, and the choice's short name on the row. Flutter used a dropdown.
struct SettingsMenuPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    /// The menu's accessibility identifier, when it must outlive a renamed title ("Auto DJ Mode menu", D210).
    var identifier: String?
    let label: (Value) -> String
    /// The row's shorter text, where the menu's would crowd the title.
    var shortLabel: ((Value) -> String)?

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text((shortLabel ?? label)(selection))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
            }
            .font(.system(size: 16))
            .foregroundStyle(Palette.accent)
            .lineLimit(1)
        }
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(label(selection))
        .accessibilityIdentifier(identifier ?? "\(title) menu")
    }
}

/// A slider with fixed stops (C30 bug 10): the thumb glides under the finger, the setting follows the
/// nearest stop as it moves, and on release the thumb animates to that stop.
struct SteppedSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1

    /// Where the finger has the thumb while dragging; nil at rest, when the thumb sits on `value`.
    @State private var dragValue: Double?

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1) {
        _value = value
        self.range = range
        self.step = step
    }

    /// The stop nearest `raw`, inside the range.
    nonisolated static func snap(_ raw: Double, in range: ClosedRange<Double>, step: Double) -> Double {
        guard step > 0 else { return min(max(raw, range.lowerBound), range.upperBound) }
        let stops = ((raw - range.lowerBound) / step).rounded()
        return min(max(range.lowerBound + stops * step, range.lowerBound), range.upperBound)
    }

    var body: some View {
        Slider(
            value: Binding(
                get: { dragValue ?? value },
                set: { raw in
                    dragValue = raw
                    let stop = Self.snap(raw, in: range, step: step)
                    if stop != value { value = stop }
                }
            ),
            in: range,
            onEditingChanged: { editing in
                if !editing { withAnimation(.snappy(duration: 0.25)) { dragValue = nil } }
            }
        )
    }
}

/// Flutter's slider rows (`ListTile` with a `Slider` as its subtitle): "Preamp: 0.0 dB".
struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var identifier: String
    /// Flutter's `leading` badge, where the row has one (Auto DJ's "Songs to Add").
    var badge: SettingsGlyph?

    var body: some View {
        HStack(spacing: 16) {
            badge
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16))
                    .monospacedDigit()
                SteppedSlider(value: $value, in: range, step: step)
                    .accessibilityIdentifier(identifier)
                    .accessibilityValue(title)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Highlights a row while it's pressed, as Flutter's `InkWell` does.
struct SettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Palette.divider.opacity(0.5) : .clear)
    }
}

/// Flutter `CacheSettingsService.formatBytes`: binary units, one decimal under 10.
nonisolated enum SettingsFormat {
    static func bytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let suffixes = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < suffixes.count - 1 {
            value /= 1024
            index += 1
        }
        let digits = value < 10 && index > 0 ? 1 : 0
        return String(format: "%.\(digits)f %@", value, suffixes[index])
    }

    /// Flutter `songsCount`: "No songs", "1 song", "N songs".
    static func songs(_ count: Int) -> String {
        switch count {
        case 0: "No songs"
        case 1: "1 song"
        default: "\(count) songs"
        }
    }

    /// Flutter `playlistSongsDownloadedCount`.
    static func songsDownloaded(_ count: Int) -> String {
        count == 1 ? "1 song downloaded" : "\(count) songs downloaded"
    }

    /// "0.0 dB", as Flutter's `toStringAsFixed(1)`.
    static func decibels(_ value: Double) -> String {
        String(format: "%.1f", value == 0 ? 0 : value)
    }
}
