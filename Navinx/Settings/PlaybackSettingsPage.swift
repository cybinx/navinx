import PlaybackKit
import SwiftUI

/// Flutter `SettingsPlaybackTab`: Auto DJ, crossfade, gapless, fade in/out, ReplayGain and the
/// streaming quality, in Flutter's order, with Resume Across Devices (C36) after gapless. Flutter's
/// lyrics lookup switch is gone: lyrics come only from the user's own server (D199).
struct PlaybackSettingsPage: View {
    @Environment(PlayerModel.self) private var player

    @AppStorage(ReplayGainSettings.modeKey) private var gainChoice = ReplayGainSettings.Mode.off.rawValue
    @AppStorage(ReplayGainSettings.preampKey) private var preamp = 0.0
    @AppStorage(ReplayGainSettings.preventsClippingKey) private var preventsClipping = true
    @AppStorage(ReplayGainSettings.fallbackKey) private var fallbackGain = -6.0
    @AppStorage(TranscodingSettings.enabledKey) private var transcodes = false
    @AppStorage(TranscodingSettings.wifiBitRateKey) private var wifiBitRate = 0
    @AppStorage(TranscodingSettings.mobileBitRateKey) private var mobileBitRate = 192
    @AppStorage(TranscodingSettings.formatKey) private var format = "mp3"
    @AppStorage(CrossfadeSettings.secondsKey) private var crossfadeSeconds = 0
    @AppStorage(FadeSettings.enabledKey) private var fades = false
    @AppStorage(FadeSettings.durationKey) private var fadeLengthMs = 300
    @AppStorage(RefillSettings.refillCountKey) private var refillCountChoice = 5
    @AppStorage(QueueSyncSettings.enabledKey) private var resumesAcrossDevices = true

    var body: some View {
        VStack(spacing: 24) {
            refillSection
            crossfade
            SettingsSection(title: "GAPLESS PLAYBACK") {
                SettingsSwitchRow(
                    title: "Gapless Playback",
                    subtitle: "Eliminate silence between songs",
                    isOn: Binding(get: { player.isGaplessEnabled }, set: { _ in player.toggleGapless() })
                ) { SettingsGlyph.accent("arrow.forward.to.line") }
            }
            // Not in Flutter (C36, D143): the queue kept on the server for the user's other devices.
            SettingsSection(title: "RESUME ACROSS DEVICES") {
                SettingsSwitchRow(
                    title: "Resume Across Devices",
                    subtitle: "Pick up your queue where you left off on another device",
                    isOn: $resumesAcrossDevices
                ) { SettingsGlyph.accent("laptopcomputer.and.iphone") }
            }
            fade
            replayGain
            streamingQuality
        }
        .onChange(of: [preamp, fallbackGain]) { player.reapplyReplayGain() }
        .onChange(of: gainChoice) { player.reapplyReplayGain() }
        .onChange(of: preventsClipping) { player.reapplyReplayGain() }
        .onChange(of: [wifiBitRate, mobileBitRate]) { player.refreshTranscoding() }
        .onChange(of: transcodes) { player.refreshTranscoding() }
        .onChange(of: format) { player.refreshTranscoding() }
        .onChange(of: crossfadeSeconds) { player.refreshCrossfade() }
    }

    /// Flutter's AUTO DJ section (C21), "AUTOPLAY" since D210: the mode as a system menu, and how many
    /// songs it adds when on.
    /// Flutter's mode descriptions were never shown, nor are they here.
    private var refillSection: some View {
        SettingsSection(title: "AUTOPLAY") {
            SettingsRow(title: "Autoplay") {
                SettingsGlyph("infinity", colors: gradient(0xFF2D55, 0xFF6B6B))
            } trailing: {
                SettingsMenuPicker(
                    title: "Autoplay",
                    selection: Binding(get: { player.refillSource }, set: { player.setRefillSource($0) }),
                    options: RefillSource.allCases,
                    identifier: "Auto DJ Mode menu"
                ) { $0.label }
            }
            if player.isRefillOn {
                SettingsRule()
                SettingsSliderRow(
                    title: "Songs to Add: \(refillCountChoice)",
                    value: Binding(
                        get: { Double(refillCountChoice) },
                        set: { refillCountChoice = Int($0.rounded()) }
                    ),
                    range: 1...20,
                    step: 1,
                    identifier: "refillCountChoice",
                    badge: SettingsGlyph("text.badge.plus", colors: gradient(0x5856D6, 0x7B68EE))
                )
            }
        }
    }

