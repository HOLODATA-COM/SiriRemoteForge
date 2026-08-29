//
//  HyperVibeCredentialBroker
//
//  Deliberately tiny and stable: this XPC service owns the macOS login-keychain ACL so normal UI
//  releases can change without prompting for API-key access again. Never add product logic here.
//

import Foundation
import LocalAuthentication
import Security

@objc(HVVoiceCredentialBrokerProtocol)
protocol VoiceCredentialBrokerProtocol {
    func readCredential(account: String,
                        reply: @escaping (NSData?, NSNumber) -> Void)
    func saveCredential(account: String, value: NSData,
                        reply: @escaping (NSNumber) -> Void)
    func removeCredential(account: String,
                          reply: @escaping (NSNumber) -> Void)
}

private final class CredentialBrokerService: NSObject, VoiceCredentialBrokerProtocol {
    private let service = "com.hypervibe.credentials.v6"
    private let loginKeychain: SecKeychain?
    private let credentialAccess: SecAccess?
    private let accessSetupStatus: OSStatus

    override init() {
        var keychainStatus = errSecItemNotFound
        let loginPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/login.keychain-db").path
        loginKeychain = loginPath.withCString {
            hv_open_keychain($0, &keychainStatus)
        }
        var accessStatus = errSecItemNotFound
        credentialAccess = hv_create_credential_access(nil, &accessStatus)
        accessSetupStatus = keychainStatus != errSecSuccess ? keychainStatus : accessStatus
        super.init()
    }

    func readCredential(account: String,
                        reply: @escaping (NSData?, NSNumber) -> Void) {
        readCredential(account: account, allowInteraction: false, reply: reply)
    }

    func readCredential(account: String, allowInteraction: Bool,
                        reply: (NSData?, NSNumber) -> Void) {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        reply(item as? NSData, NSNumber(value: status))
    }

    func saveCredential(account: String, value: NSData,
                        reply: @escaping (NSNumber) -> Void) {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrLabel as String: "HyperVibe Cloud Credential",
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess {
            reply(NSNumber(value: updated))
            return
        }
        guard updated == errSecItemNotFound else {
            reply(NSNumber(value: updated))
            return
        }
        guard credentialAccess != nil else {
            reply(NSNumber(value: accessSetupStatus))
            return
        }
        var addition = query
        addition[kSecValueData as String] = value
        addition[kSecAttrLabel as String] = "HyperVibe Cloud Credential"
        if let credentialAccess { addition[kSecAttrAccess as String] = credentialAccess }
        let added = SecItemAdd(addition as CFDictionary, nil)
        reply(NSNumber(value: added))
    }

    func removeCredential(account: String,
                          reply: @escaping (NSNumber) -> Void) {
        reply(NSNumber(value: SecItemDelete(baseQuery(account: account) as CFDictionary)))
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // An app-like XPC service may otherwise be routed to the entitlement-gated iOS/data-
        // protection implementation. HyperVibe's stable local identity has no Apple provisioning
        // profile, so explicitly select the user's encrypted file-based login keychain.
        if let loginKeychain { query[kSecUseKeychain as String] = loginKeychain }
        return query
    }
}

private final class CredentialBrokerListener: NSObject, NSXPCListenerDelegate {
    private let service = CredentialBrokerService()
    private let requiredClient: String?

    override init() {
        requiredClient = CodeSigningPeer.requirement(identifier: "com.hypervibe.app")
        super.init()
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.exportedInterface = NSXPCInterface(with: VoiceCredentialBrokerProtocol.self)
        connection.exportedObject = service
        if let requiredClient { connection.setCodeSigningRequirement(requiredClient) }
        connection.resume()
        return true
    }

}

private enum CodeSigningPeer {
    static func requirement(identifier: String) -> String? {
        var ownCode: SecCode?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(ownCode, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var ownRequirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &ownRequirement) == errSecSuccess,
              let ownRequirement else { return nil }
        var textValue: CFString?
        guard SecRequirementCopyString(ownRequirement, [], &textValue) == errSecSuccess,
              let text = textValue as String? else { return nil }
        guard let range = text.range(of: #"identifier \"[^\"]+\""#,
                                     options: .regularExpression) else { return nil }
        let replaced = text.replacingCharacters(
            in: range, with: "identifier \"\(identifier)\""
        )
        if replaced.contains("certificate leaf") { return replaced }
        return "identifier \"\(identifier)\""
    }
}

