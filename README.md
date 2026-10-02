# Paladala

A native SwiftUI client for Bilibili on iOS. Fast two-column feed, AVPlayer-based playback
through a local HLS proxy, danmaku, SponsorBlock, offline downloads, live rooms, bangumi,
and a small plugin system.

## Repository layout

| Path | What it is |
|---|---|
| `ios/Paladala` | The iOS app (SwiftUI, AVPlayer + `LocalHLSProxyServer`) |
| `portal/` | Cloudflare Worker + Astro diagnostics portal (error reports from the app) |
| `landing-page/` | Marketing site (Vite + React, deployed on Vercel) |
| `intro-deck/` | Slide deck source |
| `scripts/` | API probes and release helpers |
| `docs/` | Design specs, AltStore source, sideloading guide, revival plan |

## Install

Unsigned IPAs are published as prereleases on the Releases page and through an AltStore /
SideStore source: see [docs/altstore-source.md](docs/altstore-source.md).
Need unlimited sideloading? See [docs/sideload.md](docs/sideload.md).

## Build

Requires Xcode 16+ and iOS 18+ SDK.

```bash
open ios/Paladala/Paladala.xcodeproj
```

No third-party native dependencies. Copy `ios/Paladala/Config/Opspad.xcconfig.example` to
`Opspad.Debug.xcconfig` / `Opspad.Release.xcconfig` to enable the portal reporter (optional).

## Direction

See [docs/revival/PLAN.md](docs/revival/PLAN.md) for the roadmap and interface redesign.
Playback stays on AVPlayer; IJKPlayer/FFmpeg work is parked on the
`parked/ijkplayer-ffmpeg` branch.

## License

See [LICENSE](LICENSE).
