import CryptoKit
import Darwin
import Foundation
import Security

/// Team-signed apps accept only valid code from their own team. Development
/// apps without a team use a build digest in the signed app Info.plist.
/// No launch-time sidecar or environment variable can supply the expected pin.
enum PhoneAccessHelperIntegrity {
    static func validate(helper: URL) throws {
        var info = stat()
        guard lstat(helper.path, &info) == 0,
            info.st_mode & S_IFMT == S_IFREG,
            info.st_mode & 0o022 == 0,
            FileManager.default.isExecutableFile(atPath: helper.path)
        else { throw IntegrityError.unsafeFile }

        let appTeam = try ownTeamID()
        if let appTeam {
            guard try teamID(at: helper) == appTeam else {
                throw IntegrityError.wrongTeam
            }
        } else {
            // No Team ID: unsigned/ad-hoc builds still require an exact build pin.
            let digest = SHA256.hash(data: try Data(contentsOf: helper)).map { String(format: "%02x", $0) }.joined()
            guard acceptsDevelopmentDigest(digest, expected: Bundle.main.object(forInfoDictionaryKey: "OsaurusTSHelperSHA256") as? String) else {
                throw IntegrityError.wrongDigest
            }
        }
    }

    static func acceptsDevelopmentDigest(_ actual: String, expected: String?) -> Bool {
        guard let expected, expected.count == 64,
            expected.allSatisfy({ $0.isASCII && ("0"..."9" ~= $0 || "a"..."f" ~= $0) })
        else { return false }
        return actual == expected
    }

    private static func ownTeamID() throws -> String? {
        // Read the running app's identity, not a replaceable bundle path. This
        // does not access private signing keys or prompt for Keychain access.
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw IntegrityError.invalidSignature
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw IntegrityError.invalidSignature
        }
        var info: CFDictionary?
        let result = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        if result == errSecCSUnsigned { return nil }
        guard result == errSecSuccess, let dictionary = info as? [String: Any] else {
            throw IntegrityError.invalidSignature
        }
        return (dictionary[kSecCodeInfoTeamIdentifier as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func teamID(at url: URL) throws -> String? {
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard created == errSecSuccess, let code else { throw IntegrityError.invalidSignature }
        let validity = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        guard validity == errSecSuccess else { throw IntegrityError.invalidSignature }
        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo) == errSecSuccess,
            let dictionary = signingInfo as? [String: Any]
        else { throw IntegrityError.invalidSignature }
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        return team.flatMap { $0.isEmpty ? nil : $0 }
    }

    enum IntegrityError: LocalizedError {
        case unsafeFile, invalidSignature, wrongTeam, wrongDigest
        var errorDescription: String? {
            switch self {
            case .unsafeFile: "Bundled phone helper must be a regular executable and not group/world-writable"
            case .invalidSignature: "Phone helper or app code signature is invalid"
            case .wrongTeam: "Phone helper is not signed by the app's team"
            case .wrongDigest: "Phone helper does not match the build digest in this app’s Info.plist"
            }
        }
    }
}
