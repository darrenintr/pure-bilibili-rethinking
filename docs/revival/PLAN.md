# Paladala — Revival Plan & Interface Redesign

Date: 2026-10-02 · Status: proposal (nothing implemented yet)

## 1. Where the project actually stands

Not dead, but stuck. 50 commits since Aug 2026; 24 of the last 25 are `ci:` / `fix(ci):` — the last month went into fighting the IJKPlayer/FFmpeg build, not the product.

| Area | State |
|---|---|
| iOS app (`ios/Paladala`) | ~54k lines SwiftUI, 89 files in one flat target. Feature-rich (feed, player, danmaku, downloads, SponsorBlock, plugins, CDN probing, login, live, bangumi, watch/live-activity). |
| Giants | `LocalHLSProxyServer` 6.2k, `BilibiliAPIClient` 5.5k, `AVPlayerController` 2.6k, `VideoDetailView` 2.4k lines — hard to change safely. |
| Version | Info.plist still `0.5.1 TESTING`, CI ships `0.5.37.337`. Three version sources disagree. |
| Design | Three variants (`classic`, `streetRedesign`, `iosNative`) switched by globals in `PaladalaTheme`; every view pays the branching cost; `DesignModifier` 665 lines. |
| Music | Phase 0 scaffold spec written, Packages (`LyricKit/MusicKit/MusicUI`) never wired. |
| Side projects | `portal/` (Cloudflare diagnostics), `landing-page/`, `intro-deck/`, `experimental/ffmpeg` — each half-owned. |
| Repo hygiene | A 4 MB `.ipa` and `CHANGELOG.md` (317 KB) committed; root `README.md` is an unrelated iLoader/SideStore tutorial; `AboutView.swift.backup`; no tests; 1,600 lines of workflow YAML. |

Root cause of the stall: the player stack decision (AVPlayer + local HLS proxy vs IJKPlayer vs experimental FFmpeg) was never made, so three engines are half-built and CI is the only feedback loop.

## 2. Revival plan

### Phase 0 — Stop the bleeding (2–3 days)
1. **Freeze the engine decision.** Keep AVPlayer + `LocalHLSProxyServer` (it works and ships). Park IJKPlayer and `experimental/ffmpeg` on a branch; delete `ijkplayer-ci.yml` / `ijkplayer-spike.yml` from main. This removes the CI churn.
2. **One version source**: Info.plist reads `MARKETING_VERSION`/build from xcconfig; CI only tags.
3. **Repo cleanup**: remove the `.ipa` (use Releases), `.backup`, `.gitkeep-empty`; move the iLoader tutorial to `docs/sideload.md`; write a real README (what/screens/build/install/AltStore).
4. **Trim release notes** to auto-generated GitHub Releases; keep one `CHANGELOG.md` header-per-minor.

### Phase 1 — Make it safe to change (1–2 weeks)
1. Add a Swift Package `PaladalaCore` (models, API client, auth) with unit tests for signing, WBI, parsing, comment pipeline. Add a `swift test` + `xcodebuild build` PR check (macOS runner) — fast, no FFmpeg.
2. Split the giants along existing seams: `BilibiliAPIClient` → per-domain files (Feed, Video, Auth, Live, Relation); `VideoDetailView` → Player area / Info / Comments / Related.
3. Delete `classic` variant fully; collapse to **one** design system (below).
4. Wire the music packages or delete Music (decide with usage data from the portal).

### Phase 2 — Redesign (3–4 weeks, §3)
Ship behind a `Design v2` flag in onboarding/settings, then remove v1 after one release.

### Phase 3 — Reasons to come back (ongoing)
- Offline-first: downloads + prefetch cache surfaced as a first-class "Library".
- Picture-in-picture, background audio, Shortcuts/App Intents already exist → promote them in UI.
- Distribution: AltStore source (`docs/altstore-source.md`) as the official channel; landing page points to it.
- Portal: only keep if you read it weekly; otherwise archive and keep Telegram reporter.

### Milestones
| Release | Content |
|---|---|
| 0.6 | Phase 0 + Phase 1.1–1.2, no visible change |
| 0.7 | New design system + new Home/Player (flagged) |
| 0.8 | Library, Search, Profile redesign; old design removed |
| 1.0 | Stable, tests green, AltStore source live |

## 3. Interface redesign

