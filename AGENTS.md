# Project instructions

This is the original Felix Feeds iOS app. Felix Feeds Next is a separate project.

## Workflow

- Work directly on `main`. Do not create branches or pull requests unless asked.
- Pull with rebase before work and again before pushing. Never force-push main.
- Keep commits focused. Review the staged diff before every commit.
- Run the checks relevant to a change; `bash scripts/check.sh` is the full check.
- Use the simulator with synthetic records. A code change does not authorise
  installation on a real phone, pairing, backend deployment or real-data edits.
- Preserve unrelated uncommitted work and resolve concurrent changes carefully.

## Build and structure

- `bash scripts/setup.sh` creates ignored local config if missing and generates
  the Xcode project. Change `project.yml`, not the generated project.
- `App/`: SwiftUI UI and local storage. `Core/`: domain, merge, encryption, tests.
- `Shared/` and `LiveActivity/`: shared attributes and Lock Screen extension.
- `Backend/`: encrypted packet service, SQLite schema and synthetic tests.
- Preserve compatibility with saved records, encrypted metadata and existing
  bundle IDs. Unknown breastfeeding volume stays unknown; never derive ml from
  elapsed time. Pumped volume is separate from milk drunk.
- Maintain English and German strings together and respect Reduce Motion,
  larger text, light and dark appearance.

## Public repository

- Never commit credentials, private endpoints, family records, device identifiers,
  signing identities, provisioning profiles, personal correspondence or backups.
- Local config is `Config/Local.xcconfig`, ignored by Git. Keep secrets in Keychain
  or a secret store; never paste them into terminal commands, logs or chat.
- Do not copy private source documentation or historical screenshots into this
  repository. Use fictional data for any new documentation or screenshots.
- Run `gitleaks dir --redact --no-banner .` before publishing new configuration.
- Keep production service configuration separate. Public backend environment
  names are generic and differ from a privately deployed service.
