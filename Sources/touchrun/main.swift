import Darwin
import Foundation
import TouchRunCore

private func stderrPrint(_ message: String) {
  if let data = (message + "\n").data(using: .utf8) {
    FileHandle.standardError.write(data)
  }
}

private func readSecretInput(name: String) -> String? {
  if isatty(STDIN_FILENO) == 1 {
    stderrPrint("Enter secret for '\(name)' (input hidden), then press Enter:")
    var oldTerm = termios()
    tcgetattr(STDIN_FILENO, &oldTerm)
    var newTerm = oldTerm
    newTerm.c_lflag &= ~UInt(ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &newTerm)
    defer {
      tcsetattr(STDIN_FILENO, TCSANOW, &oldTerm)
      stderrPrint("")
    }
    return readLine(strippingNewline: true)
  } else {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
  }
}

private func runMain() -> Int32 {
  let args = Array(CommandLine.arguments.dropFirst())
  let command: Command
  do {
    command = try CLIParser.parse(args)
  } catch {
    stderrPrint("error: \(error)")
    return 2
  }

  let keychain = KeychainStore()
  let metadataStore = MetadataStore()

  switch command {
  case .help:
    print(CLIParser.usageText)
    return 0

  case .version:
    print("touchrun \(CLIParser.version)")
    return 0

  case .set(let name, let envVars):
    guard let raw = readSecretInput(name: name) else {
      stderrPrint("error: no input received.")
      return 1
    }
    let secret = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !secret.isEmpty else {
      stderrPrint("error: secret value cannot be empty.")
      return 1
    }

    do {
      try keychain.save(name: name, secret: secret)
      if let envVars {
        try metadataStore.setMetadata(name: name, env: envVars)
        print("Saved secret '\(name)' in macOS Keychain (default env: \(envVars.joined(separator: ", "))).")
      } else {
        print("Saved secret '\(name)' in macOS Keychain.")
      }
      return 0
    } catch {
      stderrPrint("error: \(error)")
      return 1
    }

  case .list:
    do {
      let names = try keychain.listNames()
      let metadata = metadataStore.loadAll()
      if names.isEmpty {
        print("No secrets stored yet. Run 'touchrun set <name> --env VAR' to add one.")
        return 0
      }
      for name in names {
        if let env = metadata[name]?.env, !env.isEmpty {
          print("\(name)\t-> \(env.joined(separator: ", "))")
        } else if CLIParser.isValidEnvVarName(name) {
          print("\(name)\t-> \(name)")
        } else {
          print("\(name)\t-> (pass ENV_VAR=\(name) when running)")
        }
      }
      return 0
    } catch {
      stderrPrint("error: \(error)")
      return 1
    }

  case .status(let name):
    do {
      if try keychain.exists(name: name) {
        let metadata = metadataStore.loadAll()
        if let env = metadata[name]?.env, !env.isEmpty {
          print("configured: \(name) (env: \(env.joined(separator: ", ")))")
        } else {
          print("configured: \(name)")
        }
        return 0
      } else {
        print("not configured: \(name)")
        return 1
      }
    } catch {
      stderrPrint("error: \(error)")
      return 1
    }

  case .delete(let name):
    do {
      let deleted = try keychain.delete(name: name)
      try metadataStore.removeMetadata(name: name)
      if deleted {
        print("Deleted secret '\(name)' from macOS Keychain.")
      } else {
        print("Secret '\(name)' was not found in macOS Keychain.")
      }
      return 0
    } catch {
      stderrPrint("error: \(error)")
      return 1
    }

  case .run(let specs, let cmdArgs):
    do {
      let metadata = metadataStore.loadAll()
      let mappings = try CLIParser.resolveEnvMappings(specs: specs, metadata: metadata)

      // Deduplicate secret names preserving order for pre-check & read.
      var uniqueSecretNames: [String] = []
      var seen = Set<String>()
      for mapping in mappings {
        if seen.insert(mapping.secretName).inserted {
          uniqueSecretNames.append(mapping.secretName)
        }
      }

      // Fail fast if any requested secret does not exist before prompting Touch ID.
      for name in uniqueSecretNames {
        guard try keychain.exists(name: name) else {
          throw KeychainError.notFound(name)
        }
      }

      try TouchIDGate.authenticate(
        secretNames: uniqueSecretNames,
        envVars: mappings.map(\.envVar),
        command: cmdArgs
      )

      var loadedSecrets: [String: String] = [:]
      for name in uniqueSecretNames {
        loadedSecrets[name] = try keychain.read(name: name)
      }

      for mapping in mappings {
        if let value = loadedSecrets[mapping.secretName] {
          setenv(mapping.envVar, value, 1)
        }
      }

      var cArgs: [UnsafeMutablePointer<CChar>?] = cmdArgs.map { strdup($0) }
      cArgs.append(nil)

      execvp(cmdArgs[0], &cArgs)

      let err = String(cString: strerror(errno))
      stderrPrint("error: failed to exec '\(cmdArgs[0])': \(err)")
      return 127
    } catch let err as KeychainError {
      stderrPrint("error: \(err)")
      if case .authFailed = err {
        return 126
      }
      return 1
    } catch {
      stderrPrint("error: \(error)")
      return 1
    }
  }
}

exit(runMain())
