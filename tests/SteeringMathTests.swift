import Foundation

func rotation(_ degrees: Double, _ axis: SIMD3<Double>) -> Quaternion {
    let h = degrees * .pi / 360
    return Quaternion(x: axis.x * sin(h), y: axis.y * sin(h), z: axis.z * sin(h), w: cos(h))
}
func near(_ a: Double, _ b: Double, _ message: String, tolerance: Double = 1e-6) {
    precondition(abs(a-b) < tolerance, "\(message): \(a) != \(b)")
}

@main struct Tests {
    static func main() {
        let x = SIMD3<Double>(1,0,0), y = SIMD3<Double>(0,1,0), z = SIMD3<Double>(0,0,1)
        var m = SteeringMath()
        var response = SteeringMath()
        response.calibrate(.identity)
        for i in 1...4 { _ = response.update(rotation(80,x),timestamp: Double(i)*0.02) }
        precondition(response.filtered > 0.9, "A deliberate turn should reach 90% within 80 ms")
        near(m.update(.identity, timestamp: 0).value, 0, "not calibrated")
        // Non-identity neutral orientation catches quaternion-order bugs.
        let neutral = rotation(37, z) * rotation(-19, x)
        m.calibrate(neutral)
        near(m.angle(neutral)!, 0, "neutral")
        near(m.angle(rotation(30,x) * neutral)!,30,"default axis is screen-plane X")
        m.axis = y
        m.inverted = true
        m.calibrate(neutral)
        near(m.angle(rotation(30,y) * neutral)!,-30,"recalibration preserves selected axis and sign")
        m.inverted = false
        for axis in [x, y, z, SIMD3<Double>(0.6,0.8,0)] {
            m.calibrate(neutral)
            precondition(m.learnRight(rotation(30, axis) * neutral))
            near(m.angle(rotation(30, axis) * neutral)!, 30, "learn right")
            near(m.angle(rotation(-45, axis) * neutral)!, -45, "left")
        }
        m.calibrate(.identity)
        m.axis = y
        precondition(!m.learnRight(.identity))
        precondition(!m.learnRight(rotation(5,y)))
        near(m.angle(rotation(45,x))!, 0, "reject cross-axis swing")
        let q = rotation(25,y)
        near(m.angle(Quaternion(x:-q.x,y:-q.y,z:-q.z,w:-q.w))!,25,"q and -q equivalent")
        near(m.angle(rotation(179,y))!,179,"positive wrap")
        near(m.angle(rotation(181,y))!,-179,"negative wrap")
        m.inverted = true
        near(m.angle(q)!,-25,"invert")
        m.inverted = false
        m.calibrate(.identity)
        for i in 1...100 { _ = m.update(rotation(1,y), timestamp: Double(i)*0.02) }
        near(m.filtered,0,"deadzone")
        for i in 101...250 { _ = m.update(rotation(80,y),timestamp:Double(i)*0.02) }
        near(m.filtered,1,"saturation")
        m.calibrate(rotation(-23,x))
        near(m.filtered,0,"calibrate resets filter")
        m.axis = SIMD3(0.6,0.8,0); m.inverted = true
        let saved = SavedCalibration(math: m, referenceFrame: 4)!
        let restored = try! JSONDecoder().decode(SavedCalibration.self, from: JSONEncoder().encode(saved))
        precondition(restored.valid)
        var nextRun = SteeringMath()
        precondition(!restored.restore(into: &nextRun, referenceFrame: 4, fixedHeading: false))
        precondition(!restored.restore(into: &nextRun, referenceFrame: 1, fixedHeading: true))
        precondition(restored.restore(into: &nextRun, referenceFrame: 4, fixedHeading: true))
        precondition(nextRun.inverted && nextRun.axis == m.axis)
        near(nextRun.angle(rotation(-23,x))!,0,"saved neutral survives encoding and valid reference restoration")
        var session = ControlSession()
        session.start(localOnly: false)
        precondition(session.sampling)
        session.setForeground(false)
        precondition(session.started && !session.sampling && !session.localOnly)
        session.setForeground(true)
        precondition(session.sampling && session.started)
        session.stop()
        session.setForeground(false); session.setForeground(true)
        precondition(!session.started && !session.sampling)
        session.start(localOnly: true)
        session.setForeground(false); session.setForeground(true)
        precondition(session.started && session.localOnly && session.sampling)
        print("PASS: neutral, learned axes, sign, wrap, cross-axis, deadzone, filter, saturation")
    }
}
