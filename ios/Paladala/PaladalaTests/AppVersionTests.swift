import XCTest
@testable import Paladala

/// Tests for the pure helpers in `AppVersion.swift`.
///
/// We deliberately don't exercise `AppVersion.current` or
/// `detectReleaseType` here — both depend on the running
/// bundle's Info.plist and on the simulator's provisioning
/// state, which is brittle in CI.  The functions below are
/// the parts of the build-identity flow that need to stay
/// stable: the SHA-1 fingerprint, the formatted serial, and
/// the dotted-version comparator used by the update checker.
final class AppVersionTests: XCTestCase {

    // MARK: - makeIdentifier

    func test_makeIdentifier_isDeterministicForSameInputs() {
        let a = AppVersion.makeIdentifier(inputs: [
            "bundleId": "com.dt.paladala",
            "marketingVersion": "0.5.1",
            "buildNumber": "195",
            "releaseType": "sideload",
            "commit": "6cf275c0",
            "epoch": "1700000000",
            "salt": ""
        ])
        let b = AppVersion.makeIdentifier(inputs: [
            "bundleId": "com.dt.paladala",
            "marketingVersion": "0.5.1",
            "buildNumber": "195",
            "releaseType": "sideload",
            "commit": "6cf275c0",
            "epoch": "1700000000",
            "salt": ""
        ])
        XCTAssertEqual(a, b, "Same inputs must produce the same fingerprint")
        XCTAssertEqual(a.count, 12, "Identifier should be 12 hex chars (6 bytes)")
        XCTAssertTrue(a.allSatisfy { $0.isHexDigit }, "Identifier must be lowercase hex")
    }

    func test_makeIdentifier_changesWhenAnyInputChanges() {
        let base: [String: String] = [
            "bundleId": "com.dt.paladala",
            "marketingVersion": "0.5.1",
            "buildNumber": "195",
            "releaseType": "sideload",
            "commit": "6cf275c0",
            "epoch": "1700000000",
            "salt": ""
        ]
        let baseID = AppVersion.makeIdentifier(inputs: base)
        for key in ["bundleId", "marketingVersion", "buildNumber",
                    "releaseType", "commit", "epoch", "salt"] {
            var mutated = base
            mutated[key] = (base[key] ?? "") + "-x"
            let mutatedID = AppVersion.makeIdentifier(inputs: mutated)
            XCTAssertNotEqual(mutatedID, baseID,
                "Changing \(key) must change the identifier")
        }
    }

    // MARK: - formatIdentifier

    func test_formatIdentifier_groupsIntoPDDashFourDashFour() {
        let formatted = AppVersion.formatIdentifier("deadbeef1234")
        XCTAssertEqual(formatted, "PD-DEAD-BEEF-1234")
    }

    func test_formatIdentifier_padsShortInputs() {
        let formatted = AppVersion.formatIdentifier("ab")
        // 2 hex chars → left-padded to 12 so the value digits
        // stay right-aligned in the last group.
        XCTAssertEqual(formatted, "PD-0000-0000-00AB")
    }

    // MARK: - VersionComparator

    func test_versionComparator_ordersByComponent() {
        XCTAssertEqual(
            VersionComparator.compare("0.5.1.195", "0.5.1.200"),
            .orderedAscending
        )
        XCTAssertEqual(
            VersionComparator.compare("0.5.1.200", "0.5.1.195"),
            .orderedDescending
        )
        XCTAssertEqual(
            VersionComparator.compare("0.5.1.200", "0.5.1.200"),
            .orderedSame
        )
    }

    func test_versionComparator_padsShorterVersions() {
        // The CI's clean "0.5.1" marketing version is older than
        // a prerelease "0.5.1.200" — the trailing 200 makes the
        // prerelease win.
        XCTAssertEqual(
            VersionComparator.compare("0.5.1", "0.5.1.200"),
            .orderedAscending
        )
        XCTAssertEqual(
            VersionComparator.compare("0.5.1.200", "0.5.1"),
            .orderedDescending
        )
    }

    func test_versionComparator_stripsLeadingV() {
        XCTAssertEqual(
            VersionComparator.compare("v0.5.1.195", "0.5.1.195"),
            .orderedSame
        )
        XCTAssertEqual(
            VersionComparator.compare("V0.5.1.196", "v0.5.1.195"),
            .orderedDescending
        )
    }

    // MARK: - AltSource manifest decoder
    //
    // `UpdateChecker.check` decodes the gh-pages-hosted
    // `apps.json` to figure out whether a newer unsigned
    // IPA is available. The field set is small (version /
    // buildVersion / downloadURL) but a silent rename in
    // `scripts/generate_apps_json.py` would push an
    // empty `.updateAvailable` to every user; this test
    // round-trips a hand-rolled sample that matches the
    // actual output shape so a future drift shows up in
    // CI instead of in the field.

    func test_altSourceManifest_decodesAppsArrayShape() throws {
        let sample = """
        {
          "name": "Paladala",
          "apps": [
            {
              "name": "Paladala",
              "bundleIdentifier": "com.dt.paladala",
              "versions": [
                {
                  "version": "0.5.2",
                  "buildVersion": "3",
                  "date": "2026-08-02T10:00:00Z",
                  "size": 12345678,
                  "downloadURL": "https://github.com/darrenintr/pure-bilibili-rethinking/releases/download/v0.5.2.3/Paladala-unsigned-v0.5.2.3.ipa"
                }
              ]
            }
          ],
          "news": []
        }
        """
        let data = sample.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(UpdateChecker.AltSourceManifest.self, from: data)
        XCTAssertEqual(manifest.apps.count, 1)
        XCTAssertEqual(manifest.apps[0].bundleIdentifier, "com.dt.paladala")
        XCTAssertEqual(manifest.apps[0].versions.count, 1)
        XCTAssertEqual(manifest.apps[0].versions[0].version, "0.5.2")
        XCTAssertEqual(manifest.apps[0].versions[0].buildVersion, "3")
        XCTAssertTrue(manifest.apps[0].versions[0].downloadURL.hasSuffix(".ipa"))
    }

    func test_altSourceManifest_ignoresExtraFields() throws {
        // AltSource has many optional fields (subtitle,
        // tintColor, appPermissions, …) we don't decode.
        // Adding a new one upstream must not break the
        // in-app check.
        let sample = """
        {
          "apps": [
            {
              "bundleIdentifier": "com.dt.paladala",
              "versions": [
                {
                  "version": "0.5.2",
                  "buildVersion": "3",
                  "downloadURL": "https://example.com/p.ipa",
                  "subtitle": "ignored",
                  "tintColor": "#FB7299",
                  "localizedDescription": "ignored"
                }
              ],
              "iconURL": "https://example.com/icon.png",
              "category": "entertainment"
            }
          ]
        }
        """
        let data = sample.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(UpdateChecker.AltSourceManifest.self, from: data)
        XCTAssertEqual(manifest.apps[0].versions[0].version, "0.5.2")
    }
}
