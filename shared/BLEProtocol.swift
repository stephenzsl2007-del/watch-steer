import Foundation
import CryptoKit

// App protocol over GATT. No credentials are advertised or sent in plaintext.
enum BLEWire {
    static let service = "D5320050-6DCB-43A6-9902-89524AB47E1B"
    static let uplink = "D5320051-6DCB-43A6-9902-89524AB47E1B"
    static let downlink = "D5320052-6DCB-43A6-9902-89524AB47E1B"
    static func nonce() -> Data { UUID().withBytes }
    static func proof(token: String, server: Data, client: Data, role: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(("WatchSteer BLE 1 " + role).utf8) + server + client,
                                             using: SymmetricKey(data: Data(token.utf8))))
    }
    static func verify(_ proof: Data, token: String, server: Data, client: Data, role: String) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof,
            authenticating: Data(("WatchSteer BLE 1 " + role).utf8) + server + client,
            using: SymmetricKey(data: Data(token.utf8)))
    }
    static func key(token: String, server: Data, client: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(token.utf8)), salt: server + client,
                              info: Data("WatchSteer BLE session 1".utf8), outputByteCount: 32)
    }
    static func seal(_ payload: Data, kind: UInt8, key: SymmetricKey) throws -> Data {
        Data([kind]) + (try ChaChaPoly.seal(payload, using: key, authenticating: Data([kind])).combined)
    }
    static func open(_ packet: Data, kind: UInt8, key: SymmetricKey) throws -> Data {
        guard packet.first == kind else { throw Failure.invalid }
        return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: packet.dropFirst()), using: key,
                                   authenticating: Data([kind]))
    }
    enum Failure: Error { case invalid }
    static func fragments(_ packet: Data, id: UInt8, mtu: Int) -> [Data] {
        // A full logical packet is <=128 bytes; even the minimum ATT MTU works.
        guard !packet.isEmpty, packet.count <= 128, mtu >= 20 else { return [] }
        let size = min(mtu - 4, 124), count = (packet.count + size - 1) / size
        return (0..<count).map { i in
            Data([0x57, id, UInt8(i), UInt8(count)]) + packet.subdata(in: i*size..<min(packet.count, (i+1)*size))
        }
    }
}

struct BLEAssembler {
    private var id: UInt8 = 0
    private var count = 0
    private var next = 0
    private var started = 0.0
    private var buffer = Data()
    mutating func append(_ frame: Data, now: Double) -> Data? {
        let b = [UInt8](frame)
        guard b.count > 4, b[0] == 0x57, b[3] > 0, b[3] <= 8, b[2] < b[3] else { reset(); return nil }
        if b[2] == 0 { id = b[1]; count = Int(b[3]); next = 0; buffer = Data(); started = now }
        guard now - started <= 1, b[1] == id, Int(b[3]) == count, Int(b[2]) == next,
              buffer.count + b.count - 4 <= 128 else { reset(); return nil }
        buffer.append(contentsOf: b.dropFirst(4)); next += 1
        if next == count { let result = buffer; reset(); return result }
        return nil
    }
    mutating func reset() { buffer = Data(); count = 0; next = 0 }
}

