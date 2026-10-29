# Encrypted packet service

This service stores opaque encrypted packets in a SQLite-compatible `DB`
binding. It supports feeds (`/api/sync`), hunger observations
(`/api/observations`) and pumping (`/api/pumping`). Decryption keys stay on the
paired clients. The implementation has two device-key slots.

```sh
npm test
npm run build
npm run validate
```

Node.js 24 or later is required. Tests use an in-memory database and synthetic
credentials. Runtime checks do not require installing npm dependencies;
`npm ci` installs the schema tooling when needed.

For a separately configured service, apply the SQL files under `drizzle/` in
order and supply `DB`, `DEVICE_A_KEY_HASH` and `DEVICE_B_KEY_HASH` through the
host's private bindings and secret store. Each device authenticates with a
random 32-byte token encoded as 64 lowercase hexadecimal characters; the server
stores its SHA-256 digest. Do not reuse the synthetic test values.

The generic `.openai/hosting.json` contains only the database binding name. No
live service URL, hosting project ID, account credentials or deployment automation
is included. Configure hosting separately; do not deploy this public copy over
an existing private service without reconciling its environment configuration.

On the client, put the exact trusted HTTPS origin in ignored
`Config/Local.xcconfig`, using the same URL escaping as its example. The app
requires a matching endpoint in its separately provisioned Keychain configuration
and refuses credential-bearing redirects. The default `example.invalid` origin
cannot reach a real sync service. Pairing also needs the service access token,
device token, family encryption key and history identity. No provisioning UI or
private provisioning tool is included in this public repository.

## Encrypted Live Activity updates

Remote updates are disabled in default app builds. Free-account builds keep
local Live Activities and foreground history sync, with no push requests or
shared widget keys. The existing service needs no deployment for those builds.

Build 26 adds `POST /api/live-activity`. After uploading and merging saved feeds,
the app publishes an AES-GCM encrypted timer snapshot. A separate display key is
derived on the phones and shared only with their widget extensions through
Keychain. Neither this service nor Apple receives the feed time, kind, volume,
notes or family encryption key in plaintext. The service does see push tokens,
activity lifetimes, update timing and the existing record revision metadata.
Full history still downloads when the app opens; an unfinished breastfeeding
timer stays local. Pumping does not change the last-feed timer.

The service authenticates registration with the existing device credential and
binds it to that credential's slot. A complete revision digest and an atomic
history-version check reject stale snapshots. The latest encrypted snapshot is
the durable outbox; APNs failures leave it pending. Rotated tokens, expired
activities and unregister tombstones are handled without changing feed packets.

For the separately configured private deployment:

1. Apply `0003_live_activity.sql` after the previous migrations. Its two triggers
   advance the history version only when a saved feed actually changes. Keep
   both triggers when maintaining the schema; Drizzle's snapshot does not model
   triggers. Existing packet rows require no rewriting or decryption.
2. Enable Push Notifications for the existing app ID and Keychain Sharing for
   the app and extension. Refresh their signing profiles while retaining the
   original app identifiers, App ID prefix and private Keychain groups.
3. Supply `APNS_PRIVATE_KEY` (PKCS#8 `.p8` contents), `APNS_KEY_ID`, `APNS_TEAM_ID`
   and `APNS_BUNDLE_ID` (`com.jonbright.FelixFeeds`) through the service's private
   secret store. The key must cover the environments used by the installed
   profiles. No key or production identifier belongs in this repository.
4. Configure the host to invoke the worker's `scheduled` handler every minute
   for retrying pending pushes. If the hosting wrapper does not expose scheduled
   handlers, that integration must be provided before promising automatic
   retries while both apps are closed. Client requests also retry pending pushes.
5. In the private signing configuration, set `FELIX_REMOTE_TIMER_UPDATES = YES`,
   `FELIX_APP_ENTITLEMENTS = Config/App.entitlements`, and
   `FELIX_WIDGET_ENTITLEMENTS = Config/LiveActivity.entitlements`.
   Match `FELIX_APNS_ENVIRONMENT` to the app's signed `aps-environment`:
   `development` for sandbox, `production` for distribution. The app sends this
   value with its activity token; the relay selects Apple's corresponding host.
6. Install the updated app on both phones and open each once with sharing and
   the Lock Screen timer enabled. The app requests ActivityKit update tokens,
   observes rotation, and registers the current activity. No notification-alert
   permission prompt is needed for these update tokens.

Deploy the service before the clients. An older service answers 404; the app
reports that remote timer setup is needed and continues normal encrypted sync.
A service without APNs configuration also reports that setup is incomplete.
Keep existing private hosting bindings separate from these public generic names.

This updates an **existing active** Live Activity. Apple's eight-hour lifetime
still applies, and a dismissed/expired activity needs the app opened to start
again. This version does not register push-to-start tokens. APNs delivery can be
delayed or lost offline. The sender gets a bounded iOS background allowance to
finish save-and-lock uploads; expired runtime leaves records in the local ledger
for the next sync. Never use background polling as a substitute for APNs.

Before live rollout, use synthetic histories to verify both directions with the
receiver locked, sender save-and-lock, mixed bottles, corrections/deletions,
token rotation, sharing pause, and a temporary APNs outage. Verify widget key
access while locked after first unlock, English/German rendering, and the
original private Keychain accessibility. Local tests mock APNs and cannot prove
the private host's HTTP/2 delivery, Apple signing setup or locked-device delivery.
