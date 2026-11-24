import Foundation

public struct SecretSpec: Equatable, Sendable {
  public let secretName: String
  public let explicitEnvVar: String?

  public init(secretName: String, explicitEnvVar: String? = nil) {
    self.secretName = secretName
    self.explicitEnvVar = explicitEnvVar
  }
}

public enum Command: Equatable, Sendable {
  case help
  case version
  case set(name: String, envVars: [String]?)
  case list
  case status(name: String)
  case delete(name: String)
  case run(specs: [SecretSpec], command: [String])
}

public enum ParseError: Error, Equatable, CustomStringConvertible {
  case missingArguments
  case invalidSecretName(String)
  case invalidEnvVarName(String)
  case missingOptionValue(String)
  case unknownOption(String)
  case missingSeparator
  case missingCommand
  case missingSecretSpec

  public var description: String {
    switch self {
    case .missingArguments:
      return "Missing arguments. Run 'touchrun --help' for usage."
    case .invalidSecretName(let name):
      return "Invalid secret name '\(name)'. Use letters, digits, '.', '_', or '-'."
    case .invalidEnvVarName(let name):
      return "Invalid environment variable name '\(name)'. Must match [A-Za-z_][A-Za-z0-9_]*."
    case .missingOptionValue(let flag):
      return "Missing value for option '\(flag)'."
    case .unknownOption(let flag):
      return "Unknown option '\(flag)'."
    case .missingSeparator:
      return "Missing '--' before the command to execute."
    case .missingCommand:
      return "Missing command after '--'."
    case .missingSecretSpec:
      return "Specify at least one secret before '--'."
    }
  }
}

public struct SecretMetadata: Codable, Equatable, Sendable {
  public var env: [String]

  public init(env: [String]) {
    self.env = env
  }
}

public struct MetadataStore: Sendable {
  public let fileURL: URL

  public init(fileURL: URL = MetadataStore.defaultFileURL()) {
    self.fileURL = fileURL
  }

  public static func defaultFileURL() -> URL {
    let base: URL
    if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
      base = URL(fileURLWithPath: xdg, isDirectory: true)
    } else {
      base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
    }
    return base
      .appendingPathComponent("touchrun", isDirectory: true)
      .appendingPathComponent("secrets.json", isDirectory: false)
  }

  public func loadAll() -> [String: SecretMetadata] {
    guard let data = try? Data(contentsOf: fileURL) else {
      return [:]
    }
    return (try? JSONDecoder().decode([String: SecretMetadata].self, from: data)) ?? [:]
  }

  public func saveAll(_ entries: [String: SecretMetadata]) throws {
    let dir = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(entries)
    try data.write(to: fileURL, options: .atomic)
  }

  public func setMetadata(name: String, env: [String]) throws {
    var all = loadAll()
    all[name] = SecretMetadata(env: env)
    try saveAll(all)
  }

  public func removeMetadata(name: String) throws {
    var all = loadAll()
    if all.removeValue(forKey: name) != nil {
      try saveAll(all)
    }
  }
}

public enum CLIParser {
  public static let version = "0.1.0"

  public static let usageText = """
    touchrun \(version) — Run commands with macOS Keychain secrets gated by Touch ID

    Usage:
      touchrun set <name> [--env VAR1,VAR2,...]   Store or update a secret in macOS Keychain
      touchrun list                               List configured secret names & env mappings
      touchrun status <name>                      Check whether a secret exists in Keychain
      touchrun delete <name>                      Delete a secret from Keychain
      touchrun run <spec...> -- <cmd> [args...]   Prompt Touch ID and exec <cmd> with secrets
      touchrun <spec...> -- <cmd> [args...]       Shorthand for 'touchrun run'

    Secret specs:
      <name>            Inject secret <name> using its configured --env mapping (or <name> itself)
      ENV_VAR=<name>    Inject secret <name> into environment variable ENV_VAR

    Security:
      touchrun has no 'get' or 'print' command. Secrets are injected directly into the
      child process environment after Touch ID approval and never printed to stdout.

    Example:
      touchrun set prod-db --env DATABASE_URL,DB_URI
      touchrun prod-db -- ./scripts/migrate.sh
    """

  public static func isValidSecretName(_ name: String) -> Bool {
    guard !name.isEmpty, !name.hasPrefix("-") else { return false }
    return name.unicodeScalars.allSatisfy { scalar in
      CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" || scalar == "."
    }
  }

