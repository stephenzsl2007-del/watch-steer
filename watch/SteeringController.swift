import Foundation
import Combine
import CoreMotion
import Security

enum TokenStore {
    static let service = "WatchSteer.pairing"
    static func read() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "token",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    @discardableResult static func write(_ token: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "token"]
        let values: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if result == errSecItemNotFound {
            return SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess
        }
        return result == errSecSuccess
    }
}

private struct Sample: Encodable {
    let session: String
    let seq: Int
    let steering: Double
    let angleDeg: Double
    let sampleHz: Double
    let sampleAgeMs: Double
    let rttMs: Double
    let calibrated: Bool
}

enum ConnectionMode: String, CaseIterable, Identifiable {
    case bluetooth, https
    var id: String { rawValue }
    var label: String { self == .bluetooth ? "蓝牙直连" : "HTTPS（高级）" }
}

enum SteeringAxis: String, CaseIterable, Identifiable {
    case x, y, z, learned
    var id: String { rawValue }
    var label: String {
        switch self {
        case .x: return "X · 屏幕左右轴"
        case .y: return "Y · 表带方向轴"
        case .z: return "Z · 垂直屏幕轴"
        case .learned: return "按右转动作识别"
        }
    }
    var vector: SIMD3<Double>? {
        switch self {
        case .x: return SIMD3(1, 0, 0)
        case .y: return SIMD3(0, 1, 0)
        case .z: return SIMD3(0, 0, 1)
        case .learned: return nil
        }
    }
}

private enum TransportFailure: Error { case http(Int), invalidACK }


@MainActor
final class SteeringController: ObservableObject {
    @Published var baseURL = UserDefaults.standard.string(forKey: "server") ?? ""
    @Published var token = ""
    @Published private(set) var preparing = true
    @Published private(set) var credentialNotice = ""
    private var prepared = false
    @Published var connectionMode = ConnectionMode(rawValue: UserDefaults.standard.string(forKey: "connectionMode") ?? "") ?? .bluetooth
    @Published private(set) var nearbyMacs: [NearbyMac] = []
    private let bluetooth = BluetoothTransport()
    private var bluetoothTick = 0.0
    private var bluetoothRateStart = 0.0
    private var bluetoothCount = 0
    @Published private(set) var session = ControlSession()
    var running: Bool { session.started }
    var paused: Bool { running && !session.foreground }
    @Published private(set) var calibrated = false
    @Published private(set) var value = 0.0
    @Published private(set) var angle = 0.0
    @Published private(set) var sampleHz = 0.0
    @Published private(set) var sendHz = 0.0
    @Published private(set) var rttMs = 0.0
    @Published private(set) var status = "准备开始 · 左滑查看连接设置"
    @Published private(set) var calibrationStatus = "保持正中，再校准"
    @Published private(set) var selectedAxis: SteeringAxis = .x
    @Published private(set) var hasLearnedAxis = false

    private(set) var isInterfacePreview = false

    init() {
        let environment = ProcessInfo.processInfo.environment
        let configured = Bundle.main.object(forInfoDictionaryKey: "WatchSteerLocalServer") as? String
        if let server = environment["WATCHSTEER_SERVER"] ?? configured,
           let parts = URLComponents(string: server), parts.scheme == "https", parts.host != nil {
            baseURL = server
            UserDefaults.standard.set(server, forKey: "server")
        }
        if let credential = environment["WATCHSTEER_TOKEN"], credential.count >= 24 {
            token = credential
        }

        bluetooth.onStatus = { [weak self] message in
            guard let self, self.running, !self.session.localOnly, self.connectionMode == .bluetooth else { return }
            if self.status != message { self.status = message }
            if message != "已连接" { self.sendHz = 0 }
        }
        bluetooth.onPeers = { [weak self] peers in self?.nearbyMacs = peers }
        bluetooth.onACK = { [weak self] rtt in
            guard let self else { return }
            self.latestRTT = rtt
            self.bluetoothCount += 1
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.bluetoothRateStart >= 1 {
                self.rttMs = rtt
                self.sendHz = Double(self.bluetoothCount) / (now - self.bluetoothRateStart)
                self.bluetoothRateStart = now; self.bluetoothCount = 0
            }
        }

        #if DEBUG
        if environment["WATCHSTEER_UI_PREVIEW"] == "control" {
            isInterfacePreview = true
            session.start(localOnly: true)
            value = 0.42; angle = 26
            calibrated = true
            status = "界面预览 · 模拟数据"
            calibrationStatus = "X 轴 · 屏幕左右方向"
        }
        #endif

    }

