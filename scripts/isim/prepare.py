#!/usr/bin/env python3
"""Apply reversible, CI-checkout-only compatibility fixes for kolabs-dev/isim.

The real iOS project is unchanged in Git. Keep these specific and fail loudly
if upstream source moves, rather than silently publishing a broken .app.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = Path("ios/Paladala/Paladala")


def replace(rel: Path, before: str, after: str, *, count: int | None = 1) -> None:
    path = ROOT / rel
    content = path.read_text()
    n = content.count(before)
    if count is not None and n != count:
        raise SystemExit(f"iSim compatibility drift: {rel}: expected {count} matches, got {n} for {before!r}")
    if n == 0:
        raise SystemExit(f"iSim compatibility drift: {rel}: missing {before!r}")
    path.write_text(content.replace(before, after))
    print(f"iSim compatibility: {rel} ({n} replacement(s))")


# The clean-room iSim SDK does not yet bridge SwiftUI Color to UIColor.
search = SRC / "UISearchFieldBridge.swift"
for color, equivalent in {
    "paper": "systemBackground",
    "ink": "label",
    "biliPink": "systemPink",
    "mutedInk": "secondaryLabel",
}.items():
    replace(search, f"UIColor(PaladalaTheme.{color})", f"UIColor.{equivalent}", count=None)

# The iSim SDK has textInputAutocapitalization but not legacy autocapitalization.
replace(SRC / "SponsorBlockSettingsView.swift",
        ".autocapitalization(.none)", ".textInputAutocapitalization(.never)")
replace(SRC / "PluginsSettingsView.swift",
        ".stroke(.secondary.opacity(0.3))", ".stroke(Color.secondary.opacity(0.3))")
replace(SRC / "DiagnosticLogger.swift", "line.data(using: .utf8)",
        "String(line).data(using: .utf8)")
replace(SRC / "PaladalaAppIntents.swift",
        "payload.video.map { .video($0.entity) }",
        "payload.video.map { IntentRoute.video($0.entity) }")
replace(SRC / "LocalHLSProxyServer.swift",
        "guard let data = try handle.read(\n                upToCount: Int(clamped.count)\n            ) else { return nil }",
        "let data = try handle.read(\n                upToCount: Int(clamped.count)\n            )")

# Text selection is a presentation-only modifier, not a requirement for rendering.
selection_count = 0
for path in (ROOT / SRC).rglob("*.swift"):
    content = path.read_text()
    if ".textSelection(.enabled)" in content:
        selection_count += content.count(".textSelection(.enabled)")
        path.write_text(content.replace(".textSelection(.enabled)", ""))
print(f"iSim compatibility: skipped {selection_count} unsupported textSelection modifiers")

# The native iOS alert(item:) -> Alert overload is missing; use iSim's
# supported alert(title:isPresented:actions:message:) without losing recovery.
alerts = ROOT / SRC / "AppErrorCenter.swift"
content = alerts.read_text()
start = content.index("private struct AppErrorAlertModifier: ViewModifier {")
body = content.index("    func body(content: Content) -> some View {", start)
end = content.index("\n    }\n}\n\nextension View {", body)
current = content[body:end]
old_head = "    func body(content: Content) -> some View {\n"
assert current.startswith(old_head)
compat = """    func body(content: Content) -> some View {
#if ISIM
        content.alert(
            center.current?.descriptor.title ?? "Paladala",
            isPresented: Binding(
                get: { center.current != nil },
                set: { isPresented in if !isPresented { center.dismiss() } }
            )
        ) {
            if center.current?.recovery != nil, let label = center.current?.recoveryLabel {
                Button(label) { center.recover() }
            }
            Button("關閉") { center.dismiss() }
        } message: {
            Text(center.current?.descriptor.message ?? "")
        }
#else
"""
content = content[:body] + compat + current[len(old_head):] + "\n#endif" + content[end:]
alerts.write_text(content)
print("iSim compatibility: used supported alert overload")

# Add shims only to the temporary CI checkout. The app's target already
# includes AppVersion.swift, avoiding edits to Xcode project source membership.
destination = ROOT / SRC / "AppVersion.swift"
shim = (ROOT / "scripts/isim/compat.swift").read_text()
destination.write_text(destination.read_text() + "\n\n#if ISIM\n" + shim + "\n#endif\n")
print("iSim compatibility: appended isolated SDK shims to the app target")