  public static func isValidEnvVarName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first else { return false }
    let firstOK = CharacterSet.letters.contains(first) || first == "_"
    guard firstOK else { return false }
    return name.unicodeScalars.dropFirst().allSatisfy { scalar in
      CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }
  }

  public static func parse(_ args: [String]) throws -> Command {
    guard let first = args.first else {
      throw ParseError.missingArguments
    }

    switch first {
    case "-h", "--help", "help":
      return .help
    case "-v", "--version", "version":
      return .version
    case "list", "ls":
      return .list
    case "status":
      guard args.count >= 2 else { throw ParseError.missingArguments }
      let name = args[1]
      guard isValidSecretName(name) else { throw ParseError.invalidSecretName(name) }
      return .status(name: name)
    case "delete", "rm":
      guard args.count >= 2 else { throw ParseError.missingArguments }
      let name = args[1]
      guard isValidSecretName(name) else { throw ParseError.invalidSecretName(name) }
      return .delete(name: name)
    case "set":
      return try parseSet(Array(args.dropFirst()))
    case "run":
      return try parseRun(Array(args.dropFirst()))
    default:
      return try parseRun(args)
    }
  }

  private static func parseSet(_ args: [String]) throws -> Command {
    guard let name = args.first else {
      throw ParseError.missingArguments
    }
    guard isValidSecretName(name) else {
      throw ParseError.invalidSecretName(name)
    }

    var envVars: [String]? = nil
    var idx = 1
    while idx < args.count {
      let arg = args[idx]
      if arg == "--env" || arg == "-e" {
        idx += 1
        guard idx < args.count else {
          throw ParseError.missingOptionValue(arg)
        }
        let parsed = try parseEnvList(args[idx])
        envVars = (envVars ?? []) + parsed
      } else if arg.hasPrefix("--env=") {
        let value = String(arg.dropFirst("--env=".count))
        let parsed = try parseEnvList(value)
        envVars = (envVars ?? []) + parsed
      } else {
        throw ParseError.unknownOption(arg)
      }
      idx += 1
    }

    return .set(name: name, envVars: envVars)
  }

  private static func parseEnvList(_ raw: String) throws -> [String] {
    let parts = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    guard !parts.isEmpty else {
      throw ParseError.invalidEnvVarName(raw)
    }
    for part in parts {
      guard isValidEnvVarName(part) else {
        throw ParseError.invalidEnvVarName(part)
      }
    }
    return parts
  }

  private static func parseRun(_ args: [String]) throws -> Command {
    guard let sepIndex = args.firstIndex(of: "--") else {
      throw ParseError.missingSeparator
    }
    let specArgs = Array(args[..<sepIndex])
    let cmdArgs = Array(args[(sepIndex + 1)...])

    guard !specArgs.isEmpty else {
      throw ParseError.missingSecretSpec
    }
    guard !cmdArgs.isEmpty else {
      throw ParseError.missingCommand
    }

    var specs: [SecretSpec] = []
    for raw in specArgs {
      if let eqIndex = raw.firstIndex(of: "=") {
        let envVar = String(raw[..<eqIndex])
        let secretName = String(raw[raw.index(after: eqIndex)...])
        guard isValidEnvVarName(envVar) else {
          throw ParseError.invalidEnvVarName(envVar)
        }
        guard isValidSecretName(secretName) else {
          throw ParseError.invalidSecretName(secretName)
        }
        specs.append(SecretSpec(secretName: secretName, explicitEnvVar: envVar))
      } else {
        guard isValidSecretName(raw) else {
          throw ParseError.invalidSecretName(raw)
        }
        specs.append(SecretSpec(secretName: raw, explicitEnvVar: nil))
      }
    }

    return .run(specs: specs, command: cmdArgs)
  }

  public static func resolveEnvMappings(
    specs: [SecretSpec],
    metadata: [String: SecretMetadata]
  ) throws -> [(envVar: String, secretName: String)] {
    var mappings: [(envVar: String, secretName: String)] = []
    for spec in specs {
      if let explicit = spec.explicitEnvVar {
        mappings.append((envVar: explicit, secretName: spec.secretName))
      } else if let configured = metadata[spec.secretName]?.env, !configured.isEmpty {
        for envVar in configured {
          mappings.append((envVar: envVar, secretName: spec.secretName))
        }
      } else if isValidEnvVarName(spec.secretName) {
        mappings.append((envVar: spec.secretName, secretName: spec.secretName))
      } else {
        throw ParseError.invalidEnvVarName(spec.secretName)
      }
    }
    return mappings
  }
}
