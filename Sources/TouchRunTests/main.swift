import Foundation
import TouchRunCore

private var passed = 0
private var failed = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #file, line: Int = #line) {
  if condition() {
    passed += 1
  } else {
    failed += 1
    fputs("FAIL (\(file):\(line)): \(message)\n", stderr)
  }
}

private func runTests() {
  // 1. parse set with --env
  do {
    let cmd = try CLIParser.parse(["set", "prod-db", "--env", "DATABASE_URL,DB_URI"])
    check(
      cmd == .set(name: "prod-db", envVars: ["DATABASE_URL", "DB_URI"]),
      "parseSetWithEnvVars"
    )
  } catch {
    check(false, "parseSetWithEnvVars threw \(error)")
  }

  // 2. parse set with --env=
  do {
    let cmd = try CLIParser.parse(["set", "prod-db", "--env=DATABASE_URL"])
    check(cmd == .set(name: "prod-db", envVars: ["DATABASE_URL"]), "parseSetWithEqualsSyntax")
  } catch {
    check(false, "parseSetWithEqualsSyntax threw \(error)")
  }

  // 3. parse run shorthand & explicit mapping
  do {
    let cmd = try CLIParser.parse([
      "prod-db",
      "API_KEY=prod-api-key",
      "--",
      "./scripts/migrate.sh",
      "--dry-run",
    ])
    check(
      cmd
        == .run(
          specs: [
            SecretSpec(secretName: "prod-db", explicitEnvVar: nil),
            SecretSpec(secretName: "prod-api-key", explicitEnvVar: "API_KEY"),
          ],
          command: ["./scripts/migrate.sh", "--dry-run"]
        ),
      "parseRunShorthandAndExplicitMapping"
    )
  } catch {
    check(false, "parseRunShorthandAndExplicitMapping threw \(error)")
  }

  // 4. parse run requires separator & command
  do {
    _ = try CLIParser.parse(["prod-db", "./scripts/migrate.sh"])
    check(false, "missingSeparator should throw")
  } catch let err as ParseError {
    check(err == .missingSeparator, "missingSeparator error mismatch: \(err)")
  } catch {
    check(false, "unexpected error: \(error)")
  }

  do {
    _ = try CLIParser.parse(["prod-db", "--"])
    check(false, "missingCommand should throw")
  } catch let err as ParseError {
    check(err == .missingCommand, "missingCommand error mismatch: \(err)")
  } catch {
    check(false, "unexpected error: \(error)")
  }

  // 5. resolve env mappings
  do {
    let metadata: [String: SecretMetadata] = [
      "prod-db": SecretMetadata(env: ["DATABASE_URL", "DB_URI"])
    ]
    let resolved = try CLIParser.resolveEnvMappings(
      specs: [
        SecretSpec(secretName: "prod-db"),
        SecretSpec(secretName: "API_TOKEN"),
        SecretSpec(secretName: "other-secret", explicitEnvVar: "CUSTOM_VAR"),
      ],
      metadata: metadata
    )
    check(resolved.count == 4, "resolved count == 4")
    check(resolved[0].envVar == "DATABASE_URL" && resolved[0].secretName == "prod-db", "mapping 0")
    check(resolved[1].envVar == "DB_URI" && resolved[1].secretName == "prod-db", "mapping 1")
    check(resolved[2].envVar == "API_TOKEN" && resolved[2].secretName == "API_TOKEN", "mapping 2")
    check(resolved[3].envVar == "CUSTOM_VAR" && resolved[3].secretName == "other-secret", "mapping 3")
  } catch {
    check(false, "resolveEnvMappings threw \(error)")
  }

  // 6. metadata store round-trip
  do {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = MetadataStore(fileURL: tempDir.appendingPathComponent("secrets.json"))
    try store.setMetadata(name: "prod-db", env: ["DATABASE_URL", "DB_URI"])
    check(store.loadAll()["prod-db"]?.env == ["DATABASE_URL", "DB_URI"], "metadata save/load")

    try store.removeMetadata(name: "prod-db")
    check(store.loadAll()["prod-db"] == nil, "metadata remove")
  } catch {
    check(false, "metadataStoreRoundTrip threw \(error)")
  }

  print("TouchRunTests: \(passed) passed, \(failed) failed")
  if failed > 0 {
    exit(1)
  }
}

runTests()
