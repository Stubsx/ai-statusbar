import Darwin
import Foundation
import Security

/// Only the explicit CLI authorization command calls this API. It never exports
/// the password or decrypts tokens. Background collection uses noninteractive reads.
public enum KimiKeychainAuthorization {
    /// Exit codes: 0 allowed, 1 denied/unavailable, 3 another request is in progress.
    public static func request(homeDirectory: String = NSHomeDirectory()) -> Int32 {
        withExclusiveRequest(homeDirectory: homeDirectory) {
            let result = KimiSafeStorage.copyKeychainPassword(
                service: KimiSafeStorage.keychainService,
                account: KimiSafeStorage.keychainAccount,
                allowInteraction: true)
            guard result.status == errSecSuccess, let password = result.password else { return 1 }
            // 钥匙串 ACL 随重建失效，备份口令让授权真正持久（见 KimiSafeStorage.keyCachePath）。
            KimiSafeStorage.cachePassword(password, homeDirectory: homeDirectory)
            // Invalidate permission-failure caches without deleting the last good quota.
            let marker = URL(fileURLWithPath: homeDirectory)
                .appendingPathComponent(".ai-statusbar/kimi-keychain-authorized")
            try? Data().write(to: marker, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            return 0
        }
    }

    static func withExclusiveRequest(homeDirectory: String, operation: () -> Int32) -> Int32 {
        let directory = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".ai-statusbar")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return 1 }
        let path = directory.appendingPathComponent("kimi-keychain-authorization.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return 1 }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return 3 }
        defer { flock(descriptor, LOCK_UN) }
        return operation()
    }
}
