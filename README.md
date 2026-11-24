# touchrun

Run commands with secrets from macOS Keychain, gated by **Touch ID** — built for safe use with AI coding agents and local scripts.

## Why?

When an AI agent needs to run a production migration or diagnostic script against a database or API, pasting secrets into chat puts credentials in transcripts and model context.

`touchrun` keeps secrets out of the conversation:
- **Write-only / inject-only:** There is no `get` or `print` command. Secrets are injected directly into the child process environment (`execvp`) and never printed to stdout.
- **Per-command Touch ID approval:** Every run triggers a native macOS Touch ID prompt showing the exact secret names, target environment variables, and command about to execute.
- **Keychain ACL scoped to `touchrun`:** Stored in your macOS Login Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) with an ACL restricted to the installed `touchrun` binary.

## Install

Requires macOS 13+ and Xcode Command Line Tools (`swift`).

```sh
make install
```

This builds a release binary and installs it to `~/.local/bin/touchrun` (ad-hoc code-signed).

## Usage

### 1. Store a secret (one-time)

```sh
touchrun set prod-db --env DATABASE_URL,DB_URI
```

You'll be prompted for the value with terminal echo disabled (or pipe via stdin).

### 2. Run a command with Touch ID approval

```sh
touchrun prod-db -- ./scripts/migrate.sh
```

You can also bind secrets to explicit environment variable names or pass multiple secrets:

```sh
touchrun DATABASE_URL=prod-db API_KEY=prod-api-key -- ./scripts/sync.sh
```

### 3. Manage stored secrets

```sh
touchrun list
touchrun status prod-db
touchrun delete prod-db
```

## AI Agent Skill

A ready-to-use skill is included at [`skills/touchrun/SKILL.md`](./skills/touchrun/SKILL.md) so coding agents automatically know to invoke `touchrun` instead of asking you to paste secrets.