    /// Flutter's `_buildCrossfadeSection`: the row with its badge, then the slider and its three marks.
    private var crossfade: some View {
        SettingsSection(title: "CROSSFADE") {
            SettingsRow(
                title: "Crossfade",
                subtitle: crossfadeSeconds == 0
                    ? "Off (Instant transition)"
                    : "\(CountText.of(crossfadeSeconds, "second")) crossfade between songs"
            ) {
                SettingsGlyph.accent("arrow.triangle.merge")
            } trailing: {
                Text(crossfadeSeconds == 0 ? "Off" : "\(crossfadeSeconds)s")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Palette.accent)
                    .monospacedDigit()
                    .fixedSize()
                    .accessibilityIdentifier("crossfadeBadge")
            }
            VStack(spacing: 2) {
                SteppedSlider(
                    value: Binding(
                        get: { Double(crossfadeSeconds) },
                        set: { crossfadeSeconds = Int($0.rounded()) }
                    ),
                    in: 0...12,
                    step: 1
                )
                .accessibilityIdentifier("crossfadeSlider")
                .accessibilityValue(crossfadeSeconds == 0 ? "Off" : CountText.of(crossfadeSeconds, "second"))
                HStack {
                    Text("Off")
                    Spacer()
                    Text("6s")
                    Spacer()
                    Text("12s")
                }
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.38))
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// Flutter's `_buildFadeSection`: the switch, and the duration's slider (50 ms steps) only when on.
    private var fade: some View {
        SettingsSection(title: "FADES") {
            SettingsSwitchRow(
                title: "Fade on Play and Pause",
                subtitle: "Smoothly fade audio when playing or pausing",
                isOn: $fades
            ) { SettingsGlyph.accent("playpause") }
            if fades {
                SettingsRule()
                SettingsSliderRow(
                    title: "Fade Duration: \(fadeLengthMs)ms",
                    value: Binding(
                        get: { Double(fadeLengthMs) },
                        set: { fadeLengthMs = Int($0.rounded()) }
                    ),
                    range: 100...1000,
                    step: 50,
                    identifier: "fadeDuration"
                )
            }
        }
    }

    private var replayGain: some View {
        SettingsSection(title: "VOLUME LEVELING") {
            SettingsRow(title: "Mode") {
                SettingsGlyph("slider.vertical.3", colors: gradient(0x34C759, 0x30D158))
            } trailing: {
                SettingsMenuPicker(
                    title: "Mode",
                    selection: $gainChoice,
                    options: ReplayGainSettings.Mode.allCases.map(\.rawValue)
                ) { ["Off", "Track", "Album"][$0] }
            }
            if gainChoice != ReplayGainSettings.Mode.off.rawValue {
                SettingsRule()
                SettingsSliderRow(
                    title: "Preamp: \(SettingsFormat.decibels(preamp)) dB",
                    value: $preamp,
                    range: -12...12,
                    identifier: "replayGainPreamp"
                )
                SettingsRule()
                SettingsSwitchRow(title: "Prevent Clipping", isOn: $preventsClipping)
                SettingsRule()
                SettingsSliderRow(
                    title: "Fallback Gain: \(SettingsFormat.decibels(fallbackGain)) dB",
                    value: $fallbackGain,
                    range: -12...0,
                    identifier: "replayGainFallback"
                )
            }
        }
    }

    /// Flutter's `_buildTranscodingSection`, always choosing by connection (D66): no Smart switch,
    /// and so no "Detected network" line.
    private var streamingQuality: some View {
        SettingsSection(title: "STREAMING") {
            SettingsSwitchRow(
                title: "Adjust Streaming Quality",
                subtitle: "Reduce data usage with lower quality",
                isOn: $transcodes
            ) { SettingsGlyph("gauge.with.dots.needle.33percent", colors: gradient(0xFF9500, 0xFF3B30)) }
            if transcodes {
                SettingsRule()
                SettingsRow(title: "Wi-Fi Quality", subtitle: "Used automatically on Wi-Fi") {
                    plainIcon("wifi.router")
                } trailing: {
                    bitRatePicker("Wi-Fi Quality", selection: $wifiBitRate)
                }
                SettingsRule()
                SettingsRow(title: "Mobile Quality", subtitle: "Used automatically on cellular data") {
                    plainIcon("antenna.radiowaves.left.and.right")
                } trailing: {
                    bitRatePicker("Mobile Quality", selection: $mobileBitRate)
                }
                SettingsRule()
                SettingsRow(title: "Format", subtitle: "Audio codec used for streaming") {
                    plainIcon("doc.badge.gearshape")
                } trailing: {
                    SettingsMenuPicker(title: "Format", selection: $format, options: TranscodingSettings.formats) {
                        $0 == "raw" ? "Original" : $0.uppercased()
                    }
                }
            }
        }
    }

    private func bitRatePicker(_ title: String, selection: Binding<Int>) -> some View {
        SettingsMenuPicker(
            title: title,
            selection: selection,
            options: TranscodingSettings.bitRates,
            label: { $0 == 0 ? "Original (No Transcoding)" : "\($0) kbps" },
            shortLabel: { $0 == 0 ? "Original" : "\($0) kbps" }
        )
    }

    /// Flutter's plain 20 pt icons on the quality rows, in a badge-wide frame so the titles line up.
    private func plainIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 17))
            .foregroundStyle(.primary)
            .frame(width: 32)
            .accessibilityHidden(true)
    }
}
