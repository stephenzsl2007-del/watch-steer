import Foundation
import Security

// CoreMotion uses (x,y,z,w). Hamilton product, same relative operation as
// CMAttitude.multiply(byInverseOf:). No Euler-angle subtraction or integration.
struct Quaternion: Codable {
    var x: Double, y: Double, z: Double, w: Double
    static let identity = Quaternion(x: 0, y: 0, z: 0, w: 1)
    var inverse: Quaternion { Quaternion(x: -x, y: -y, z: -z, w: w) }
    var normalized: Quaternion {
        let n = sqrt(x*x + y*y + z*z + w*w)
        guard n > 1e-12 else { return .identity }
        return Quaternion(x: x/n, y: y/n, z: z/n, w: w/n)
    }
    static func * (a: Quaternion, b: Quaternion) -> Quaternion {
        Quaternion(x: a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,
                   y: a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,
                   z: a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w,
                   w: a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z)
    }
}

struct SteeringMath {
    var zero: Quaternion?
    var axis = SIMD3<Double>(1, 0, 0)
    var inverted = false
    var filtered = 0.0
    var lastTimestamp: Double?
    let fullScaleDegrees = 60.0
    let deadzoneDegrees = 2.0
    let timeConstant = 0.025

    mutating func calibrate(_ q: Quaternion) {
        zero = q.normalized
        filtered = 0
        lastTimestamp = nil
    }

    // Hold a deliberate right turn 15–60 degrees, then learn its actual axis.
    // This accommodates wrist, crown orientation, and steering pose.
    mutating func learnRight(_ q: Quaternion) -> Bool {
        guard let zero else { return false }
        var r = (q.normalized * zero.inverse).normalized
        if r.w < 0 { r = Quaternion(x: -r.x, y: -r.y, z: -r.z, w: -r.w) }
        let length = sqrt(r.x*r.x + r.y*r.y + r.z*r.z)
        let angle = 2 * atan2(length, r.w) * 180 / .pi
        guard angle >= 10, angle <= 100, length > 1e-8 else { return false }
        axis = SIMD3(r.x/length, r.y/length, r.z/length)
        inverted = false
        filtered = 0
        lastTimestamp = nil
        return true
    }

    func angle(_ q: Quaternion) -> Double? {
        guard let zero else { return nil }
        let r = (q.normalized * zero.inverse).normalized
        // Swing–twist decomposition: project the relative quaternion vector
        // onto the chosen axis and discard off-axis swing.
        let projection = r.x*axis.x + r.y*axis.y + r.z*axis.z
        guard hypot(projection, r.w) > 1e-8 else { return nil }
        var radians = 2 * atan2(projection, r.w)
        if radians > .pi { radians -= 2 * .pi }
        if radians < -.pi { radians += 2 * .pi }
        return radians * 180 / .pi * (inverted ? -1 : 1)
    }

    mutating func update(_ q: Quaternion, timestamp: Double) -> (angle: Double, value: Double) {
        guard let angle = angle(q) else { filtered = 0; return (0, 0) }
        let magnitude = max(0, abs(angle) - deadzoneDegrees) / (fullScaleDegrees - deadzoneDegrees)
        let target = min(1, magnitude) * (angle < 0 ? -1.0 : 1.0)
        let dt = lastTimestamp.map { max(0, min(0.2, timestamp - $0)) } ?? 0.02
        lastTimestamp = timestamp
        filtered += (1 - exp(-dt / timeConstant)) * (target - filtered)
        return (angle, filtered)
    }
}

// User intent survives navigation and inactive/background transitions.
struct ControlSession {
    private(set) var started = false
    private(set) var localOnly = true
    private(set) var foreground = true
    var sampling: Bool { started && foreground }
    mutating func start(localOnly: Bool) { started = true; self.localOnly = localOnly }
    mutating func stop() { started = false }
    mutating func setForeground(_ active: Bool) { foreground = active }
}

// A persisted attitude can cross sensor restarts only in a fixed-heading frame.
struct SavedCalibration: Codable {
    let version: Int
    let zero: Quaternion
    let axis: [Double]
    let inverted: Bool
    let referenceFrame: UInt
    let savedAt: Date
    init?(math: SteeringMath, referenceFrame: UInt) {
        guard let zero = math.zero else { return nil }
        version = 1; self.zero = zero.normalized
        axis = [math.axis.x, math.axis.y, math.axis.z]
        inverted = math.inverted; self.referenceFrame = referenceFrame; savedAt = Date()
    }
    var valid: Bool {
        let q = [zero.x, zero.y, zero.z, zero.w]
        return version == 1 && axis.count == 3 && (axis + q).allSatisfy { $0.isFinite }
            && abs(axis.reduce(0) { $0 + $1*$1 } - 1) < 0.01
            && abs(q.reduce(0) { $0 + $1*$1 } - 1) < 0.01
    }
    func restore(into math: inout SteeringMath, referenceFrame: UInt, fixedHeading: Bool) -> Bool {
        guard valid, fixedHeading, self.referenceFrame == referenceFrame else { return false }
        math.axis = SIMD3(axis[0], axis[1], axis[2]); math.inverted = inverted
        math.calibrate(zero); return true
    }
}

// Trust only the development CA bundled for this one LAN host. Certificates
// still undergo signature-chain, validity-date, server-auth and hostname checks.
final class LocalServerTrust: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private var lastMetricAt = Date.distantPast
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard Date().timeIntervalSince(lastMetricAt) > 2 else { return }
        lastMetricAt = Date()
        let rows: [[String: Any]] = metrics.transactionMetrics.map { item in
            ["dnsStarted": item.domainLookupStartDate != nil,
             "dnsFinished": item.domainLookupEndDate != nil,
             "connectStarted": item.connectStartDate != nil,
             "connectFinished": item.connectEndDate != nil,
             "tlsStarted": item.secureConnectionStartDate != nil,
             "tlsFinished": item.secureConnectionEndDate != nil,
             "localAddress": item.localAddress ?? "",
             "remoteAddress": item.remoteAddress ?? "",
             "proxy": item.isProxyConnection,
             "reused": item.isReusedConnection,
             "protocol": item.networkProtocolName ?? ""]
        }
        let result: [String: Any] = ["duration": metrics.taskInterval.duration,
                                   "transactions": rows, "httpStatus": (task.response as? HTTPURLResponse)?.statusCode ?? 0]
        if let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: result) {
            try? data.write(to: folder.appendingPathComponent("watchsteer-network-metrics.json"), options: .atomic)
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let host = Bundle.main.object(forInfoDictionaryKey: "WatchSteerLocalHost") as? String,
              challenge.protectionSpace.host.lowercased() == host.lowercased(),
              let encoded = Bundle.main.object(forInfoDictionaryKey: "WatchSteerLocalCertificate") as? String,
              let data = Data(base64Encoded: encoded),
              let certificate = SecCertificateCreateWithData(nil, data as CFData),
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        if Self.evaluate(trust, anchor: certificate, host: host) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    static func evaluate(_ trust: SecTrust, anchor: SecCertificate, host: String) -> Bool {
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return false }
        SecTrustSetNetworkFetchAllowed(trust, false)
        return SecTrustEvaluateWithError(trust, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let source = task.originalRequest?.url, let target = request.url,
              target.scheme == "https", target.host == source.host,
              target.port == source.port else { completionHandler(nil); return }
        completionHandler(request)
    }
}
