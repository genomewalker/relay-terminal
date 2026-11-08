# Relay application style

`Sources/Relay/Theme.swift` is the shared visual template for Relay-owned UI.

- Palette: canvas, sidebar, surface, elevated, ink, stroke, selection and accent. Status: `success` (`#73C7A5` dark, system green light) for success/connected; do not reuse accent for success.
- Typography: `font(size:weight:design:)`, `TextRole` (title 17, heading 14, body 13, label 12, callout 11.5, caption 11, micro 10, code 12, codeSmall 11) and `typeScale`. No text below `minimumTextSize` (10 pt); `TextRole.font` clamps to it after `typeScale`, while raw `font(size:)` does not clamp until the existing sub-10 pt call sites are migrated.
- Layout: `Space` tokens `xxs 2, xs 4, sm 6, md 8, lg 12, xl 16, xxl 24`, `spacingScale`, `cornerScale`, content width and gutters. Existing role proportions are retained.
- Control geometry: `Control.height` 28 pt for standard controls; `Control.compactIcon` 22 pt for icon buttons in dense rows.
- Controls: `RelayPrimaryButtonStyle`, `RelaySecondaryButtonStyle`, `RelayQuietButtonStyle`.
- Presentation: `.relaySurface()` provides the inherited palette, body font, tint, control size, background and native appearance.
- Native dialogs: `RelayTheme.alert`, `openPanel`, `savePanel` preserve native behavior while applying the same appearance.

New SwiftUI window or sheet roots use `.relaySurface()`. New custom controls use the shared tokens and button styles. Use `RelayTheme.spacing` and `cornerRadius` for visual constants. The existing `RelayAgentDesign` names delegate to this template; they must not introduce another palette or type scale. `RelayToolSurface.configure` owns window behavior and delegates visual appearance to the template.

Terminal palettes, syntax colors, plots, images and PDF contents belong to the content, not the application frame. System-owned security dialogs and third-party web content retain their native appearance. Changing a style token does not change input ownership, dialog authorization, sessions or transport behavior.

The source migration covers the current native SwiftUI presentation roots, literal view typography, stack/padding spacing, rounded rectangles, and Relay-created AppKit alerts/file panels. Specialized dimensions and component layouts remain local. Changing the template requires rebuilding Relay.
