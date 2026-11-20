import Foundation
import CoreBluetooth
import CryptoKit

struct NearbyMac: Identifiable { let id: UUID; let name: String }

// Main-queue delegates. A two-packet send window hides BLE round-trip latency;
// backpressure still queues only fragments of the single packet being written.
final class BluetoothTransport: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onStatus: ((String) -> Void)?
    var onPeers: (([NearbyMac]) -> Void)?
    var onACK: ((Double) -> Void)?
    private var central: CBCentralManager?
    private var peer: CBPeripheral?
    private var peers: [UUID: CBPeripheral] = [:]
    private var names: [UUID: String] = [:]
    private var up: CBCharacteristic?
    private var down: CBCharacteristic?
    private var assembler = BLEAssembler()
    private var queue: [Data] = []
    private var packetID: UInt8 = 0
    private var key: SymmetricKey?
    private var serverNonce = Data(), clientNonce = Data()
    private var token = ""
    private var started = false
    private var paused = false
    private var window = BLESendWindow()
    private var seq: UInt32 = 0
    private var deadline: Timer?
    private var reconnect: Timer?
    private var savedID: UUID? { UserDefaults.standard.string(forKey: "bluetoothMac").flatMap(UUID.init(uuidString:)) }
    var pendingCount: Int { window.sent.count }
    var maximumWriteLength: Int { peer?.maximumWriteValueLength(for: .withoutResponse) ?? 0 }
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    func start(token: String) {
        if started, self.token == token {
            paused = false
            if let peer, peer.state == .connected, key != nil {
                onStatus?("蓝牙连接保留 · 等待新数据")
            } else if peer == nil { discover() }
            else { armTimeout(12) }
            return
        }
        stop(); self.token = token; started = true; paused = false
        onStatus?("正在寻找附近的 Mac…")
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else if central?.state == .poweredOn { discover() }
    }
    func pause() {
        // Inactive is not a disconnect; let watchOS retain the GATT link.
        paused = true; deadline?.invalidate(); deadline = nil
        central?.stopScan(); reconnect?.invalidate(); reconnect = nil
        window.reset(); queue = []
    }
    func stop() {
        started = false; central?.stopScan()
        deadline?.invalidate(); reconnect?.invalidate(); deadline = nil; reconnect = nil
        if let peer { central?.cancelPeripheralConnection(peer) }
        peer = nil; up = nil; down = nil; queue = []; key = nil; window.reset()
        peers = [:]; names = [:]; assembler.reset(); onPeers?([])
    }
    func forget() { UserDefaults.standard.removeObject(forKey: "bluetoothMac") }
    private func discover() {
        guard started, !paused, central?.state == .poweredOn, peer == nil else { return }
        central?.scanForPeripherals(withServices: [CBUUID(string: BLEWire.service)], options: nil)
        onStatus?("请选择附近电脑；请打开 Mac 接收器")
        // Re-observe the service before auto-connecting: cached IDs can become
        // unreachable after a Mac restart. Other nearby Macs stay selectable.

    }
    func connect(_ id: UUID) {
        guard started, peer == nil, let p = peers[id] else { return }
        central?.stopScan(); peer = p; p.delegate = self; onPeers?([])
        onStatus?("正在连接 \(names[id] ?? p.name ?? "Mac")…")
        central?.connect(p, options: nil)
        armTimeout(12)
    }
    private func armTimeout(_ interval: Double) {
        deadline?.invalidate()
        deadline = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self, !self.paused else { return }
            self.fail("蓝牙无响应，正在重新连接")
        }
    }
    private func fail(_ message: String) {
        guard started else { return }
        onStatus?(message); deadline?.invalidate(); deadline = nil
        if let peer { central?.cancelPeripheralConnection(peer) }
        peer = nil; up = nil; down = nil; key = nil; window.reset(); queue = []; assembler.reset()
        reconnect?.invalidate()
        reconnect = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in self?.discover() }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard started else { return }
        switch central.state {
        case .poweredOn: discover()
        case .unauthorized: onStatus?("请在设置中允许 WatchSteer 使用蓝牙")
        case .poweredOff: onStatus?("请开启手表蓝牙")
        case .unsupported: onStatus?("当前设备不支持蓝牙连接")
        default: onStatus?("蓝牙正在准备…")
        }
        if central.state != .poweredOn { key = nil; window.reset(); peer = nil; queue = [] }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard started else { return }
        peers[peripheral.identifier] = peripheral
        names[peripheral.identifier] = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "WatchSteer Mac"
        if peripheral.identifier == savedID { connect(peripheral.identifier) }
        else if peer == nil {
            onPeers?(peers.keys.sorted { $0.uuidString < $1.uuidString }.map { NearbyMac(id: $0, name: names[$0] ?? "Mac") })
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === peer else { return }
        peripheral.discoverServices([CBUUID(string: BLEWire.service)])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === peer else { return }; fail("蓝牙连接失败，正在重试")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === peer else { return }; fail("蓝牙已断开，正在重连")
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === peer else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: BLEWire.service) })
        else { fail("电脑服务未就绪"); return }
        peripheral.discoverCharacteristics([CBUUID(string: BLEWire.uplink), CBUUID(string: BLEWire.downlink)], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === peer else { return }
        up = service.characteristics?.first { $0.uuid == CBUUID(string: BLEWire.uplink) }
        down = service.characteristics?.first { $0.uuid == CBUUID(string: BLEWire.downlink) }
        guard error == nil, up?.properties.contains(.writeWithoutResponse) == true, let down,
              down.properties.contains(.notify) else { fail("电脑蓝牙协议不匹配"); return }
        peripheral.setNotifyValue(true, for: down)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === peer else { return }
        if error != nil { fail("无法订阅电脑蓝牙状态") }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === peer, characteristic.uuid == CBUUID(string: BLEWire.downlink), error == nil,
              let frame = characteristic.value, let packet = assembler.append(frame, now: now), let kind = packet.first else { return }
        do {
            if kind == 1, packet.count == 17, key == nil {
                serverNonce = Data(packet.dropFirst()); clientNonce = BLEWire.nonce()
                send(Data([2]) + clientNonce + BLEWire.proof(token: token, server: serverNonce, client: clientNonce, role: "watch"))
                onStatus?("正在验证电脑…")
            } else if kind == 3, packet.count == 33, key == nil, clientNonce.count == 16,
                      BLEWire.verify(Data(packet.dropFirst()), token: token, server: serverNonce, client: clientNonce, role: "mac") {
                key = BLEWire.key(token: token, server: serverNonce, client: clientNonce)
                seq = 0; window.reset(); deadline?.invalidate(); deadline = nil
                UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "bluetoothMac")
                onStatus?("蓝牙已验证 · 等待首帧确认")
            } else if kind == 5, let key {
                let ack = try BLEWire.open(packet, kind: 5, key: key)
                guard ack.count == 5, let rtt = window.acknowledge(ack.u32(at: 0), at: now) else { return }
                deadline?.invalidate(); deadline = nil
                if !window.isEmpty { armTimeout(2) }
                if ack.last == 1 { onACK?(rtt); onStatus?("已连接") }
                else { onStatus?("Mac 网页服务暂不可用，正在重试") }
            } else if kind == 6 { // Non-secret rejection; never authenticates a peer.
                stop(); onStatus?("配对令牌不一致，请从 Mac 接收器复制一次")
            }
        } catch { fail("蓝牙数据验证失败，正在重连") }
    }
    func offer(steering: Double, angle: Double, sampleHz: Double, ageMs: Double, rttMs: Double, calibrated: Bool) {
        guard started, !paused, let key, window.canSend, queue.isEmpty, ageMs >= 0, ageMs <= 250 else { return }
        guard seq < UInt32.max else { fail("正在更新蓝牙会话"); return }
        seq += 1
        let sample = BLESample(seq: seq, steering: calibrated ? steering : 0, angle: angle,
                               sampleHz: min(250, sampleHz), ageMs: ageMs, rttMs: rttMs, calibrated: calibrated)
        guard let payload = try? sample.compactEncoded(), let packet = try? BLEWire.seal(payload, kind: 7, key: key) else { return }
        let first = window.isEmpty
        guard window.submit(seq, at: now) else { return }
        if first { armTimeout(2) }
        send(packet)
    }
    private func send(_ packet: Data) {
        guard let peer, queue.isEmpty else { return }
        packetID &+= 1
        queue = BLEWire.fragments(packet, id: packetID, mtu: peer.maximumWriteValueLength(for: .withoutResponse))
        flush()
    }
    private func flush() {
        guard let peer, let up else { return }
        while !queue.isEmpty, peer.canSendWriteWithoutResponse {
            peer.writeValue(queue.removeFirst(), for: up, type: .withoutResponse)
        }
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if peripheral === peer { flush() }
    }
}
