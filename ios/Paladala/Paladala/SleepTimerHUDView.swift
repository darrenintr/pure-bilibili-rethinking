//
//  SleepTimerHUDView.swift
//
//  Small overlay HUD shown while the sleep timer is counting
//  down.  Observes ONLY its own `SleepTimer` so the parent
//  `PlayerView` is not re-evaluated every tick — that's what
//  keeps the countdown cheap.  `allowsHitTesting(true)` is set
//  on the cancel button so it still receives taps even though
//  the dim background is non-interactive.
//

import SwiftUI

struct SleepTimerHUDView: View {
    @ObservedObject var timer: SleepTimer

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: timer.phase == .fading
                  ? "moon.zzz.fill"
                  : "moon.zzz")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
            Text(formatMMSS(timer.remainingSeconds))
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .monospacedDigit()
            Button {
                timer.cancel()
            } label: {
                Text(L10n.common.cancel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.white.opacity(0.18))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Color.black.opacity(0.55))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text("\(timer.remainingSeconds / 60) 分 \(timer.remainingSeconds % 60) 秒後自動暫停")
        )
    }

    private func formatMMSS(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}
