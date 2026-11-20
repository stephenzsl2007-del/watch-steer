# Building and checking

## Browser demo

Python 3.10+ is sufficient. All 18 original CC0 material maps and the vendored rendering/physics engines are included.

```sh
python3 tools/build_web.py
python3 tools/run_local.py
```

Open http://127.0.0.1:8765/ and use the explicitly labeled keyboard preview. `tools/fetch_assets.py` can restore missing maps from their recorded upstream URLs; every map is SHA-256 checked. `web/app.js` is generated and ignored by Git.

## Native source receiver

On macOS with full Xcode, command-line tools and Python:

```sh
python3 tools/run_bluetooth.py
```

The launcher builds `desktop/WatchSteer 接收器.app` when absent. Rebuild after source changes with `python3 tools/build_mac.py`. Daily connection uses BLE, and the service stays on loopback. Pairing state is in the current user's Application Support directory, not the checkout. `WATCHSTEER_STATE_DIR` may point to an isolated directory for tests.

## Standalone Mac app

On an Apple Silicon Mac with full Xcode and Python 3.12:

```sh
python3.12 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements-build.txt
python tools/build_standalone.py
```

Output: `desktop/WatchSteer.app`. The build includes Python, web assets and third-party notices, uses ad-hoc signing and verifies its signature. It does not perform Apple notarization. The source receiver also supports host-architecture compilation, but only the arm64 standalone download is validated for this release.

## Checks

```sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 tools/check_public_tree.py
swiftc watch/SteeringMath.swift tests/SteeringMathTests.swift -o /tmp/watchsteer-math-tests
/tmp/watchsteer-math-tests
swiftc shared/BLEProtocol.swift tests/BLEProtocolTests.swift -o /tmp/watchsteer-ble-tests
/tmp/watchsteer-ble-tests
xcodebuild -project watch/WatchSteer.xcodeproj -scheme WatchSteer \
  -sdk watchos -destination 'generic/platform=watchOS' \
  -derivedDataPath work/DerivedData CODE_SIGNING_ALLOWED=NO build
npm ci
npx playwright install chromium
npm run test:physics
npm run test:browser
```

Node 20+ and Playwright are development-only dependencies. Browser QA uses software rendering by default; `WATCHSTEER_GPU_TEST=1` opts into Chromium Metal checks on a supported Mac. Screenshots and reports go to ignored `work/test-results/`. They are synthetic tests, not physical Watch latency measurements.

Release packaging uses a clean checkout, builds the app, scans extracted artifacts and creates the DMG, source ZIP and SHA-256 manifest. Do not publish a development-signed Watch binary or any state from Application Support. A physical Watch session is required to claim hardware behavior beyond the build/unit checks.

To package a committed source tree after building and scanning the app:

```sh
python3 tools/package_release.py --app desktop/WatchSteer.app --output dist
```

To re-record the README scene, install the development browser dependencies, build the web bundle, then run `node tools/record_demo.cjs`. It writes 60 explicitly simulated frames to `work/demo-frames/` and two curated scene screenshots to `docs/media/`; encode selected frames into a small looping GIF for the README. This does not record or claim physical Watch input.

An optional GitHub Actions template is included as [ci.example.yml](ci.example.yml). Copy it into `.github/workflows/checks.yml` to enable it; the published release was checked locally.
