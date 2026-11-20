# Setup and troubleshooting

## Mac

The downloadable arm64 DMG is self-contained. Drag WatchSteer into Applications, open it and allow Bluetooth. The receiver starts its own loopback service on port 8765; keep the app running and the Mac awake. No Wi-Fi setup is required for BLE operation. The first public build is ad-hoc signed and not notarized; use Apple's documented Privacy & Security → Open Anyway flow if required. Do not disable system-wide protections.

## Watch

Open `watch/WatchSteer.xcodeproj` in full Xcode. Select your own Signing Team and a unique Bundle Identifier, then choose your physical Apple Watch and Run. The repository contains no account, device registration or provisioning profile. Your paired iPhone may be needed for initial development pairing/trust. Complete Developer Mode and Xcode's device preparation first. Xcode must support your actual device OS; do not interpret build success as a physical connection test.

On the Mac choose **手表连接 → 复制配对令牌**. Enter it once in WatchSteer settings on the Watch; use the paired iPhone's keyboard prompt if available. Choose **蓝牙直连 → 连接电脑 → WatchSteer Mac**. Once authenticated, the app remembers the receiver. This is application-level pairing, separate from Xcode development pairing.

Hold the wrist in your intended straight-ahead pose and tap **校准正中 / 设为正中**. Turn left and right. Default X is the screen-plane left/right axis; Y follows the strap; Z points through the screen. If the wrong movement changes steering, select the appropriate axis and recalibrate. Use direction inversion if left and right are reversed. Saved neutral attitude is reused only when the reference-frame conditions allow it; recalibrate after changing your pose or axis.

## Common issues

| Symptom | Check |
| --- | --- |
| No nearby Mac | Mac app running and Bluetooth allowed on both devices; keep them nearby; no second receiver copy running. |
| Token mismatch | Copy the token from the Mac app currently running and replace the Watch token once; do not put it in a URL or issue. |
| Connected but car does not move | Calibrate, confirm receive counts/rate increase, and start driving. Authentication alone does not prove fresh samples are arriving. |
| Car pauses after dimming | Keep the Watch app active. Wake Duration 70 seconds and a longer Return to Clock setting may help interaction but cannot grant background runtime. |
| Xcode cannot install | Check Developer Mode, trust, supported OS/device components and the paired iPhone's connection; this is independent of daily BLE operation. |
| Unstyled page or no scene | Build `web/app.js` and open the local server URL. Do not double-click `index.html`. |
| Port 8765 already occupied | Quit the previous receiver/server. A service using another token is not silently adopted. |

The optional HTTPS transport uses URLSession and requires a reachable server with a valid trusted HTTPS certificate. It is an advanced path, not needed for BLE. No personal CA or LAN hostname is shipped, and no public tunnel is launched automatically.
