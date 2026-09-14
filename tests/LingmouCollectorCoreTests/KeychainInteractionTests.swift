import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import LingmouCollectorCore

final class KeychainInteractionTests: XCTestCase {
    func testBackgroundReadSuppressesLegacyAndModernPromptsAndRestoresState() {
        for status in [errSecSuccess, errSecInteractionNotAllowed, errSecUserCanceled, errSecItemNotFound] {
            var changes: [Bool] = []
            let result = KimiSafeStorage.copyKeychainPassword(
                service: "test-service", account: "test-account",
                getInteraction: { previous in previous.pointee = true; return errSecSuccess },
                setInteraction: { enabled in changes.append(enabled); return errSecSuccess },
                copyMatching: { query, item in
                    XCTAssertEqual(changes, [false], "Legacy UI must be disabled before lookup")
                    let values = query as NSDictionary
                    let context = values[kSecUseAuthenticationContext] as? LAContext
                    XCTAssertEqual(context?.interactionNotAllowed, true)
                    XCTAssertEqual(values[kSecAttrService] as? String, "test-service")
                    if status == errSecSuccess { item.pointee = Data("fixture".utf8) as CFData }
                    return status
                })
            XCTAssertEqual(changes, [false, true], "Restore interaction even after a failed read")
            XCTAssertEqual(result.status, status)
            XCTAssertEqual(result.password, status == errSecSuccess ? Data("fixture".utf8) : nil)
        }
    }

    func testCannotReadWhenLegacyPromptSuppressionFails() {
        for getFails in [true, false] {
            var copies = 0
            let result = KimiSafeStorage.copyKeychainPassword(
                service: "test", account: "test",
                getInteraction: { _ in getFails ? errSecNotAvailable : errSecSuccess },
                setInteraction: { _ in errSecNotAvailable },
                copyMatching: { _, _ in copies += 1; return errSecSuccess })
            XCTAssertEqual(copies, 0, "Fail closed instead of risking an interactive lookup")
            XCTAssertEqual(result.status, errSecInteractionNotAllowed)
            XCTAssertNil(result.password)
        }
    }

    func testExplicitAuthorizationIsTheOnlyInteractiveRead() {
        var changes: [Bool] = []
        let result = KimiSafeStorage.copyKeychainPassword(
            service: "test", account: "test", allowInteraction: true,
            getInteraction: { previous in previous.pointee = false; return errSecSuccess },
            setInteraction: { enabled in changes.append(enabled); return errSecSuccess },
            copyMatching: { query, _ in
                XCTAssertEqual(changes, [true])
                XCTAssertEqual(((query as NSDictionary)[kSecUseAuthenticationContext] as? LAContext)?
                    .interactionNotAllowed, false)
                return errSecUserCanceled
            })
        XCTAssertEqual(result.status, errSecUserCanceled)
        XCTAssertNil(result.password)
        XCTAssertEqual(changes, [true, false])
    }

    func testKeyCacheRoundTripPermissionsAndClear() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = KimiSafeStorage.keyCachePath(homeDirectory: home.path)
        XCTAssertNil(KimiSafeStorage.cachedPassword(homeDirectory: home.path))
        KimiSafeStorage.cachePassword(Data("secret-pass".utf8), homeDirectory: home.path)
        XCTAssertEqual(KimiSafeStorage.cachedPassword(homeDirectory: home.path),
                       Data("secret-pass".utf8))
        let filePerms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(filePerms, 0o600)
        let dirPerms = try FileManager.default.attributesOfItem(
            atPath: (path as NSString).deletingLastPathComponent)[.posixPermissions] as? Int
        XCTAssertEqual(dirPerms, 0o700)
        // 覆盖写入（口令轮换后重新授权）不能沿用旧文件的宽松权限
        KimiSafeStorage.cachePassword(Data("rotated".utf8), homeDirectory: home.path)
        XCTAssertEqual(KimiSafeStorage.cachedPassword(homeDirectory: home.path), Data("rotated".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int, 0o600)
        KimiSafeStorage.clearCachedPassword(homeDirectory: home.path)
        XCTAssertNil(KimiSafeStorage.cachedPassword(homeDirectory: home.path))
    }

    func testAuthorizationLockRejectsOverlapAndReleasesAfterDenial() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var prompts = 0
        let first = KimiKeychainAuthorization.withExclusiveRequest(homeDirectory: directory.path) {
            prompts += 1
            let overlap = KimiKeychainAuthorization.withExclusiveRequest(homeDirectory: directory.path) {
                prompts += 1
                return 0
            }
            XCTAssertEqual(overlap, 3)
            return 1
        }
        XCTAssertEqual(first, 1)
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(KimiKeychainAuthorization.withExclusiveRequest(homeDirectory: directory.path) { 0 }, 0)
    }
}
