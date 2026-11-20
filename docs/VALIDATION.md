# Validation: v0.1.0-alpha.1

Release checks performed on 2026-11-20–21 using an Apple Silicon Mac, macOS 27.0.1, Xcode 27.2, Python 3.12.14 / PyInstaller 6.22.0, and Playwright 1.62.1. Deployment targets are not a claim of testing every supported OS.

| Check | Result |
| --- | --- |
| Backend and per-user pairing state | 13 automated tests passed: authorization, origin checks, read-only cookies, single-use tickets, validation, freshness, queue behavior, distinct private tokens and persistence. |
| Steering mathematics | Passed neutral quaternion, axes, inversion, wrap, cross-axis rejection, dead zone, filtering and saturation checks. |
| BLE protocol | Passed mutual authentication, fresh sessions, encryption, tamper rejection, MTU fragmentation, packet loss/expiry and sample validation checks. |
| Watch app | Clean project built for physical watchOS with code signing disabled and no personal signing team. |
| Driving physics | Simulated full 6.1 km loop passed steering, braking, suspension, collision, road continuity and bounded body-count checks. |
| Browser integration | Chromium Metal checks passed simulated steering → HTTP → SSE → wheel/car, stale-data pause, ticket redemption, responsive layout and absence of JavaScript errors. |
| Garage | Four finite distinct models, paused switching, odometer retention, inspect/orbit, paint, session preferences, bounded cache and mobile layout passed. |
| Standalone Mac app | arm64 build and strict ad-hoc signature verification passed. Bundled service and WebKit scene opened with fresh isolated state; no external Python required. Existing state directories are restricted to 0700, token files to 0600; saved pairing persists. |
| Dependency lock | `npm ci` installed the locked official development dependencies successfully. |
| Privacy | Public source and app scanned against known private identifiers and tokens; frozen Python code objects also inspected. No matching private fingerprints found. |

Earlier physical-device sessions confirmed Watch-to-Mac BLE steering, saved calibration and reconnection using a Series 11 on watchOS 27.2.1. The current callback-based sampling/lower-UI-update path has a successful build and automated checks but has not completed a new physical Watch validation session. No new latency or screen-off-runtime claim is made for the public release.

README recordings use explicitly simulated input. Unit/browser tests and local loopback timing are not physical-radio or input-to-photon benchmarks. The download is an experimental arm64 build, not Developer ID signed or Apple notarized. Intel Macs and older deployment-target OS versions have not been validated for the standalone download.