struct BLESample {
    let seq: UInt32
    let steering: Double
    let angle: Double
    let sampleHz: Double
    let ageMs: Double
    let rttMs: Double
    let calibrated: Bool
    var encoded: Data {
        var d = Data(); d.put(seq)
        for v in [steering, angle, sampleHz, ageMs, rttMs] { d.put(Float(v).bitPattern) }
        d.append(calibrated ? 1 : 0); return d
    }
    init(seq: UInt32, steering: Double, angle: Double, sampleHz: Double, ageMs: Double, rttMs: Double, calibrated: Bool) {
        self.seq = seq; self.steering = steering; self.angle = angle; self.sampleHz = sampleHz
        self.ageMs = ageMs; self.rttMs = rttMs; self.calibrated = calibrated
    }
    func compactEncoded() throws -> Data {
        // Preserve validation and quantize well below the visible steering resolution.
        _ = try BLESample(data: encoded)
        var d = Data(); d.put(seq)
        d.put16(UInt16(bitPattern: Int16((steering * 32767).rounded())))
        d.put16(UInt16(bitPattern: Int16((angle * 100).rounded())))
        d.put16(UInt16((sampleHz * 10).rounded()))
        d.put16(UInt16((ageMs * 10).rounded()))
        d.put16(UInt16(rttMs.rounded()))
        d.append(calibrated ? 1 : 0); return d
    }
    init(compactData d: Data) throws {
        guard d.count == 15, d.last! <= 1 else { throw BLEWire.Failure.invalid }
        self.init(seq: d.u32(at: 0), steering: Double(Int16(bitPattern: d.u16(at: 4)))/32767,
                  angle: Double(Int16(bitPattern: d.u16(at: 6)))/100,
                  sampleHz: Double(d.u16(at: 8))/10, ageMs: Double(d.u16(at: 10))/10,
                  rttMs: Double(d.u16(at: 12)), calibrated: d.last == 1)
        _ = try BLESample(data: encoded)
    }
    init(data: Data) throws {
        guard data.count == 25 else { throw BLEWire.Failure.invalid }
        let b = [UInt8](data)
        seq = data.u32(at: 0)
        let values = (1...5).map { Double(Float(bitPattern: data.u32(at: $0*4))) }
        steering = values[0]; angle = values[1]; sampleHz = values[2]; ageMs = values[3]; rttMs = values[4]
        calibrated = b[24] == 1
        guard values.allSatisfy({ $0.isFinite }), (-1...1).contains(steering), (-180...180).contains(angle),
              (0...250).contains(sampleHz), (0...250).contains(ageMs), (0...60000).contains(rttMs),
              b[24] <= 1, calibrated || steering == 0 else { throw BLEWire.Failure.invalid }
    }
    func json(session: String) -> [String: Any] {
        ["session": session, "seq": Int(seq), "steering": steering, "angleDeg": angle,
         "sampleHz": sampleHz, "sampleAgeMs": ageMs, "rttMs": rttMs, "calibrated": calibrated]
    }
}

extension Data {
    mutating func put16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    func u16(at offset: Int) -> UInt16 { let b = [UInt8](self); return UInt16(b[offset]) | UInt16(b[offset+1]) << 8 }
    mutating func put(_ value: UInt32) { append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0*8)) }) }
    func u32(at offset: Int) -> UInt32 {
        let b = [UInt8](self)
        return (0..<4).reduce(0) { $0 | UInt32(b[offset+$1]) << ($1*8) }
    }
}
private extension UUID {
    var withBytes: Data { var u = uuid; return withUnsafeBytes(of: &u) { Data($0) } }
}


// Two packets at most: hide one BLE round trip without accumulating old turns.
struct BLESendWindow {
    private(set) var sent: [UInt32: Double] = [:]
    var canSend: Bool { sent.count < 2 }
    var isEmpty: Bool { sent.isEmpty }
    mutating func submit(_ seq: UInt32, at time: Double) -> Bool {
        guard canSend, sent[seq] == nil else { return false }
        sent[seq] = time; return true
    }
    mutating func acknowledge(_ seq: UInt32, at time: Double) -> Double? {
        guard let start = sent[seq] else { return nil }
        sent = sent.filter { $0.key > seq }
        return max(0, (time-start)*1000)
    }
    mutating func reset() { sent.removeAll(keepingCapacity: true) }
}

struct BLELatestMailbox {
    struct Entry { let sample: BLESample; let receivedAt: Double }
    private var latest: Entry?
    private var lastSeq: UInt32?
    mutating func offer(_ sample: BLESample, at time: Double) -> Bool {
        guard lastSeq.map({ sample.seq > $0 }) ?? true else { return false }
        lastSeq = sample.seq; latest = Entry(sample: sample, receivedAt: time); return true
    }
    mutating func take() -> Entry? { defer { latest = nil }; return latest }
}
