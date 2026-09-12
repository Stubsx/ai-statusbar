import CommonCrypto
import Foundation
import LocalAuthentication
import Security

/// 解密新版 Kimi 桌面端（3.2.4+）写入 `token-store.json` 的 Electron safeStorage 密文。
///
/// 磁盘格式：`{"encryption":"safeStorage.v1","data":"<base64>"}`，base64 解码后是
/// Chromium os_crypt v10 密文：AES-128-CBC + PKCS7。密钥并非口令本身，而是按 Chromium
/// 统一方案 PBKDF2-HMAC-SHA1(口令, salt="saltysalt", 1003 轮, 16 字节) 派生；
/// IV 固定 16 个空格。口令存在钥匙串 "kimi-desktop Safe Storage"（账户 "kimi-desktop
/// Key"）。解开后是 token store 的 JSON 文本（实测为 {"origin":…,"tokens":{…}}）。
/// 默认关闭。后台读取始终禁止授权界面；交互授权由独立的手动命令完成。
enum KimiSafeStorage {
    static let keychainService = "kimi-desktop Safe Storage"
    static let keychainAccount = "kimi-desktop Key"

    private static let interactionLock = NSLock()

    /// 后台读取必须快速降级，不能让定时采集停在系统授权窗口。
    static func readKeychainPassword(service: String, account: String) -> Data? {
        copyKeychainPassword(service: service, account: account).password
    }

    static func copyKeychainPassword(
        service: String, account: String, allowInteraction: Bool = false,
        getInteraction: (UnsafeMutablePointer<DarwinBoolean>) -> OSStatus = SecKeychainGetUserInteractionAllowed,
        setInteraction: (Bool) -> OSStatus = SecKeychainSetUserInteractionAllowed,
        copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>) -> OSStatus = SecItemCopyMatching
    ) -> (status: OSStatus, password: Data?) {
        // Electron uses the legacy login keychain. LAContext alone does not suppress
        // legacy ACL/unlock dialogs, so also disable Security.framework interaction.
        // This flag is process-wide; serialize and restore it for library callers.
        interactionLock.lock()
        defer { interactionLock.unlock() }
        var previous = DarwinBoolean(false)
        guard getInteraction(&previous) == errSecSuccess,
              setInteraction(allowInteraction) == errSecSuccess else {
            return (errSecInteractionNotAllowed, nil)
        }
        defer { _ = setInteraction(previous.boolValue) }
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &item)
        return (status, status == errSecSuccess ? item as? Data : nil)
    }

    /// Chromium os_crypt 的密钥派生（macOS/Linux 统一）：
    /// PBKDF2-HMAC-SHA1(口令, "saltysalt", 1003 轮) → 16 字节 AES-128 密钥。
    static func deriveKey(password: Data) -> Data? {
        let passwordBytes = password.map { Int8(bitPattern: $0) }
        let salt = [UInt8]("saltysalt".utf8)
        let length = kCCKeySizeAES128
        var derived = [UInt8](repeating: 0, count: length)
        let status: CCCryptorStatus = passwordBytes.withUnsafeBufferPointer { passwordPointer in
            salt.withUnsafeBufferPointer { saltPointer in
                derived.withUnsafeMutableBufferPointer { derivedPointer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPointer.baseAddress, passwordBytes.count,
                        saltPointer.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1_003,
                        derivedPointer.baseAddress, length
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(derived)
    }

    /// 解密 token store；明文按 JSON 解析返回。任何一步失败都返回 nil，调用方降级为提示。
    static func decryptTokenStore(
        payload: String,
        keyProvider: (String, String) -> Data? = { service, account in
            readKeychainPassword(service: service, account: account)
        }
    ) -> JSONObject? {
        guard let blob = Data(base64Encoded: payload),
            blob.count > 3 + kCCBlockSizeAES128,
            blob.prefix(3) == Data("v10".utf8),
            let password = keyProvider(keychainService, keychainAccount),
            let key = deriveKey(password: password)
        else { return nil }
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        guard
            let plain = aesCBCDecrypt(key: key, iv: iv, ciphertext: blob.suffix(from: 3)),
            let text = String(data: plain, encoding: .utf8)
        else { return nil }
        return JSONValue.object(from: text)
    }

    private static func aesCBCDecrypt(key: Data, iv: Data, ciphertext: Data) -> Data? {
        var keyBytes = [UInt8](key)
        var ivBytes = [UInt8](iv)
        var cipherBytes = [UInt8](ciphertext)
        var outputBytes = [UInt8](repeating: 0, count: cipherBytes.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            &keyBytes, keyBytes.count,
            &ivBytes,
            &cipherBytes, cipherBytes.count,
            &outputBytes, outputBytes.count,
            &moved
        )
        guard status == kCCSuccess else { return nil }
        return Data(outputBytes.prefix(moved))
    }
}
