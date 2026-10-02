import XCTest
@testable import Paladala

/// Tests for the 大会员 upgrade-sheet pipeline. The sheet
/// itself is a SwiftUI view modifier and the test target
/// would otherwise have to spin up an `XCUIApplication` to
/// assert against, which is heavier than the assertion is
/// worth — so these tests focus on the *logic* the sheet is
/// built from: the typed error's helpers, the
/// `VipUpgradeReason` copy factory, and the
/// `BiliVideoQuality.requiresVIP` matrix the menu reads from.
///
/// The view-level behaviour (tapping a gated row flips the
/// local state, the alert modifier presents) is exercised
/// by the iOS preview / manual smoke; the logic tests
/// below catch regressions in the *content* of the sheet
/// when the underlying ladder or the message copy moves.
final class VipUpgradeHintTests: XCTestCase {

    // MARK: - BiliVideoQuality VIP gate

    func test_videoQuality_ladderMatchesKnownGatedSet() {
        // The ladder entries that B站 publishes today
        // and which the gate recognises. Adding a new
        // VIP-only entry that forgot to set `requiresVIP`
        // would let a non-VIP user pick a row that the
        // upstream would 62004 — these assertions catch
        // that drift.
        XCTAssertFalse(BiliVideoQuality.p360.requiresVIP)
        XCTAssertFalse(BiliVideoQuality.p480.requiresVIP)
        XCTAssertFalse(BiliVideoQuality.p720.requiresVIP)
        XCTAssertFalse(BiliVideoQuality.p1080.requiresVIP)
        XCTAssertTrue(BiliVideoQuality.p1080Plus.requiresVIP)
        XCTAssertTrue(BiliVideoQuality.p1080P60.requiresVIP)
        XCTAssertTrue(BiliVideoQuality.k4K.requiresVIP)
        XCTAssertTrue(BiliVideoQuality.hdr.requiresVIP)
        XCTAssertTrue(BiliVideoQuality.dolbyVision.requiresVIP)
        XCTAssertTrue(BiliVideoQuality.k8K.requiresVIP)
        XCTAssertTrue(BiliVideoQuality.p1080HiBitrate.requiresVIP)
        XCTAssertTrue(BiliVideoQuality.k4KHiBitrate.requiresVIP)
        XCTAssertTrue(BiliVideoQuality.k4KHDR.requiresVIP)
        XCTAssertTrue(BiliVideoQuality.k8KHDR.requiresVIP)
    }

    func test_videoQuality_title_appendsLockedBadge_whenGated() {
        // The non-VIP label for a gated row carries the
        // locked suffix so the menu's title row is
        // self-explanatory: the user sees "4K · 大会员"
        // and immediately knows why the row is dimmed.
        let nonVIPLabel = BiliVideoQuality.k4K.title(isVIP: false)
        XCTAssertTrue(
            nonVIPLabel.contains(L10n.vip.lockedBadge),
            "non-VIP label for 4K should append the locked badge, got: \(nonVIPLabel)"
        )
        // VIP label for the same entry drops the suffix.
        let vipLabel = BiliVideoQuality.k4K.title(isVIP: true)
        XCTAssertFalse(
            vipLabel.contains(L10n.vip.lockedBadge),
            "VIP label for 4K should NOT carry the locked badge, got: \(vipLabel)"
        )
    }

    // MARK: - BiliAudioQuality VIP gate

    func test_audioQuality_ladderMatchesKnownGatedSet() {
        XCTAssertFalse(BiliAudioQuality.low64.requiresVIP)
        XCTAssertFalse(BiliAudioQuality.standard128.requiresVIP)
        XCTAssertTrue(BiliAudioQuality.hiRes320.requiresVIP)
        XCTAssertTrue(BiliAudioQuality.dolby192.requiresVIP)
    }

    // MARK: - BilibiliAPIError typed-error plumbing

    func test_apiError_isVipExpiredError_trueOnlyForExpiredCase() {
        // The ViewModel's setPreferredQn branches on this
        // flag to decide between "去开通" and "去续费" copy.
        // A typo that inverted the predicate would route
        // every "not a VIP" failure to the renewal path —
        // these assertions keep the two paths apart.
        XCTAssertTrue(
            BilibiliAPIError.vipExpired(gated: .k4K).isVipExpiredError
        )
        XCTAssertFalse(
            BilibiliAPIError.vipRequired(gated: .k4K).isVipExpiredError
        )
        XCTAssertFalse(BilibiliAPIError.noPlayableFormat.isVipExpiredError)
        XCTAssertFalse(
            BilibiliAPIError.api("啥都木有").isVipExpiredError
        )
        XCTAssertFalse(BilibiliAPIError.sessionExpired.isVipExpiredError)
    }

