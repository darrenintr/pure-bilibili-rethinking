//
//  VipBadgeView.swift
//  Paladala
//
//  Renders a BiliVIPBadge as a colored capsule with an icon
//  + label. Used in every surface that surfaces the user's
//  display name:
//
//    • Profile header (ProfileSettingsView.signedInHeader)
//    • UP profile header (UPProfileView, replacing the
//      previous generic `crown.fill` icon)
//    • Comment header / reply row (ReplyListView)
//    • Home / search card owner-name suffix (SharedViews)
//
//  Two flavours live in this file:
//    • `VipBadgeView` — full chip with icon + label. Use
//      where there is room.
//    • `VipBadgeCompact` — icon-only. Use where the chip
//      would push the display name out of the row.
//    • `vipBadgeColor(...)` — single-colour fallback for
//      cases where we only want to tint the username, not
//      render a chip.
//

import SwiftUI

// MARK: - Full badge

/// Full-size 大会员 chip. Renders as a colored capsule with an
/// SF Symbol glyph + badge text. Honours the badge's colour
/// palette (background, foreground, border) so a "十年大会员"
/// looks different from a regular "大会员".
struct VipBadgeView: View {
    let badge: BiliVIPBadge
    /// Visual size — controls the icon's pointSize and the
    /// chip's vertical padding. `.standard` is the default for
    /// profile headers; `.small` suits inline comment rows.
    var size: Size = .standard

    enum Size {
        case standard
        case small
    }

    var body: some View {
        if badge.isActive {
            HStack(spacing: iconSpacing) {
                if !badge.symbolName.isEmpty {
                    Image(systemName: badge.symbolName)
                        .font(.system(
                            size: iconPointSize,
                            weight: .heavy
                        ))
                }
                if !badge.text.isEmpty, size != .small {
                    Text(badge.text)
                        .font(.system(
                            size: textPointSize,
                            weight: .black,
                            design: .rounded
                        ))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .foregroundStyle(badge.foregroundColor)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background {
                Capsule(style: .continuous)
                    .fill(badge.backgroundColor)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(
                                badge.borderColor.opacity(0.85),
                                lineWidth: PaladalaTheme.hairlineWidth
                            )
                    }
            }
            .opacity(badge.isExpired ? 0.55 : 1.0)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityDescription)
        }
    }

    private var iconSpacing: CGFloat {
        switch size {
        case .standard: return 3
        case .small: return 0
        }
    }
    private var iconPointSize: CGFloat {
        switch size {
        case .standard: return 9
        case .small: return 9
        }
    }
    private var textPointSize: CGFloat {
        switch size {
        case .standard: return 9
        case .small: return 8
        }
    }
    private var horizontalPadding: CGFloat {
        switch size {
        case .standard: return 6
        case .small: return 4
        }
    }
    private var verticalPadding: CGFloat {
        switch size {
        case .standard: return 2
        case .small: return 2
        }
    }

    private var accessibilityDescription: String {
        var parts: [String] = [badge.text.isEmpty ? "大會員" : badge.text]
        if let due = badge.dueDate, !badge.isExpired {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            parts.append("到期 \(f.string(from: due))")
        } else if badge.isExpired {
            parts.append("已過期")
        }
        return parts.joined(separator: "，")
    }
}

// MARK: - Compact (icon only)

/// Icon-only badge — a single SF Symbol glyph tinted to the
/// badge's background colour. Use in tight rows where the
/// full chip would push the user-name off-screen (e.g. the
/// home feed card's owner-name line).
struct VipBadgeCompact: View {
    let badge: BiliVIPBadge
    var pointSize: CGFloat = 11

    var body: some View {
        if badge.isActive {
            Image(systemName: badge.symbolName.isEmpty ? "crown.fill" : badge.symbolName)
                .font(.system(size: pointSize, weight: .heavy))
                .foregroundStyle(badge.backgroundColor)
                .opacity(badge.isExpired ? 0.55 : 1.0)
                .accessibilityLabel(Text(badge.text.isEmpty ? "大會員" : badge.text))
        }
    }
}

// MARK: - Nickname color helper

/// Resolve the colour a user-name should be rendered in for a
/// given badge. Returns `nil` for the no-badge case so the
/// caller can fall through to its default text colour
/// (typically `.primary` / `PaladalaTheme.ink`).
func vipBadgeNicknameColor(for badge: BiliVIPBadge?) -> Color? {
    guard let badge, badge.isActive, !badge.isExpired else { return nil }
    return badge.nicknameColor
}