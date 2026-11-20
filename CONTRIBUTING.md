# Contributing

Small, focused changes are welcome. Explain the user-visible result and how you checked it. Keep the steering controller reusable; driving-demo additions should remain optional consumers of the signal.

Before a pull request, run the checks in [DEVELOPMENT.md](docs/DEVELOPMENT.md). Hardware reports should distinguish physical Watch tests from simulated input and include OS versions, sampling/receive rates and test conditions without device IDs or pairing credentials. Do not claim screen-off runtime or latency improvements based only on a successful build.

Do not commit personal signing teams, Xcode user state, tokens, certificates, logs or generated bundles. Use your own untracked local signing configuration. Existing BLE and HTTP/SSE consumers should continue to work unless a protocol change is explicitly documented and tested.
