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
