# Architecture and steering interface

## Data path

1. The Watch SwiftUI app reads `CMMotionManager.deviceMotion` on a serial operation queue. Quaternion-relative rotation around the selected axis produces a calibrated angle; dead zone, clamping and smoothing produce a continuous steering value.
2. Core Bluetooth connects the Watch central to the Mac peripheral. Fresh mutual challenges authenticate a shared random token. HKDF derives a per-session key; ChaCha20-Poly1305 encrypts steering and acknowledgement payloads. Fragmentation, sequence checks, backpressure and bounded latest-value queues avoid replaying an accumulated motion backlog.
3. The Swift Mac receiver authenticates HTTP ingest into the bundled Python service on loopback. Its ACK follows successful local ingest; the reported RTT therefore includes BLE and the local relay, not browser rendering.
4. The browser consumes SSE and renders a steering wheel or the optional driving demo. A single-use ticket gives the browser read-only access. The car cruises automatically; stale Watch input pauses it.

BLE UUIDs and packet formats live in `shared/BLEProtocol.swift`. Both compact and legacy sample decoding are retained. Pairing state and saved calibration are device-local; neither is exported with the project.

## Existing local interface

The following example is a representative sample, not measured hardware telemetry:

```json
{
  "session": "example-session",
  "seq": 1,
  "steering": 0.35,
  "angleDeg": 21,
  "sampleHz": 50,
  "sampleAgeMs": 4,
  "rttMs": 18,
  "calibrated": true
}
```

- `POST /api/steer`: device-token bearer authorization; submits the sample shape above. `steering` is −1 for left, 0 for neutral and +1 for right.
- `GET /api/state`: authenticated snapshot with `sample`, `serverAgeMs`, connection/freshness state and receive-rate metadata.
- `GET /api/events`: authenticated SSE stream of state snapshots; inspect `sample.steering` and freshness rather than using the last value indefinitely.
- `POST /api/login`: exchanges a token for a read-only browser cookie. The native app instead uses `/api/browser-ticket` and `/api/browser-redeem` for automatic one-use browser authorization.

The bundled browser demonstrates EventSource cookie authorization. Native local integrations may use the bearer token to read `/api/state`. Keep credentials out of source, logs and URL query strings. The default service is for one trusted local controller and local visualizations, not a public multi-user backend.

## Timing and lifecycle

Configured targets: 50 Hz motion sampling, up to 30 Hz BLE submissions, two in-flight samples, throttled UI updates. These are not guaranteed delivered rates. The relay/browser consider input stale after about 500 ms. Sampling, radio scheduling, filtering, ACKs and frame presentation all affect latency. No public end-to-end latency number is claimed for this release.

Foreground-inactive callback sampling is implemented but broader hardware validation is pending. watchOS may suspend work when the screen dims, wrist lowers or app backgrounds. The app does not start a fake workout, audio session or unrelated extended-runtime category to bypass lifecycle rules.