### Principles
1. **Content first** — video art is the only decoration. Chrome is quiet.
2. **One language** — no variants. Native SwiftUI components, custom tokens only for color, type, spacing, motion.
3. **Thumb-reachable** — primary actions in the bottom 40% of the screen.
4. **Fast-feeling** — skeletons, instant mini-player, no blocking spinners.

### Navigation (5 → 4 tabs + search)
| Tab | Replaces | Contents |
|---|---|---|
| **Discover** | Home + Bangumi + Live | Segmented top: 推薦 · 熱門 · 追番 · 直播. Pull to refresh, feed cache already exists. |
| **Following** | Dynamic | Followed-UP stories row + timeline feed; unread dot. |
| **Library** | Downloads + History + Favorites + Watch later | Segmented; offline items badged; continue-watching rail on top. |
| **Me** | Profile/Settings | Account, coins/VIP chip, settings, plugins, CDN, about. |
| **Search** | `.searchable` in the tab bar (iOS 26 search tab role) | Suggestions, history, trending. |

Music tab is dropped from the bar; if kept it becomes a Library segment ("Audio").

### Visual system
- **Color**: neutral surface (system background / grouped), one accent `biliPink #FF6194` used only for primary actions, live badges, progress. Full dark mode via semantic colors, not inverted hardcoded ink/paper.
- **Shape**: continuous corner radius 14 for cards, 10 for chips, capsule for buttons. No hard borders/shadows (retire "Street" 1.5pt black stroke).
- **Material**: system Liquid Glass for floating bars (tab bar, mini-player, player controls) with a solid fallback for iOS < 26.
- **Type**: SF Pro Dynamic Type only; Title 22/semibold, card title 15/medium 2-line, meta 12/secondary. CJK uses PingFang fallback automatically.
- **Motion**: spring (response 0.35, damping 0.85); matched-geometry cover → player; haptics on like/coin/follow.

### Key screens
1. **Home/Discover card**: 16:9 cover (not 16:10 crop), duration pill bottom-right, UP avatar + name + views on one meta line, `⋯` menu (watch later, download, coin, not interested). Single-column list on iPhone for 推薦 with auto-preview muted on dwell; 2-column toggle in settings; adaptive grid on iPad.
2. **Player**: cover expands to player; collapsed state = mini-player above the tab bar. Fullscreen controls: bottom scrub bar with SponsorBlock segments in accent tint, double-tap seek, long-press 2×, vertical swipe brightness/volume. Danmaku toggle + opacity in one popover. Below player: sticky tabs 简介 · 评论 (count) · 相关.
3. **Comments**: threaded, collapsed replies ("查看 12 則回覆") in a bottom sheet instead of a pushed page.
4. **Library**: continue-watching rail with progress bars; storage meter; swipe to delete.
5. **Me**: header card (avatar, level, coins, VIP), then grouped list; Developer/Plugins/CDN moved under "Advanced".
6. **Onboarding**: 3 screens max (value, sign in optional, pick density), no design picker.

### Implementation order (small, shippable PRs)
1. `DesignSystem` package: tokens (`Color`, `Font`, `Spacing`, `Radius`, `Motion`), `Card`, `Chip`, `PrimaryButton`, `SkeletonView`, `GlassBar`. Previews for light/dark/AX5.
2. New `RootView` with 4 tabs + search, old tabs reachable behind flag.
3. Discover list/card + skeletons.
4. Player chrome + mini-player.
5. Library, Following, Me.
6. Delete variants + `DesignModifier` branching.

## 4. Risks
- No macOS in this environment: all UI changes must be verified through CI/Simulator on your side; keep PRs small.
- `LocalHLSProxyServer` is the real moat and the real fragility; add tests before touching it.
- Using Bilibili private APIs is ToS-grey and can break at any time; keep API layer isolated so fixes are one-file.

## 5. Decisions (confirmed 2026-10-02)
- Stay on AVPlayer; IJKPlayer/FFmpeg parked on `parked/ijkplayer-ffmpeg`.
- Music dropped (views/VM removed; lyric models kept for subtitles).
- Portal kept.
- Default feed: two columns (not single column).

### Originally asked
1. Confirm: park IJKPlayer/FFmpeg and stay on AVPlayer?
2. Keep Music or drop it?
3. Keep the portal/landing page/deck, or archive them?
4. Single-column vs 2-column default feed?
