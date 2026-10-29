# Felix Feeds

A native iPhone feeding tracker built with SwiftUI. Log bottles, breastfeeding
and pumping; review history and trends; export backups; and
see feeding information in a Live Activity. English and German are included.
Requires iOS 17 or later.

This is the original Felix Feeds app, separate from Felix Feeds Next. The initial
public source is based on version 1.8, build 19. It contains no feeding history,
production credentials, live sync endpoint, signing certificates or private
provisioning tool. The app starts empty and works offline. Private sharing needs
separate service configuration and pairing; cloning this repository does not
connect a device to an existing family history.

## Mixed bottles

In **Log a bottle → Type → Mixed bottle**, enter the expressed milk and formula
amounts drunk in ml. The total is calculated automatically and saved as one feed.
Both amounts must be positive and the combined total must be at most 2,000 ml.
History shows the split; daily and rolling totals and Trends include each portion
under its milk type. JSON backups and encrypted feed sharing retain the split.
CSV appends `expressed_millilitres` and `formula_millilitres` columns while keeping
the combined amount in `millilitres`.

The split is an optional `formulaMillilitres` field on an expressed bottle whose
`millilitres` remains the total. Existing records need no migration. Update every
caregiver's app before using mixed bottles: older versions can read the total but
show it as expressed milk and discard the split if they edit that record.

## Get started on a Mac

Install Xcode, open it once to finish setup, and select its command-line tools.
Install XcodeGen with Homebrew (`brew install xcodegen`). Node.js 24 or later
runs the optional backend tests.

```sh
git clone https://github.com/jonbrightdev/felix-feeds-original.git
cd felix-feeds-original
bash scripts/setup.sh
open FelixFeeds.xcodeproj
```

Choose the **FelixFeeds** scheme and an **iPhone simulator**, then press Run.
Simulator builds do not need an Apple signing team or sync credentials.

The generated Xcode project is ignored by Git. Edit `project.yml` for project
settings, then rerun setup. `Config/Local.xcconfig` is also ignored; its tracked
example contains placeholders only. Keep build output outside this repository.

## Contribute directly to main

Collaborators commit and push to `main`; pull requests are not part of this
project's workflow. Public visitors can read the code, but direct writes require
a collaborator invitation and their own GitHub account.

Before starting, pull the latest changes. Coordinate when editing the same files.

```sh
git switch main
git pull --rebase origin main
# Make a small change and try it in the simulator.
bash scripts/check.sh
git diff
# Stage only the files you intend to publish.
git add path/to/changed-file.swift
git diff --cached
git commit -m "Describe the change"
git pull --rebase origin main
git push origin main
```

If rebase reports a conflict, resolve it and rerun the checks before pushing.
Never force-push shared `main`. Commit source changes separately from phone
installation or backend deployment. GitHub Actions checks each push to main.

See [AGENTS.md](AGENTS.md) for project instructions and
[the contribution guide](docs/contributing.md) for an AI-assisted first change.

## Checks

```sh
bash scripts/check.sh
```

This runs the Swift package tests, backend tests, backend artifact validation,
and an unsigned iOS simulator build. Backend tests use synthetic data and an
in-memory SQLite database. They do not contact a live service.

## Private configuration

See [Backend/README.md](Backend/README.md). Local signing and the trusted sync
origin belong in ignored `Config/Local.xcconfig`. Pairing secrets belong in
Keychain or a secret store, never in source, screenshots, issues or logs.
Do not install a development build over an app containing real history without
an explicit installation request and a fresh backup. The bundle IDs match the
original app, so a phone installation can update that app.

Build 26 keeps local Live Activities and foreground encrypted sync enabled in
free-account builds. Remote updates are off by default, with no push entitlement
or push-service requests. Save-and-lock uploads get a bounded background allowance.
Optional encrypted push updates can update the other phone's existing activity
while its app is closed. These require a supported Apple Developer Program team,
private service setup, push credentials, and explicit signing configuration; see
[the deployment and verification requirements](Backend/README.md#encrypted-live-activity-updates).
Full records still download on opening the app. Apple's eight-hour activity
lifetime and offline delivery limits apply.

The iOS content compatibility tests run on a simulator with:

```sh
xcodebuild -project FelixFeeds.xcodeproj -scheme FelixFeeds \
  -destination 'platform=iOS Simulator,name=YOUR_SIMULATOR' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

The source includes offline merge and encrypted-sync support; the public copy
is not a turnkey public sharing service. No App Store distribution is configured.