    private lazy var motion = CMMotionManager()
    private var math = SteeringMath()
    private let motionQueue: OperationQueue = {
        let q = OperationQueue(); q.name = "WatchSteer.motion"; q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated; return q
    }()
    private var sensorGeneration = UUID()
    private var callbackCount = 0
    private var measuredSampleHz = 0.0
    private var latestRTT = 0.0
    private var streamValue = 0.0
    private var streamAngle = 0.0
    private var lastUIUpdate = 0.0
    private var sender: Task<Void, Never>?
    private var latest: Quaternion?
    private var sampleTimestamp = 0.0
    private var previousTimestamp = 0.0
    private var diagnosticTime = 0.0
    private var referenceFrame = CMAttitudeReferenceFrame.xArbitraryZVertical
    private var sensorStarts = 0
    private var activeTransitions = 0
    private var inactiveTransitions = 0
    private var interactive = true
    private var savedCalibration: SavedCalibration? {
        guard let data = UserDefaults.standard.data(forKey: "calibrationV1"),
              let profile = try? JSONDecoder().decode(SavedCalibration.self, from: data), profile.valid else { return nil }
        return profile
    }
    private var fixedHeading: Bool {
        referenceFrame == .xMagneticNorthZVertical || referenceFrame == .xTrueNorthZVertical
    }
    private func saveCalibration() {
        guard let profile = SavedCalibration(math: math, referenceFrame: referenceFrame.rawValue),
              let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: "calibrationV1")
        UserDefaults.standard.set(selectedAxis.rawValue, forKey: "steeringAxis")
        UserDefaults.standard.set(math.inverted, forKey: "steeringInverted")
    }
    private var generation = UUID()
    private lazy var network: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 1
        config.httpShouldSetCookies = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: LocalServerTrust(), delegateQueue: queue)
    }()

    private func endpoint() -> URL? {
        guard var c = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "https", let host = c.host,
              host != "steer.example.com", host != "localhost", host != "127.0.0.1", host != "::1",
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/" else { return nil }
        c.path = "/api/steer"
        return c.url
    }

    func start(localOnly: Bool = false) {
        guard !running else { return }
        let url: URL?
        if localOnly {
            url = nil
        } else if connectionMode == .bluetooth {
            guard token.count >= 24, token.utf8.allSatisfy({ $0 < 128 }) else {
                status = "首次连接：从 Mac 接收器复制配对令牌"; return
            }
            url = nil
        } else {
            guard let destination = endpoint(), token.count >= 24, token.utf8.allSatisfy({ $0 < 128 }) else {
                status = "请填写实际 HTTPS 地址和令牌"; return
            }
            url = destination
        }
        guard motion.isDeviceMotionAvailable else { status = "无姿态数据，请使用真机"; return }
        guard CMMotionManager.availableAttitudeReferenceFrames().contains(.xArbitraryZVertical) else {
            status = "此设备不支持所需姿态参考系"; return
        }
        if url != nil {
            UserDefaults.standard.set(baseURL, forKey: "server")
        }
        if !localOnly { persistCredential() }
        if let axis = UserDefaults.standard.string(forKey: "steeringAxis").flatMap(SteeringAxis.init(rawValue:)) {
            selectedAxis = axis
        }
        if selectedAxis == .learned, let profile = savedCalibration {
            math.axis = SIMD3(profile.axis[0], profile.axis[1], profile.axis[2]); hasLearnedAxis = true
        } else { math.axis = selectedAxis.vector ?? SIMD3(1, 0, 0) }
        math.inverted = UserDefaults.standard.bool(forKey: "steeringInverted")
        calibrated = math.zero != nil
        calibrationStatus = "保持正中，再校准；轴可在下方切换"
        previousTimestamp = 0
        latest = nil
        sampleHz = 0; sendHz = 0; rttMs = 0
        UserDefaults.standard.set(connectionMode.rawValue, forKey: "connectionMode")
        session.start(localOnly: localOnly)
        status = localOnly ? "仅手表测试 · 未联网" : "正在连接…"
        activateSampling()
    }

    func prepare() async {
        guard !prepared else { return }
        prepared = true
        let injected = token
        // Keychain IPC must not block the first frame or its controls.
        let saved = await Task.detached(priority: .userInitiated) {
            if !injected.isEmpty { return (injected, TokenStore.write(injected)) }
            return (TokenStore.read(), true)
        }.value
        if token.isEmpty { token = saved.0 }
        if !saved.1 { credentialNotice = "令牌未能保存，请确认手表已解锁" }
        preparing = false
    }
    private func persistCredential() {
        let credential = token
        Task { [weak self] in
            let ok = await Task.detached(priority: .utility) { TokenStore.write(credential) }.value
            guard let self, self.token == credential else { return }
            self.credentialNotice = ok ? "" : "本次可连接，但令牌未保存；请解锁后重试"
        }
    }

    private var attemptedAutoStart = false
    func autoStartIfRequested() {
        guard !isInterfacePreview, !attemptedAutoStart else { return }
        attemptedAutoStart = true
        if ProcessInfo.processInfo.environment["WATCHSTEER_AUTOCONNECT"] == "1" { start() }
    }

    func sceneChanged(active: Bool, background: Bool = false) {
        guard !isInterfacePreview else { return }
        interactive = active
        if active { activeTransitions += 1 } else { inactiveTransitions += 1 }
        // Dimmed but frontmost is still foreground. Do not voluntarily stop
        // streaming here; watchOS may limit runtime. True background pauses work.
        let foreground = !background
        guard session.foreground != foreground else {
            // Re-prime a sensor stream that did not resume after an inactive interval.
            if active, running, sampleTimestamp > 0, ProcessInfo.processInfo.systemUptime - sampleTimestamp > 0.5 {
                sensorGeneration = UUID(); motion.stopDeviceMotionUpdates(); activateSampling()
            }
            recordDiagnostics(force: true); return
        }
        session.setForeground(foreground)
        guard running else { return }
        if foreground {
            activateSampling()
        } else {
            suspendSampling(stopSensors: true, disconnect: false)
            status = "已进入后台 · 抬腕打开后恢复"
            recordDiagnostics(force: true)
        }
    }

    private func activateSampling() {
        guard session.sampling else { return }
        sender?.cancel(); sender = nil
        math.filtered = 0; math.lastTimestamp = nil
        previousTimestamp = 0; sampleTimestamp = 0
        value = 0; angle = 0
        status = session.localOnly ? "本地测试 · 未联网" : "正在连接…"
        if !motion.isDeviceMotionActive {
            let available = CMMotionManager.availableAttitudeReferenceFrames()
            referenceFrame = available.contains(.xMagneticNorthZVertical) ? .xMagneticNorthZVertical : .xArbitraryZVertical
            calibrated = false; math.zero = nil
            if let profile = savedCalibration,
               profile.restore(into: &math, referenceFrame: referenceFrame.rawValue, fixedHeading: fixedHeading) {
                calibrated = true; calibrationStatus = "已恢复保存的正中"
            } else {
                calibrationStatus = savedCalibration == nil ? "请保持正中，点击校准" : "已保存上次正中；姿态参照重启，请重新校准"
            }
            sensorStarts += 1
            motion.deviceMotionUpdateInterval = 1.0 / 50.0
            sensorGeneration = UUID()
            let sensorID = sensorGeneration
            motion.startDeviceMotionUpdates(using: referenceFrame, to: motionQueue) { [weak self] sample, _ in
                guard let sample else { return }
                let q = sample.attitude.quaternion
                let attitude = Quaternion(x: q.x, y: q.y, z: q.z, w: q.w)
                let timestamp = sample.timestamp
                Task { @MainActor [weak self] in
                    self?.receiveMotion(attitude: attitude, timestamp: timestamp, sensorID: sensorID)
                }
            }
        } else if calibrated {
            calibrationStatus = "正中已保留，无需重复校准"
        }
        let id = UUID()
        generation = id
        if !session.localOnly, connectionMode == .bluetooth {
            bluetoothTick = 0; bluetoothRateStart = ProcessInfo.processInfo.systemUptime; bluetoothCount = 0
            bluetooth.start(token: token)
        } else if !session.localOnly, let url = endpoint() {
            let credential = token
            sender = Task { [weak self] in
                await self?.sendLoop(url: url, token: credential, id: id)
            }
        }
    }

    private func suspendSampling(stopSensors: Bool = true, disconnect: Bool = true) {
        generation = UUID()
        sender?.cancel(); sender = nil
        if stopSensors { sensorGeneration = UUID(); motion.stopDeviceMotionUpdates() }
        if disconnect { bluetooth.stop() } else { bluetooth.pause() }
        latest = nil; value = 0; angle = 0
        math.filtered = 0; math.lastTimestamp = nil
        sendHz = 0
    }

    func connectBluetoothMac(_ id: UUID) { bluetooth.connect(id) }
    func forgetBluetoothMac() { bluetooth.forget(); status = "已忘记电脑，下次连接可重新选择" }

    func stop() {
        session.stop()
        suspendSampling()
        status = "已停止"
    }

    func calibrate() {
        guard let latest, ProcessInfo.processInfo.systemUptime - sampleTimestamp < 0.25 else { return }
        math.calibrate(latest)
        calibrated = true
        value = 0; angle = 0
        saveCalibration()
        calibrationStatus = "正中已保存，重连无需重校"
    }

    func selectAxis(_ selection: SteeringAxis) {
        guard selection != .learned, let axis = selection.vector else { return }
        selectedAxis = selection
        UserDefaults.standard.set(selection.rawValue, forKey: "steeringAxis")
        UserDefaults.standard.removeObject(forKey: "calibrationV1")
        math.axis = axis
        math.zero = nil
        math.filtered = 0
        math.lastTimestamp = nil
        calibrated = false
        value = 0; angle = 0
        calibrationStatus = "轴已切换，请重新设为正中"
    }

    func learnRight() {
        guard let latest, ProcessInfo.processInfo.systemUptime - sampleTimestamp < 0.25 else { return }
        if math.learnRight(latest) {
            selectedAxis = .learned
            hasLearnedAxis = true
            saveCalibration()
            calibrationStatus = "右转已识别，请回正后测试"
        } else {
            calibrationStatus = "先校准正中，再明显向右转"
        }
    }

    func invert() { math.inverted.toggle(); math.filtered = 0; saveCalibration(); UserDefaults.standard.set(math.inverted, forKey: "steeringInverted") }

    private func recordDiagnostics(force: Bool = false) {
        guard running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - diagnosticTime > 1 else { return }
        diagnosticTime = now
        let data: [String: Any] = ["status": status, "running": running,
            "foreground": session.foreground, "interactive": interactive, "motionActive": motion.isDeviceMotionActive,
            "motionAvailable": motion.isDeviceMotionAvailable, "hasSample": latest != nil,
            "hardwareTimestamp": previousTimestamp, "receiptAgeMs": max(0, (now-sampleTimestamp)*1000),
            "sampleHz": sampleHz, "sendHz": sendHz, "calibrated": calibrated,
            "sensorStarts": sensorStarts, "callbackCount": callbackCount, "samplingMode": "coreMotionCallback", "uiHz": interactive ? 10 : 1, "activeTransitions": activeTransitions, "inactiveTransitions": inactiveTransitions,
            "referenceFrame": referenceFrame.rawValue, "availableFrames": CMMotionManager.availableAttitudeReferenceFrames().rawValue,
            "hasSavedCalibration": savedCalibration != nil, "blePending": bluetooth.pendingCount, "bleWriteLength": bluetooth.maximumWriteLength, "compactBLE": true]
        if let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let encoded = try? JSONSerialization.data(withJSONObject: data) {
            try? encoded.write(to: url.appendingPathComponent("watchsteer-status.json"), options: .atomic)
        }
    }

    private func receiveMotion(attitude: Quaternion, timestamp: Double, sensorID: UUID) {
        guard sensorID == sensorGeneration, session.sampling, timestamp > previousTimestamp else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Drop delayed callbacks rather than presenting old turns as live input.
        guard now - timestamp >= 0, now - timestamp < 0.25 else { return }
        callbackCount += 1
        if previousTimestamp > 0 {
            let rate = 1 / (timestamp - previousTimestamp)
            measuredSampleHz = measuredSampleHz == 0 ? rate : 0.9 * measuredSampleHz + 0.1 * rate
        }
        previousTimestamp = timestamp; sampleTimestamp = now; latest = attitude
        let result = math.update(attitude, timestamp: timestamp)
        streamValue = result.value; streamAngle = result.angle
        // Always On UI updates are throttled independently of control output.
        if now - lastUIUpdate >= (interactive ? 0.1 : 1.0) {
            value = streamValue; angle = streamAngle; sampleHz = measuredSampleHz
            rttMs = latestRTT; lastUIUpdate = now
        }
        if !session.localOnly, connectionMode == .bluetooth, now - bluetoothTick >= 1.0/30.0 {
            bluetoothTick = bluetoothTick == 0 || now - bluetoothTick > 0.15 ? now : bluetoothTick + 1.0/30.0
            bluetooth.offer(steering: streamValue, angle: streamAngle, sampleHz: measuredSampleHz,
                            ageMs: max(0, (now-timestamp)*1000), rttMs: latestRTT, calibrated: calibrated)
        }
        recordDiagnostics()
    }

    private func sendLoop(url: URL, token: String, id: UUID) async {
        var seq = 0
        var failures = 0
        var warmed = false
        var count = 0
        var rateStart = ProcessInfo.processInfo.systemUptime
        while !Task.isCancelled, session.sampling, generation == id {
            let start = ProcessInfo.processInfo.systemUptime
            let age = (start - sampleTimestamp) * 1000
            let warming = !warmed
            guard warming || (latest != nil && age >= 0 && age <= 250) else {
                value = 0; status = "等待新鲜姿态数据"
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            seq += 1
            let sample = Sample(session: id.uuidString, seq: seq, steering: calibrated ? streamValue : 0,
                angleDeg: streamAngle, sampleHz: min(250, measuredSampleHz), sampleAgeMs: age,
                rttMs: rttMs, calibrated: calibrated)
            let target = warming ? url.deletingLastPathComponent().appendingPathComponent("ping") : url
            var request = URLRequest(url: target)
            request.timeoutInterval = warming ? 15 : 3
            request.httpMethod = warming ? "GET" : "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if !warming { request.httpBody = try? JSONEncoder().encode(sample) }
            var delay = 0.05
            do {
                // Exactly one request in flight. The NEXT request uses the
                // latest sample; failed samples are never replayed.
                let (data, response) = try await network.data(for: request)
                guard !Task.isCancelled, generation == id else { return }
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if http.statusCode == 401 || http.statusCode == 403 {
                    status = "令牌错误，请在连接页重新填写"; sendHz = 0; return
                }
                guard http.statusCode == 200 else { throw TransportFailure.http(http.statusCode) }
                if warming {
                    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          (result["ok"] as? Bool) == true else { throw TransportFailure.invalidACK }
                    warmed = true
                    status = "已连接"
                    continue // Fetch a NEW sensor sample after network setup.
                }
                guard let ack = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (ack["seq"] as? Int) == seq, (ack["ok"] as? Bool) == true else {
                    throw TransportFailure.invalidACK
                }
                let now = ProcessInfo.processInfo.systemUptime
                rttMs = (now - start) * 1000
                count += 1
                if now - rateStart >= 1 {
                    sendHz = Double(count) / (now - rateStart)
                    count = 0; rateStart = now
                }
                failures = 0
                status = "已连接"
                delay = max(0.001, 0.05 - (now - start))
            } catch {
                guard !Task.isCancelled, generation == id else { return }
                failures += 1
                warmed = false
                if let failure = error as? TransportFailure {
                    switch failure {
                    case .http(409): status = "另一控制端占用，稍后重连"
                    case .http(let code): status = "服务返回 HTTP \(code)，重连中"
                    case .invalidACK: status = "地址返回内容不符，请检查服务地址"
                    }
                } else {
                    switch (error as NSError).code {
                    case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                        status = "服务地址无法解析，请检查地址"
                    case NSURLErrorCannotConnectToHost:
                        status = "无法连接服务，请检查电脑服务"
                    case NSURLErrorTimedOut: status = "请求超时，重连中"
                    case NSURLErrorNotConnectedToInternet: status = "手表暂无网络，重连中"
                    case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                         NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot:
                        status = "HTTPS 证书校验失败，请检查服务"
                    default: status = "连接失败（\((error as NSError).code)），重连中"
                    }
                }
                sendHz = 0
                delay = min(3.0, 0.25 * pow(2, Double(min(failures - 1, 4))))
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}
