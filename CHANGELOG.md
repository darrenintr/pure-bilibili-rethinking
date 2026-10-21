# Changelog

One section per minor version. Per-build notes are published automatically as
[GitHub Releases](https://github.com/darrenintr/pure-bilibili-rethinking/releases)
(and mirrored in `release-notes/`). The detailed log through v0.5.48 is archived in
[docs/history/CHANGELOG-through-0.5.48.md](docs/history/CHANGELOG-through-0.5.48.md).

## 0.5 (current)

- One version source: `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in
  `project.pbxproj`; the app and widget `Info.plist`s read them as build settings.
  CI passes the next version to `xcodebuild` instead of editing `Info.plist`, and
  only tags releases.
- Removed the seven parked IJKPlayer/FFmpeg workflows from the default branch; the
  last revision of them is commit `07fce19`.
- Danmaku moved to WBI-signed protobuf segments; profile dynamic count and follow
  state use the endpoints the web profile page calls; the detail screen shows
  separate like / coin / favorite / share counts.
- Playback regression suite on the simulator (silent DASH, replay after
  completion, proxy restart).
