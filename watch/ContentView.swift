import SwiftUI

struct ContentView: View {
    @StateObject private var controller = SteeringController()
    @Environment(\.scenePhase) private var phase
    private let accent = Color(red: 196.0/255, green: 246.0/255, blue: 164.0/255)
    @State private var page = ProcessInfo.processInfo.environment["WATCHSTEER_UI_PREVIEW"] == "settings" ? 1 : 0

    var body: some View {
        TabView(selection: $page) {
            control.tag(0)
            settings.tag(1)
        }
        .tabViewStyle(.page)
        .task { await controller.prepare(); controller.autoStartIfRequested() }
        .onChange(of: phase) { _, newPhase in
            controller.sceneChanged(active: newPhase == .active, background: newPhase == .background)
        }
        // Opening a picker, swiping pages, and system overlays must not stop
        // the user's session. Only the explicit Stop button ends it.
    }

    private var control: some View {
        ScrollView {
            VStack(spacing: 6) {
                HStack {
                    Image("BrandMark").resizable().scaledToFit().frame(width: 14, height: 14)
                    Text("WATCHSTEER").font(.system(size: 10, weight: .semibold))
                    Spacer()
                    Circle().fill(controller.status == "已连接" ? accent : Color.gray)
                        .frame(width: 6, height: 6)
                }.foregroundStyle(accent)
                HStack(spacing: 14) {
                    Image("BrandMark")
                        .resizable().scaledToFit().frame(width: 42, height: 42)
                        .rotationEffect(.degrees(controller.value * 120))
                    Text(controller.value, format: .number.precision(.fractionLength(2)))
                        .font(.system(size: 28, weight: .medium, design: .rounded).monospacedDigit())
                }.padding(.vertical, 2)
                Text(controller.status).font(.system(size: 10)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if controller.running {
                    if !controller.nearbyMacs.isEmpty {
                        Text("选择附近电脑").font(.caption2)
                        ForEach(controller.nearbyMacs) { mac in
                            actionButton(mac.name) { controller.connectBluetoothMac(mac.id) }
                        }
                    }
                    actionButton(controller.calibrated ? "重新校准正中" : "校准正中") { controller.calibrate() }
                        .disabled(controller.paused)
                    Text(controller.calibrationStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    axisSelector
                    HStack(spacing: 5) {
                        Button("反转") { controller.invert() }
                        Button("学习轴") { controller.learnRight() }.disabled(!controller.calibrated)
                    }.font(.system(size: 11))
                    Text(String(format: "采样 %.0f Hz  ·  发送 %.0f Hz\nRTT %.0f ms  ·  %.1f°",
                                controller.sampleHz, controller.sendHz, controller.rttMs, controller.angle))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("停止", role: .destructive) { controller.stop() }.font(.caption)
                } else {
                    actionButton("连接电脑") {
                        controller.start()
                        if !controller.running { page = 1 }
                    }
                    Button("仅手表测试") { controller.start(localOnly: true) }
                        .buttonStyle(.plain).font(.system(size: 12)).padding(.vertical, 7)
                    Button("连接设置 →") { page = 1 }.font(.caption2).buttonStyle(.plain)
                }
            }.padding(.horizontal, 5).padding(.bottom, 14)
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(accent.opacity(0.18), in: Capsule())
                .foregroundStyle(accent)
        }.buttonStyle(.plain)
    }

    private var axisSelector: some View {
        HStack(spacing: 4) {
            ForEach([SteeringAxis.x, .y, .z]) { axis in
                Button { controller.selectAxis(axis) } label: {
                    Text(axis.rawValue.uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(controller.selectedAxis == axis ? accent.opacity(0.20) : Color.white.opacity(0.12), in: Capsule())
                        .foregroundStyle(controller.selectedAxis == axis ? accent : Color.gray)
                }.buttonStyle(.plain)
            }
        }.accessibilityLabel("选择转向轴")
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                Text("连接电脑").font(.headline)
                if controller.preparing { Text("正在读取已保存的配对信息…").font(.caption2) }
                if !controller.credentialNotice.isEmpty { Text(controller.credentialNotice).font(.caption2).foregroundStyle(.orange) }
                Picker("连接方式", selection: $controller.connectionMode) {
                    ForEach(ConnectionMode.allCases) { mode in Text(mode.label).tag(mode) }
                }.disabled(controller.running)
                if controller.connectionMode == .bluetooth {
                    Text("先打开 Mac 的“启动蓝牙连接”，无需同一 Wi-Fi。电脑会出现在控制页。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button("忘记已选电脑") { controller.forgetBluetoothMac() }
                        .font(.caption2).disabled(controller.running)
                } else {
                    Text("与电脑处于同一 Wi-Fi").font(.caption2).foregroundStyle(.secondary)
                    Text("服务地址").font(.caption2)
                    TextField("https://…", text: $controller.baseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(size: 11))
                }
                Text("配对令牌").font(.caption2)
                SecureField("令牌", text: $controller.token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.system(size: 11))
                actionButton("保存并连接") {
                    controller.stop()
                    controller.start()
                    if controller.running { page = 0 }
                }
                Text(controller.status).font(.system(size: 10)).foregroundStyle(.secondary)
                Button("← 返回控制") { page = 0 }.font(.caption).buttonStyle(.plain)
            }.padding(.horizontal, 5).padding(.bottom, 14)
        }
    }
}