@main
private enum CredentialBrokerMain {
    static func main() {
        let allowedAccounts = ["openai-api-key", "deepseek-api-key"]
        if let index = CommandLine.arguments.firstIndex(of: "--save-credential"),
           index + 1 < CommandLine.arguments.count {
            let account = CommandLine.arguments[index + 1]
            guard allowedAccounts.contains(account), trustedParent() else {
                print(errSecAuthFailed)
                exit(1)
            }
            let value = FileHandle.standardInput.readDataToEndOfFile()
            guard !value.isEmpty, value.count <= 16_384 else {
                print(errSecParam)
                exit(1)
            }
            let service = CredentialBrokerService()
            var status = errSecInternalError
            service.saveCredential(account: account, value: value as NSData) {
                status = OSStatus($0.int32Value)
            }
            print(status)
            exit(status == errSecSuccess ? 0 : 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--read-credential"),
           index + 1 < CommandLine.arguments.count {
            let account = CommandLine.arguments[index + 1]
            guard allowedAccounts.contains(account), trustedParent() else {
                print(errSecAuthFailed)
                exit(1)
            }
            let service = CredentialBrokerService()
            var status = errSecInternalError
            var value: Data?
            service.readCredential(account: account, allowInteraction: false) { data, result in
                value = data as Data?
                status = OSStatus(result.int32Value)
            }
            print(status)
            if status == errSecSuccess, let value {
                print(value.base64EncodedString())
            }
            exit(status == errSecSuccess ? 0 : 1)
        }
        if CommandLine.arguments.contains("--read-credentials") {
            guard trustedParent() else {
                print(errSecAuthFailed)
                exit(1)
            }
            let service = CredentialBrokerService()
            var values: [String: [String: Any]] = [:]
            for account in allowedAccounts {
                var status = errSecInternalError
                var value: Data?
                service.readCredential(account: account, allowInteraction: false) { data, result in
                    value = data as Data?
                    status = OSStatus(result.int32Value)
                }
                var entry: [String: Any] = ["status": status]
                if status == errSecSuccess, let value {
                    entry["value"] = value.base64EncodedString()
                }
                values[account] = entry
            }
            guard let json = try? JSONSerialization.data(withJSONObject: values),
                  let text = String(data: json, encoding: .utf8) else {
                print(errSecInternalError)
                exit(1)
            }
            print(errSecSuccess)
            print(text)
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--authorize-credential"),
           index + 1 < CommandLine.arguments.count {
            let account = CommandLine.arguments[index + 1]
            guard allowedAccounts.contains(account), trustedParent() else {
                print(errSecAuthFailed)
                exit(1)
            }
            let service = CredentialBrokerService()
            var status = errSecInternalError
            service.readCredential(account: account, allowInteraction: true) { _, result in
                status = OSStatus(result.int32Value)
            }
            // Never write the credential to stdout in authorization mode. Only the OSStatus crosses
            // the pipe; this process exists solely to let SecurityAgent record Always Allow.
            print(status)
            exit(status == errSecSuccess ? 0 : 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--remove-credential"),
           index + 1 < CommandLine.arguments.count {
            let account = CommandLine.arguments[index + 1]
            guard allowedAccounts.contains(account), trustedParent() else {
                print(errSecAuthFailed)
                exit(1)
            }
            let service = CredentialBrokerService()
            var status = errSecInternalError
            service.removeCredential(account: account) {
                status = OSStatus($0.int32Value)
            }
            print(status)
            exit(status == errSecSuccess || status == errSecItemNotFound ? 0 : 1)
        }
        if CommandLine.arguments.contains("--self-test-keychain") {
            let account = "credential-broker-self-test"
            let service = CredentialBrokerService()
            var saveStatus = errSecInternalError
            service.saveCredential(account: account, value: Data("probe".utf8) as NSData) {
                saveStatus = OSStatus($0.int32Value)
            }
            var readStatus = errSecInternalError
            var matches = false
            service.readCredential(account: account) { value, status in
                readStatus = OSStatus(status.int32Value)
                matches = (value as Data?) == Data("probe".utf8)
            }
            var removeStatus = errSecInternalError
            service.removeCredential(account: account) {
                removeStatus = OSStatus($0.int32Value)
            }
            let passed = saveStatus == errSecSuccess && readStatus == errSecSuccess
                && matches && removeStatus == errSecSuccess
            print("CREDENTIAL_BROKER_SELF_TEST \(passed ? "PASS" : "FAIL") "
                  + "save=\(saveStatus) read=\(readStatus) match=\(matches) "
                  + "remove=\(removeStatus)")
            exit(passed ? 0 : 1)
        }
        let delegate = CredentialBrokerListener()
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
    }

    private static func trustedParent() -> Bool {
        guard let requirementText = CodeSigningPeer.requirement(identifier: "com.hypervibe.app")
        else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText as CFString, [], &requirement
        ) == errSecSuccess, let requirement else { return false }
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: getppid())]
        var parent: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil, attributes as CFDictionary, [], &parent
        ) == errSecSuccess, let parent else { return false }
        return SecCodeCheckValidity(parent, [], requirement) == errSecSuccess
    }
}
