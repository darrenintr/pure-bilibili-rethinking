# DesignSystem

Design v2 tokens and components for Paladala. iOS 18+, no dependencies.

- `Tokens/` — `DSColor`, `DSSpacing`, `DSRadius`, `DSFont`, `DSMotion`
- `Components/` — `DSVideoCard`, `DSFeedGrid` (two-column adaptive), `DSSkeleton`,
  `DSChip`, `DSPrimaryButtonStyle`, `DSSectionHeader`, `.dsGlassBar()`
- `Support/` — `DSFormat` (播放量 `1.2萬`, durations)

Rules: UI copy is Traditional Chinese (繁體中文), never Simplified; semantic colors only (no hardcoded black/white ink), continuous corners, no
hard borders or offset shadows, Dynamic Type text styles, accent pink only for primary
actions / live / progress. Components never load images themselves: pass a `cover` view.

Previews live in `Components/DSPreviews.swift` (light, dark + skeleton, AX5).
Tests: `xcodebuild test -scheme DesignSystem -destination 'platform=iOS Simulator,name=iPhone 16'`
(also run by the `design-system` workflow).
