import Foundation
import Security

struct TokenStore {
    private let service = "dev.fjira.app.jira-token"

    func load(site: String, account: String) throws -> String? {
        var query = query(site: site, account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { throw Failure(status: status) }
        return token
    }

    func save(_ token: String, site: String, account: String) throws {
        let query = query(site: site, account: account)
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Failure(status: addStatus) }
        } else if status != errSecSuccess {
            throw Failure(status: status)
        }
    }

    func delete(site: String, account: String) throws {
        let status = SecItemDelete(query(site: site, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    private func query(site: String, account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: "\(site)|\(account)"]
    }

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "Keychain access failed: \(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")."
        }
    }
}
