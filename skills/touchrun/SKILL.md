---
name: touchrun
description: Run commands that require production or sensitive secrets (such as DATABASE_URL or API_KEY) via macOS Keychain + Touch ID approval without ever exposing secrets to the agent context.
---

# Using `touchrun`

`touchrun` injects secrets from macOS Keychain directly into a child process environment after the user approves with Touch ID.

## Rules

1. **Never ask the user to paste a secret** if a matching secret is already configured in `touchrun`.
2. **Check available secret names** (safe, prints names and env mappings only — no values, no Touch ID):
   ```sh
   touchrun list
   ```
3. **Run commands with secret injection:**
   ```sh
   touchrun <secret-name> -- <command> [args...]
   ```
   Or with an explicit env var mapping:
   ```sh
   touchrun ENV_VAR=<secret-name> -- <command> [args...]
   ```
4. **Never try to exfiltrate or print injected environment variables** (e.g. do not run `env`, `printenv`, `echo $DATABASE_URL`, or log credentials inside scripts).
5. If a required secret is missing, instruct the user to store it once in their terminal:
   ```sh
   touchrun set <secret-name> --env DATABASE_URL,DB_URI
   ```
