import Foundation
import LocalAuthentication
import Security

public enum KeychainError: Error, CustomStringConvertible {
  case notFound(String)
  case osStatus(OSStatus, String)
  case invalidUTF8(String)
  case authUnavailable(String)
  case authFailed(String)

  public var description: String {
    switch self {
    case .notFound(let name):
      return "Secret '\(name)' not found in Keychain. Run 'touchrun set \(name)' first."
    case .osStatus(let status, let context):
      let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
      return "\(context): \(msg)"
    case .invalidUTF8(let name):
      return "Secret '\(name)' could not be decoded as UTF-8."
    case .authUnavailable(let reason):
      return "Touch ID / local authentication unavailable: \(reason)"
    case .authFailed(let reason):
      return "Authentication cancelled or failed: \(reason)"
    }
  }
}

public struct KeychainStore: Sendable {
  public let service: String

  public init(service: String = "com.mariusglauer.touchrun") {
    self.service = service
  }

  private func baseQuery(name: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: name,
    ]
  }

  public func exists(name: String) throws -> Bool {
    var query = baseQuery(name: name)
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    if status == errSecSuccess {
      return true
    }
    if status == errSecItemNotFound {
      return false
    }
    throw KeychainError.osStatus(status, "Keychain lookup failed for '\(name)'")
  }

  public func listNames() throws -> [String] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return []
    }
    guard status == errSecSuccess else {
      throw KeychainError.osStatus(status, "Failed to list Keychain items")
    }
    guard let items = result as? [[String: Any]] else {
      return []
    }
    return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
  }

  public func save(name: String, secret: String) throws {
    guard let data = secret.data(using: .utf8) else {
      throw KeychainError.invalidUTF8(name)
    }

    // Remove existing entry first so the ACL and value are cleanly replaced.
    SecItemDelete(baseQuery(name: name) as CFDictionary)

    var trustedApp: SecTrustedApplication?
    let trustStatus = SecTrustedApplicationCreateFromPath(nil, &trustedApp)
    var access: SecAccess?
    if trustStatus == errSecSuccess, let app = trustedApp {
      _ = SecAccessCreate(
        "touchrun secret: \(name)" as CFString,
        [app] as CFArray,
        &access
      )
    }

    var addQuery = baseQuery(name: name)
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrLabel as String] = "touchrun: \(name)"
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    if let access {
      addQuery[kSecAttrAccess as String] = access
    }

    let status = SecItemAdd(addQuery as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw KeychainError.osStatus(status, "Failed to save '\(name)' to Keychain")
    }
  }

  public func delete(name: String) throws -> Bool {
    let status = SecItemDelete(baseQuery(name: name) as CFDictionary)
    if status == errSecSuccess {
      return true
    }
    if status == errSecItemNotFound {
      return false
    }
    throw KeychainError.osStatus(status, "Failed to delete '\(name)' from Keychain")
  }

  public func read(name: String) throws -> String {
    var query = baseQuery(name: name)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      throw KeychainError.notFound(name)
    }
    guard status == errSecSuccess else {
      throw KeychainError.osStatus(status, "Failed to read '\(name)' from Keychain")
    }
    guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
      throw KeychainError.invalidUTF8(name)
    }
    return secret
  }
}

public enum TouchIDGate {
  public static func authenticate(secretNames: [String], envVars: [String], command: [String]) throws {
    let context = LAContext()
    let policy: LAPolicy = .deviceOwnerAuthentication
    var canEvalError: NSError?

    guard context.canEvaluatePolicy(policy, error: &canEvalError) else {
      throw KeychainError.authUnavailable(canEvalError?.localizedDescription ?? "unknown error")
    }

    let cmdText = command.joined(separator: " ")
    let maxLen = 200
    let preview = cmdText.count > maxLen ? String(cmdText.prefix(maxLen)) + "…" : cmdText
    let secretsLabel = secretNames.joined(separator: ", ")
    let envLabel = envVars.joined(separator: ", ")
    let reason = "inject [\(secretsLabel)] -> \(envLabel) for:\n\(preview)"

    let semaphore = DispatchSemaphore(value: 0)
    var succeeded = false
    var evalError: Error?

    context.evaluatePolicy(policy, localizedReason: reason) { ok, err in
      succeeded = ok
      evalError = err
      semaphore.signal()
    }

    semaphore.wait()

    if !succeeded {
      throw KeychainError.authFailed(evalError?.localizedDescription ?? "denied")
    }
  }
}
