import SwiftUI

// The app's own glass (C26, D105 (2); simplified in C30, D122). Every piece of glass the app draws itself
// goes through `.appGlass(…)` / `.appGlassButtonStyle()`, so it has one look in one place: the system's
// `.regular` glass, as C26's default (the middle stop of the Glass slider, which C30 removed: the user
// chose removal once told it only reached the app's own glass, D122). D77's two pills stay `.clear`.
// The system's own glass (the tab bar and its mini-player, the top bars' buttons, menus, sheets,
// alerts) is Apple's and isn't touched.

extension View {
    /// The app's own glass. Use it in place of `glassEffect(.regular…)`. A surface with its own colour
    /// (`tint`) keeps it; `staysClear` is for the two pills that are clear on purpose (D77).
    func appGlass(
        in shape: some Shape = .capsule,
        interactive: Bool = false,
        tint: Color? = nil,
        staysClear: Bool = false
    ) -> some View {
        glassEffect(AppGlass.glass(tint: tint, interactive: interactive, staysClear: staysClear), in: shape)
    }

    /// The app's own glass button style: `.buttonStyle(.glass)` with the app's glass.
    func appGlassButtonStyle() -> some View {
        buttonStyle(.glass(AppGlass.glass()))
    }
}

/// The one glass the app draws itself.
nonisolated enum AppGlass {
    static func glass(tint: Color? = nil, interactive: Bool = false, staysClear: Bool = false) -> Glass {
        var glass: Glass = staysClear ? .clear : .regular
        if let tint { glass = glass.tint(tint) }
        return interactive ? glass.interactive() : glass
    }
}
