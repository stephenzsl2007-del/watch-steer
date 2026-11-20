import Foundation
import CryptoKit

@main struct BLEProtocolTests {
    static func main() throws {
        let token = "sample-test-credential-32-characters"
        let server = BLEWire.nonce(), client = BLEWire.nonce()
        let proof = BLEWire.proof(token: token, server: server, client: client, role: "watch")
        precondition(BLEWire.verify(proof, token: token, server: server, client: client, role: "watch"))
        precondition(!BLEWire.verify(proof, token: "incorrect credential", server: server, client: client, role: "watch"))
        precondition(!BLEWire.verify(proof, token: token, server: BLEWire.nonce(), client: client, role: "watch"))
        precondition(!BLEWire.verify(proof, token: token, server: server, client: client, role: "mac"))
        let key = BLEWire.key(token: token, server: server, client: client)
        let sample = BLESample(seq: 1234, steering: -0.42, angle: -26, sampleHz: 50, ageMs: 12, rttMs: 33, calibrated: true)
        let compact = try sample.compactEncoded()
        precondition(compact.count == 15)
        let compactSample = try BLESample(compactData: compact)
        precondition(compactSample.seq == sample.seq && abs(compactSample.steering-sample.steering) < 0.00004)
        let compactPacket = try BLEWire.seal(compact, kind: 7, key: key)
        precondition(BLEWire.fragments(compactPacket, id: 0, mtu: 20).count == 3)
        for sign in [-1.0, 1.0] {
            let edge = BLESample(seq: UInt32.max, steering: sign, angle: 180*sign, sampleHz: 250, ageMs: 250, rttMs: 60000, calibrated: true)
            let roundtrip = try BLESample(compactData: edge.compactEncoded())
            precondition(roundtrip.steering == sign && roundtrip.angle == 180*sign && roundtrip.rttMs == 60000)
        }
        var window = BLESendWindow()
        precondition(window.submit(1,at: 0) && window.submit(2,at: 0.03))
        precondition(!window.submit(3,at: 0.06))
        precondition(window.acknowledge(99,at: 0.08) == nil && !window.canSend)
        precondition(abs(window.acknowledge(2,at: 0.08)! - 50) < 1e-6 && window.isEmpty)
        precondition(window.acknowledge(1,at: 0.09) == nil)
        precondition(window.submit(3,at: 0.1)); window.reset(); precondition(window.isEmpty)
        var mailbox = BLELatestMailbox()
        for seq in 1...100 {
            precondition(mailbox.offer(BLESample(seq: UInt32(seq),steering: 0,angle: 0,sampleHz: 50,ageMs: 0,rttMs: 0,calibrated: false),at: Double(seq)))
        }
        precondition(!mailbox.offer(sampleWithSeq(99),at: 101))
        precondition(mailbox.take()?.sample.seq == 100 && mailbox.take() == nil)
        let sealed = try BLEWire.seal(sample.encoded, kind: 4, key: key)
        for mtu in [20, 64, 182, 512] {
            let frames = BLEWire.fragments(sealed, id: 17, mtu: mtu)
            precondition(frames.allSatisfy { $0.count <= mtu })
            var assembly = BLEAssembler(), packet: Data?
            for (i, frame) in frames.enumerated() { packet = assembly.append(frame, now: Double(i)*0.03) }
            precondition(packet == sealed)
            let decoded = try BLESample(data: BLEWire.open(packet!, kind: 4, key: key))
            precondition(decoded.seq == 1234 && abs(decoded.steering + 0.42) < 1e-6)
        }
        var tampered = sealed; tampered[tampered.count-1] ^= 1
        do { _ = try BLEWire.open(tampered, kind: 4, key: key); preconditionFailure("tamper accepted") } catch {}
        let otherKey = BLEWire.key(token: token, server: BLEWire.nonce(), client: client)
        do { _ = try BLEWire.open(sealed, kind: 4, key: otherKey); preconditionFailure("old session accepted") } catch {}
        do { _ = try BLEWire.open(sealed, kind: 5, key: key); preconditionFailure("direction accepted") } catch {}
        var assembly = BLEAssembler()
        let frames = BLEWire.fragments(sealed, id: 5, mtu: 20)
        precondition(assembly.append(frames[0], now: 0) == nil)
        precondition(assembly.append(frames[2], now: 0.1) == nil)
        precondition(assembly.append(frames.last!, now: 0.2) == nil)
        precondition(assembly.append(frames[0], now: 1) == nil)
        precondition(assembly.append(frames[1], now: 3) == nil)
        // Malformed payloads cannot poison the relay or evade neutral-before-calibration.
        for bad in [Double.nan, Double.infinity, 2.0] {
            let invalid = BLESample(seq: 1, steering: bad, angle: 0, sampleHz: 50, ageMs: 0, rttMs: 0, calibrated: true)
            do { _ = try BLESample(data: invalid.encoded); preconditionFailure("invalid sample accepted") } catch {}
            do { _ = try invalid.compactEncoded(); preconditionFailure("invalid compact sample accepted") } catch {}
        }
        do {
            _ = try BLESample(data: BLESample(seq: 1, steering: 1, angle: 0, sampleHz: 50, ageMs: 0, rttMs: 0, calibrated: false).encoded)
            preconditionFailure("uncalibrated turn accepted")
        } catch {}
        print("PASS: mutual authentication, fresh sessions, encrypted payloads, tamper rejection, minimum-MTU fragmentation, loss/expiry, value validation")
    }
    static func sampleWithSeq(_ seq: UInt32) -> BLESample {
        BLESample(seq: seq,steering: 0,angle: 0,sampleHz: 50,ageMs: 0,rttMs: 0,calibrated: false)
    }
}
