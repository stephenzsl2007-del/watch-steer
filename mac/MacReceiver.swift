import SwiftUI
import AppKit
import CoreBluetooth
import CryptoKit
import Darwin
import WebKit

private enum ReceiverInstance {
    // Shared by extracted copies. Keep the descriptor open for the app lifetime.
    static var descriptor: Int32 = -1
    static func claim() -> Bool {
        if ProcessInfo.processInfo.environment["WATCHSTEER_APP_TEST"] == "1" { return true }
        let path = NSTemporaryDirectory() + "watchsteer-receiver-v1.lock"
        descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }
}

private final class Link {
    let central: CBCentral
    let nonce = BLEWire.nonce()
    let session = UUID().uuidString
    var assembler = BLEAssembler()
    var key: SymmetricKey?
    var mailbox = BLELatestMailbox()
    var pendingNotification: Data?
    var queue: [Data] = []
    var packetID: UInt8 = 0
    var busy = false
    var subscribedAt = ProcessInfo.processInfo.systemUptime
    init(_ central: CBCentral) { self.central = central }
}

final class MacReceiver: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    @Published var bluetoothStatus = "点击开始，允许蓝牙后等待手表"
    @Published var backendStatus = "正在检查网页服务…"
    @Published var received = 0
    @Published var rate = 0.0
    @Published var steering = 0.0
    @Published var connected = false
    @Published var accepting = false
    @Published var pageURL: URL?
    let token: String
    let port = Int(ProcessInfo.processInfo.environment["WATCHSTEER_PORT"] ?? "8765") ?? 8765
    var baseURL: String { "http://127.0.0.1:\(port)" }
    private var manager: CBPeripheralManager?
    private var down: CBMutableCharacteristic?
    private var links: [UUID: Link] = [:]
    private var active: UUID?
    private var backend: Process?
    private var ready = false
    private var lastReceive = 0.0
    private var rateTime = ProcessInfo.processInfo.systemUptime
    private var rateCount = 0
    private var lastRelayMs = 0.0
    private var watchdog: Timer?
    private let http: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1; c.timeoutIntervalForResource = 2
        c.connectionProxyDictionary = [:] // This hop is always the Mac's loopback.
        c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }()
    override init() {
        token = Self.loadToken()
        super.init()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastReceive > 0.5 { self.connected = false; self.steering = 0 }
            // Abandoned subscriptions cannot consume unbounded state.
            if let path = ProcessInfo.processInfo.environment["WATCHSTEER_DIAGNOSTIC_PATH"],
               let data = try? JSONSerialization.data(withJSONObject: ["bluetoothStatus": self.bluetoothStatus,
                   "backendStatus": self.backendStatus, "received": self.received, "connected": self.connected,
                   "rate": self.rate, "accepting": self.accepting, "subscriptions": self.links.count, "relayMs": self.lastRelayMs]) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            self.links = self.links.filter { $0.value.key != nil || now - $0.value.subscribedAt < 20 }
            // Neutralize output on a wrist-down pause, but keep authentication.
            if self.active != nil, now - self.lastReceive > 0.5 {
                self.bluetoothStatus = "采样已暂停 · 蓝牙会话保留"
            }
        }
        Task { await prepareBackend() }
    }
    private static func loadToken() -> String {
        do {
            let fm = FileManager.default
            let folder: URL
            if let state = ProcessInfo.processInfo.environment["WATCHSTEER_STATE_DIR"] { folder = URL(fileURLWithPath: state) }
            else { folder = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("WatchSteer", isDirectory: true) }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            let file = folder.appendingPathComponent(ProcessInfo.processInfo.environment["WATCHSTEER_APP_TEST"] == "1" ? "test-pairing-token" : "pairing-token")
            let existing = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let supplied = ProcessInfo.processInfo.environment["WATCHSTEER_TOKEN"]
            let value = supplied ?? existing ?? Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
            guard value.count >= 24, value.utf8.allSatisfy({ $0 < 128 }) else { return "" }
            try (value + "\n").write(to: file, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return value
        } catch { return "" }
    }
    private func request(_ path: String, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        var r = URLRequest(url: URL(string: baseURL + path)!)
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body { r.httpMethod = "POST"; r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await http.data(for: r)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }
    @MainActor private func prepareBackend() async {
        guard token.count >= 24 else { backendStatus = "无法保存配对信息，请检查当前用户目录权限"; return }
        if let (_, response) = try? await request("/api/ping") {
            if response.statusCode == 200 { ready = true; backendStatus = "网页服务已就绪 · 仅本机访问"; autoStart(); return }
            backendStatus = "已有服务使用另一令牌，请关闭旧服务后重开"; return
        }
        guard let resources = Bundle.main.resourceURL else { return }
        let child = Process()
        let bundled = resources.appendingPathComponent("service/WatchSteerService")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            child.executableURL = bundled
            child.arguments = ["--port", String(port), "--origin", baseURL]
        } else {
            child.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WATCHSTEER_PYTHON"] ?? "/usr/bin/python3")
            child.arguments = [resources.appendingPathComponent("backend/server.py").path, "--port", String(port), "--origin", baseURL]
        }
        var environment = ProcessInfo.processInfo.environment
        environment["WATCHSTEER_TOKEN"] = token
        environment["WATCHSTEER_WEB_ROOT"] = resources.appendingPathComponent("web").path
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        do { try child.run(); backend = child }
        catch { backendStatus = "无法启动网页服务：\(error.localizedDescription)"; return }
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let (_, response) = try? await request("/api/ping"), response.statusCode == 200 {
                ready = true; backendStatus = "网页服务已就绪 · 仅本机访问"; autoStart(); return
            }
            if !child.isRunning { break }
        }
        backendStatus = "网页服务启动失败，请检查 8765 端口"
    }
    private func autoStart() {
        if ProcessInfo.processInfo.environment["WATCHSTEER_BLE_AUTOSTART"] != "0", ProcessInfo.processInfo.environment["WATCHSTEER_APP_TEST"] != "1" { start() }
        openWeb()
    }
    func start() {
        guard ready else { bluetoothStatus = "请先让网页服务就绪"; return }
        accepting = true
        if manager == nil { manager = CBPeripheralManager(delegate: self, queue: .main) }
        else if manager?.state == .poweredOn { publish() }
    }
    func stop() {
        accepting = false; manager?.stopAdvertising(); manager?.removeAllServices()
        links = [:]; active = nil; down = nil; connected = false; steering = 0
        bluetoothStatus = "蓝牙接收已停止"
    }
    func shutdown() { stop(); watchdog?.invalidate(); if backend?.isRunning == true { backend?.terminate() } }
    func retry() { Task { await prepareBackend() } }
    func copyToken() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(token, forType: .string) }
    func openWeb(external: Bool = false) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (data, response) = try await self.request("/api/browser-ticket", body: Data("{}".utf8))
                guard response.statusCode == 200,
                      let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ticket = result["ticket"] as? String else { throw URLError(.badServerResponse) }
                var url = URLComponents(string: self.baseURL + "/?desktop=1")!
                url.queryItems = [URLQueryItem(name: "desktop", value: "1"), URLQueryItem(name: "view", value: UUID().uuidString)]
                // One-use, read-only ticket in the fragment; never the device credential.
                url.fragment = "connect=" + ticket
                if let destination = url.url {
                    if external { NSWorkspace.shared.open(destination) } else { self.pageURL = destination }
                }
            } catch { self.backendStatus = "无法连接网页，请重开接收器：\(error.localizedDescription)" }
        }
    }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn: if accepting { publish() }
        case .poweredOff: bluetoothStatus = "请开启 Mac 蓝牙"; connected = false
        case .unauthorized: bluetoothStatus = "请在系统设置 → 隐私与安全性 → 蓝牙中允许 WatchSteer"
        case .unsupported: bluetoothStatus = "这台 Mac 不支持蓝牙外设模式"
        default: bluetoothStatus = "蓝牙正在准备…"
        }
        if peripheral.state != .poweredOn { links = [:]; active = nil; down = nil }
    }
    private func publish() {
        guard let manager, accepting else { return }
        manager.removeAllServices(); links = [:]; active = nil
        let up = CBMutableCharacteristic(type: CBUUID(string: BLEWire.uplink),
                                        properties: [.writeWithoutResponse], value: nil, permissions: [.writeable])
        let down = CBMutableCharacteristic(type: CBUUID(string: BLEWire.downlink),
                                          properties: [.notify], value: nil, permissions: [.readable])
        self.down = down
        let service = CBMutableService(type: CBUUID(string: BLEWire.service), primary: true)
        service.characteristics = [up, down]; manager.add(service)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard accepting else { return }
        guard error == nil else { bluetoothStatus = "无法建立蓝牙服务：\(error!.localizedDescription)"; return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: BLEWire.service)],
                                    CBAdvertisementDataLocalNameKey: "WatchSteer Mac"])
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        bluetoothStatus = error == nil ? "等待手表 · 在手表上点击连接电脑" : "蓝牙广播失败：\(error!.localizedDescription)"
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard accepting, characteristic.uuid == CBUUID(string: BLEWire.downlink), links.count < 4 else { return }
        if active == central.identifier { active = nil }
        let link = Link(central); links[central.identifier] = link
        peripheral.setDesiredConnectionLatency(.low, for: central)
        send(Data([1]) + link.nonce, to: link)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        links.removeValue(forKey: central.identifier)
        if active == central.identifier { active = nil; connected = false; bluetoothStatus = "手表已离线 · 等待重连" }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard request.characteristic.uuid == CBUUID(string: BLEWire.uplink), request.offset == 0,
                  let link = links[request.central.identifier], let value = request.value,
                  let packet = link.assembler.append(value, now: ProcessInfo.processInfo.systemUptime) else { continue }
            receive(packet, link: link)
        }
    }
    private func receive(_ packet: Data, link: Link) {
        guard let kind = packet.first else { return }
        if kind == 2, link.key == nil, packet.count == 49 {
            let client = packet.subdata(in: 1..<17)
            guard BLEWire.verify(packet.subdata(in: 17..<49), token: token, server: link.nonce, client: client, role: "watch") else {
                send(Data([6]), to: link); return
            }
            guard active == nil || active == link.central.identifier else { return }
            link.key = BLEWire.key(token: token, server: link.nonce, client: client)
            active = link.central.identifier; lastReceive = ProcessInfo.processInfo.systemUptime
            send(Data([3]) + BLEWire.proof(token: token, server: link.nonce, client: client, role: "mac"), to: link)
            bluetoothStatus = "手表已验证 · 等待转向"
        } else if (kind == 4 || kind == 7), let key = link.key, active == link.central.identifier {
            do {
                let payload = try BLEWire.open(packet, kind: kind, key: key)
                let sample = try kind == 7 ? BLESample(compactData: payload) : BLESample(data: payload)
                guard link.mailbox.offer(sample, at: ProcessInfo.processInfo.systemUptime) else { return }
                drain(link)
            } catch { bluetoothStatus = "收到无效蓝牙数据，已丢弃" }
        }
    }
    private func drain(_ link: Link) {
        guard !link.busy, let entry = link.mailbox.take(), let key = link.key else { return }
        link.busy = true
        Task { @MainActor [weak self, weak link] in
            guard let self, let link else { return }
            let sample = entry.sample
            let started = ProcessInfo.processInfo.systemUptime
            let age = sample.ageMs + (started-entry.receivedAt)*1000
            var ok = false
            var json = sample.json(session: link.session); json["sampleAgeMs"] = age
            if age <= 250,
               let body = try? JSONSerialization.data(withJSONObject: json),
               let (data, response) = try? await self.request("/api/steer", body: body),
               response.statusCode == 200,
               let ack = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (ack["seq"] as? Int) == Int(sample.seq), (ack["ok"] as? Bool) == true { ok = true }
            guard self.links[link.central.identifier] === link else { return }
            link.busy = false
            if ok {
                let now = ProcessInfo.processInfo.systemUptime
                self.lastRelayMs = (now-started)*1000
                if now-self.lastReceive > 0.5 { self.rateTime = now; self.rateCount = 0; self.rate = 0 }
                self.received += 1; self.rateCount += 1; self.connected = true
                self.lastReceive = now; self.steering = sample.steering
                if now-self.rateTime >= 1 {
                    self.rate = Double(self.rateCount)/(now-self.rateTime)
                    self.rateCount = 0; self.rateTime = now
                }
                self.bluetoothStatus = "已连接 · 转向正在送达网页"
            } else { self.bluetoothStatus = "蓝牙已通，网页服务未确认" }
            var ack = Data(); ack.put(sample.seq); ack.append(ok ? 1 : 0)
            if let packet = try? BLEWire.seal(ack, kind: 5, key: key) { self.send(packet, to: link) }
            // A single replaceable newest value, never a FIFO of old turns.
            self.drain(link)
        }
    }
    private func send(_ packet: Data, to link: Link) {
        guard link.queue.isEmpty else { link.pendingNotification = packet; return }
        link.packetID &+= 1
        link.queue = BLEWire.fragments(packet, id: link.packetID, mtu: link.central.maximumUpdateValueLength)
        flush(link)
    }
    private func flush(_ link: Link) {
        guard let manager, let down else { return }
        while let frame = link.queue.first {
            guard manager.updateValue(frame, for: down, onSubscribedCentrals: [link.central]) else { return }
            link.queue.removeFirst()
        }
        if let next = link.pendingNotification {
            link.pendingNotification = nil; send(next, to: link)
        }
    }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        for link in links.values { flush(link) }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    var receiver: MacReceiver?
    private var terminationSignal: DispatchSourceSignal?
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }; source.resume(); terminationSignal = source
    }
    func applicationWillTerminate(_ notification: Notification) { receiver?.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
struct DrivingWebView: NSViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: "window.__nativeErrors=[];const oldError=console.error;console.error=(...args)=>{window.__nativeErrors.push(args.map(String).join(' '));oldError.apply(console,args);};", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url
        view.load(URLRequest(url: url))
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: URL?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            decisionHandler((url.scheme == "http" && url.host == "127.0.0.1" && url.port == loaded?.port) || url.scheme == "about" ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard ProcessInfo.processInfo.environment["WATCHSTEER_APP_TEST"] == "1", let path = ProcessInfo.processInfo.environment["WATCHSTEER_WEB_DIAGNOSTIC_PATH"] else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                webView.evaluateJavaScript("document.querySelector('#drive-quality').click();document.querySelector('#drive-demo').click();")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                webView.evaluateJavaScript("JSON.stringify({errors:window.__nativeErrors,quality:document.querySelector('#drive-quality').textContent,title:document.title,desktop:document.body.classList.contains('desktop-app'),ready:document.querySelector('#drive-scene').dataset.ready,paired:document.querySelector('#pair-message').textContent.includes('已配对'),car:document.querySelector('#drive-car').value,hasTokenInURL:location.href.includes('connect=')})") { value, error in
                    if let result = value as? String { try? result.write(toFile: path, atomically: true, encoding: .utf8) }
                    else { try? String(describing: error).write(toFile: path, atomically: true, encoding: .utf8) }
                    webView.takeSnapshot(with: nil) { image, _ in
                        if let data = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path + ".png")) }
                        if ProcessInfo.processInfo.environment["WATCHSTEER_APP_TEST"] == "1" { NSApp.terminate(nil) }
                    }
                }
                }
            }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }
    }
}

