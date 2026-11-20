# Security boundaries

WatchSteer is an experimental local controller, not a remotely operated vehicle system.

- The default Mac relay binds to `127.0.0.1`; no tunnel or public server starts automatically.
- A fresh random token is created on first launch. macOS stores it under the current user's Application Support directory (directory mode 0700, token mode 0600). The Watch stores its token in Keychain.
- BLE uses fresh mutual nonce challenges, HMAC-SHA256 verification, HKDF-SHA256 session keys and ChaCha20-Poly1305 authenticated payloads. Session keys and sequence checks reject stale/replayed packets. This custom shared-secret protocol has not received an independent security audit and does not provide forward secrecy if the token is compromised.
- The native app redeems a short-lived one-use browser ticket for a read-only HttpOnly, SameSite cookie. The shared device token is not placed in browser URLs or local storage. Tickets briefly travel in a URL fragment and are cleared after redemption.
- Browser read authorization cannot write steering values. Ingest requires the device bearer token. Origin checks, static-file allowlists and bounded queues reduce exposure; another process running as the same local user remains within the trust boundary.
- Stale samples pause the demo. Never use this project to steer a real vehicle.

Do not publish pairing tokens, Keychain exports, private certificates, device identifiers or signing profiles. To report a vulnerability, use GitHub private vulnerability reporting when available; otherwise open a minimal issue asking for a private reporting channel without posting secrets or exploit credentials.
