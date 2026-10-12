# Relay application style

`Sources/Relay/Theme.swift` is the shared visual template for Relay-owned UI.

- Palette: canvas, sidebar, surface, elevated, ink, stroke, selection and accent.
- Typography: `font(size:weight:design:)`, semantic type roles and `typeScale`.
- Layout: `spacingScale`, `cornerScale`, content width and gutters. Existing role proportions are retained.
- Controls: `RelayPrimaryButtonStyle`, `RelaySecondaryButtonStyle`, `RelayQuietButtonStyle`.
- Presentation: `.relaySurface()` provides the inherited palette, body font, tint, control size, background and native appearance.
- Native dialogs: `RelayTheme.alert`, `openPanel`, `savePanel` preserve native behavior while applying the same appearance.

New SwiftUI window or sheet roots use `.relaySurface()`. New custom controls use the shared tokens and button styles. Use `RelayTheme.spacing` and `cornerRadius` for visual constants. The existing `RelayAgentDesign` names delegate to this template; they must not introduce another palette or type scale. `RelayToolSurface.configure` owns window behavior and delegates visual appearance to the template.

Terminal palettes, syntax colors, plots, images and PDF contents belong to the content, not the application frame. System-owned security dialogs and third-party web content retain their native appearance. Changing a style token does not change input ownership, dialog authorization, sessions or transport behavior.

The source migration covers the current native SwiftUI presentation roots, literal view typography, stack/padding spacing, rounded rectangles, and Relay-created AppKit alerts/file panels. Specialized dimensions and component layouts remain local. Changing the template requires rebuilding Relay.