    func test_apiError_localizedDescriptionForVipErrors_usesHintStrings() {
        // The inline `errorMessage` banner reads
        // `errorDescription`. Both VIP-typed errors must
        // surface a non-nil, non-empty description — a
        // regression that left them nil would leave the
        // user with a silent "该画质不可用" banner.
        let required = BilibiliAPIError.vipRequired(gated: .k4K)
        XCTAssertEqual(
            required.errorDescription,
            L10n.vip.requiredHint
        )
        let expired = BilibiliAPIError.vipExpired(gated: .k4K)
        XCTAssertEqual(
            expired.errorDescription,
            L10n.vip.expiredHint
        )
    }

    // MARK: - VipUpgradeReason copy factory

    func test_upgradeReason_loggedOut_showsLoginAction() {
        // The alert modifier uses this flag to decide
        // whether to render the secondary "去登录" button.
        // Forgetting to gate it would push a sign-in sheet
        // at a user who is already signed in.
        XCTAssertTrue(VipUpgradeReason.loggedOut.showsLoginAction)
        XCTAssertFalse(VipUpgradeReason.notVIP.showsLoginAction)
        XCTAssertFalse(VipUpgradeReason.expired.showsLoginAction)
    }

    func test_upgradeReason_titlesAreNotEmpty() {
        // The alert title drives the iOS chrome's bold
        // weight — an empty title would render the sheet
        // with a blank header bar, which the iOS HIG
        // explicitly warns against.
        XCTAssertFalse(VipUpgradeReason.loggedOut.alertTitle.isEmpty)
        XCTAssertFalse(VipUpgradeReason.notVIP.alertTitle.isEmpty)
        XCTAssertFalse(VipUpgradeReason.expired.alertTitle.isEmpty)
    }

    func test_upgradeReason_loggedOutBody_omitsGatedLabel() {
        // The signed-out branch uses the generic
        // "登录大会员账号后可解锁" copy because we don't
        // know whether the (absent) account would be VIP.
        // The body must not embed a `gatedLabel` — that
        // would be misleading ("登录后可解锁 4K" implies
        // the user's account has 4K, which we cannot know).
        let body = VipUpgradeReason.loggedOut.alertMessage(gatedLabel: "4K · 大會員")
        XCTAssertFalse(
            body.contains("4K"),
            "loggedOut body must not interpolate the gated label, got: \(body)"
        )
    }

    func test_upgradeReason_notVIPBody_appendsGatedLabel_whenProvided() {
        // The non-VIP branch *does* append the gated
        // label so the user knows which row the upgrade
        // unlocks. The exact format is `(label)` —
        // changing the brackets would be a copy
        // regression we want to catch.
        let body = VipUpgradeReason.notVIP.alertMessage(gatedLabel: "4K · 大會員")
        XCTAssertTrue(
            body.contains("（4K · 大會員）"),
            "notVIP body should embed the gated label in parens, got: \(body)"
        )
    }

    func test_upgradeReason_expiredBody_appendsGatedLabel_whenProvided() {
        let body = VipUpgradeReason.expired.alertMessage(gatedLabel: "1080P60 · 大會員")
        XCTAssertTrue(
            body.contains("（1080P60 · 大會員）"),
            "expired body should embed the gated label in parens, got: \(body)"
        )
    }

    func test_upgradeReason_bodies_omitsGated_whenNil() {
        // The ViewModel's onChange handler renders the
        // current preferred qn / audio id when a
        // refetch-triggered upgrade sheet comes through.
        // A nil `gatedLabel` must fall back to the
        // generic body — empty parens are a copy
        // regression.
        let body = VipUpgradeReason.notVIP.alertMessage(gatedLabel: nil)
        XCTAssertFalse(body.contains("（"))
        XCTAssertFalse(body.contains(")"))
    }

    // MARK: - VipUpgradeURL

    func test_upgradeURL_pointsAtOfficialBiliAccount() {
        // The "去开通/续费" button opens this URL. A
        // regression that pointed it at the homepage
        // would silently break the upgrade flow — the
        // assert catches the drift without needing a
        // network round-trip.
        XCTAssertEqual(
            VipUpgradeURL.upgrade.scheme,
            "https"
        )
        XCTAssertEqual(
            VipUpgradeURL.upgrade.host,
            "account.bilibili.com"
        )
        XCTAssertTrue(
            VipUpgradeURL.upgrade.path.contains("bigVip"),
            "upgrade URL should hit the VIP-specific landing page, got: \(VipUpgradeURL.upgrade.absoluteString)"
        )
    }
}