@main struct WatchSteerMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var receiver = MacReceiver()
    @State private var showConnection = false
    init() {
        guard ReceiverInstance.claim() else {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.watchsteer.local.mac")
                .first(where: { $0.processIdentifier != getpid() })?.activate(options: [.activateAllWindows])
            Darwin.exit(0)
        }
    }
    var body: some Scene {
        WindowGroup("WatchSteer · 高地驾驶") {
            ZStack {
                Color(red: 0.06, green: 0.09, blue: 0.07)
                if let url = receiver.pageURL { DrivingWebView(url: url) }
                else { VStack(spacing: 16) {
                    Image(systemName: "steeringwheel").font(.system(size: 54)).foregroundStyle(.green)
                    ProgressView()
                    Text(receiver.backendStatus).foregroundStyle(.white)
                    Button("重新准备驾驶画面") { receiver.retry() }
                } }
            }
            .frame(minWidth: 960, minHeight: 700)
            .toolbar {
                ToolbarItem(placement: .automatic) { Text(receiver.connected ? "手表已连接" : "等待手表").foregroundStyle(receiver.connected ? .green : .secondary) }
                ToolbarItem { Button("手表连接") { showConnection = true } }
                ToolbarItem { Button("刷新画面", systemImage: "arrow.clockwise") { receiver.openWeb() } }
            }
            .sheet(isPresented: $showConnection) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("连接 Apple Watch").font(.title2.bold())
                    Text(receiver.backendStatus)
                    Text(receiver.bluetoothStatus).fixedSize(horizontal: false, vertical: true)
                    Text("在手表打开 WatchSteer，点“连接电脑”并选择 WatchSteer Mac，然后校准正中。")
                    Text(String(format: "转向 %+.3f · %.1f Hz", receiver.steering, receiver.rate)).monospaced()
                    HStack {
                        Button(receiver.accepting ? "停止接收" : "开始接收") { receiver.accepting ? receiver.stop() : receiver.start() }
                        Button("复制配对令牌") { receiver.copyToken() }
                    }
                    Text("仅新安装手表 App 或令牌不一致时，需要粘贴令牌一次。").font(.callout).foregroundStyle(.secondary)
                    Button("完成") { showConnection = false }.keyboardShortcut(.defaultAction)
                }.padding(28).frame(width: 470)
            }
            .onAppear { delegate.receiver = receiver }
        }.defaultSize(width: 1360, height: 940)
        .commands { CommandGroup(after: .appInfo) { Button("在浏览器中打开") { receiver.openWeb(external: true) } } }
    }
}
