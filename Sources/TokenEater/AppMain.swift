import AppKit
import SwiftUI

@MainActor
final class QuotaModel: ObservableObject {
    @Published var gpt: ProviderQuota = .loading("GPT")
    @Published var grok: ProviderQuota = .loading("Grok")
    @Published var updated: Date?
    @Published var refreshing = false
    @Published var floating = false

    var refreshNow: () -> Void = {}
    var setFloating: (Bool) -> Void = { _ in }
    var signInGPT: () -> Void = {}
    var signInGrok: () -> Void = {}
    var showSettings: () -> Void = {}
    var quit: () -> Void = {}

    func apply(gpt: ProviderQuota, grok: ProviderQuota) {
        self.gpt = gpt
        self.grok = grok
        updated = Date()
        refreshing = false
    }
}

@main
struct TokenEaterMain {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--self-test") {
            let failures = LogicTests.run()
            if failures.isEmpty {
                print("ok")
                exit(0)
            }
            for failure in failures {
                fputs("fail \(failure)\n", stderr)
            }
            exit(1)
        }
        if arguments.contains("--once") {
            let gpt = QuotaFetch.gpt()
            let grok = QuotaFetch.grok()
            print(summary(gpt))
            print(summary(grok))
            exit(0)
        }
        if let preview = arguments.firstIndex(of: "--preview"), arguments.count > preview + 1 {
            let url = URL(fileURLWithPath: arguments[preview + 1])
            let app = NSApplication.shared
            DispatchQueue.main.async {
                renderPreview(to: url)
                app.terminate(nil)
            }
            app.run()
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private let model = QuotaModel()
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var floating = false
    private var loggingIn = false
    private var offeredGPT = false
    private var offeredGrok = false
    private var settingsWindow: NSWindow?
    private let settingsModel = SettingsModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppInstaller.relocateIfNeeded() || AppInstaller.isDuplicateInstance() {
            NSApp.terminate(nil)
            return
        }
        LaunchAtLogin.enableByDefaultIfNeeded()
        model.refreshNow = { [weak self] in self?.refresh() }
        model.setFloating = { [weak self] value in self?.applyFloating(value) }
        model.signInGPT = { [weak self] in self?.signInGPT() }
        model.signInGrok = { [weak self] in self?.signInGrok() }
        model.showSettings = { [weak self] in self?.showSettings() }
        model.quit = { NSApp.terminate(nil) }

        let saved = WindowStore.load()
        floating = saved?.floating ?? false
        model.floating = floating

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 280),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = windowLevel(floating: floating)
        panel.collectionBehavior = collectionBehavior(floating: floating)
        panel.isReleasedWhenClosed = false

        let host = DragHostingView(rootView: WidgetView(model: model))
        host.onDoubleClick = { [weak self] in self?.refresh() }
        panel.contentView = host
        self.panel = panel
        place(panel, saved: saved)
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowMoved),
            name: NSWindow.didMoveNotification,
            object: panel
        )

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        persist()
    }

    private func refresh() {
        guard refreshTask == nil, !loggingIn else { return }
        model.refreshing = true
        let model = self.model
        refreshTask = Task {
            let gpt = await Task.detached(operation: { QuotaFetch.gpt() }).value
            let grok = await Task.detached(operation: { QuotaFetch.grok() }).value
            model.apply(gpt: gpt, grok: grok)
            self.refreshTask = nil
            self.offerLoginIfNeeded()
        }
    }

    private func offerLoginIfNeeded() {
        guard !loggingIn else { return }
        if !offeredGPT && model.gpt.windows.isEmpty && OfficialLogin.needsOfficialLogin(model.gpt.message) {
            offeredGPT = true
            signInGPT()
            return
        }
        if !offeredGrok && model.grok.windows.isEmpty && OfficialLogin.needsOfficialLogin(model.grok.message) {
            offeredGrok = true
            signInGrok()
        }
    }

    private func signInGPT() {
        guard !loggingIn else { return }
        loggingIn = true
        elevate()
        let previous = model.gpt
        model.gpt.message = "正在打开官方登录页"
        model.refreshing = true
        Task {
            let outcome = await Task.detached(operation: { QuotaFetch.signInGPT() }).value
            if outcome.windows.isEmpty, !previous.windows.isEmpty {
                var restored = previous
                restored.message = "登录未完成，仍是当前账号"
                model.gpt = restored
            } else {
                model.gpt = outcome
            }
            model.updated = Date()
            model.refreshing = false
            loggingIn = false
            restoreLevel()
        }
    }

    private func signInGrok() {
        guard !loggingIn else { return }
        loggingIn = true
        elevate()
        let previous = model.grok
        let stamp = QuotaFetch.grokStamp()
        model.grok.message = QuotaFetch.openGrokLogin()
        model.refreshing = true
        Task {
            let changed = await Task.detached(operation: {
                QuotaFetch.waitForGrokChange(since: stamp, timeout: 180)
            }).value
            if changed {
                model.grok = await Task.detached(operation: { QuotaFetch.grok() }).value
            } else if previous.windows.isEmpty {
                model.grok = .unavailable("Grok", "在 Grok Bot 里完成登录后再刷新")
            } else {
                var restored = previous
                restored.message = "还是当前账号"
                model.grok = restored
            }
            model.updated = Date()
            model.refreshing = false
            loggingIn = false
            restoreLevel()
        }
    }

    private func showSettings() {
        settingsModel.reload()
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(model: settingsModel))
            let window = NSWindow(contentViewController: host)
            window.title = "设置"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.setContentSize(NSSize(width: 380, height: 168))
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func elevate() {
        panel?.level = .floating
        panel?.orderFrontRegardless()
    }

    private func restoreLevel() {
        guard let panel else { return }
        panel.level = windowLevel(floating: floating)
        panel.collectionBehavior = collectionBehavior(floating: floating)
    }

    private func applyFloating(_ value: Bool) {
        floating = value
        model.floating = value
        guard let panel else { return }
        panel.level = windowLevel(floating: value)
        panel.collectionBehavior = collectionBehavior(floating: value)
        panel.orderFrontRegardless()
        persist()
    }

    private func windowLevel(floating: Bool) -> NSWindow.Level {
        if floating { return .floating }
        return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    private func collectionBehavior(floating: Bool) -> NSWindow.CollectionBehavior {
        if floating { return [.canJoinAllSpaces, .fullScreenAuxiliary] }
        return [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    private func place(_ panel: NSPanel, saved: WindowStore.State?) {
        let size = panel.frame.size
        if let saved, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: saved.x, y: saved.y)) }) {
            var frame = NSRect(x: saved.x, y: saved.y, width: size.width, height: size.height)
            frame = frame.intersection(screen.visibleFrame)
            if frame.width > 40, frame.height > 40 {
                panel.setFrameOrigin(NSPoint(x: saved.x, y: saved.y))
                return
            }
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - 28,
            y: visible.minY + 28
        ))
    }

    @objc private func windowMoved() {
        persist()
    }

    private func persist() {
        guard let panel else { return }
        WindowStore.save(WindowStore.State(
            x: panel.frame.origin.x,
            y: panel.frame.origin.y,
            floating: floating
        ))
    }
}

enum WindowStore {
    struct State {
        var x: Double
        var y: Double
        var floating: Bool
    }

    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenEater", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("window.json")
    }

    static func load() -> State? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let x = object["x"] as? Double,
              let y = object["y"] as? Double else {
            return nil
        }
        return State(x: x, y: y, floating: (object["floating"] as? Bool) ?? false)
    }

    static func save(_ state: State) {
        let object: [String: Any] = ["x": state.x, "y": state.y, "floating": state.floating]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

final class DragHostingView<Content: View>: NSHostingView<Content> {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        window?.performDrag(with: event)
    }
}

private func summary(_ quota: ProviderQuota) -> String {
    if quota.windows.isEmpty {
        return "\(quota.name): \(quota.message ?? "没有数据")"
    }
    let windows = quota.windows.map { window in
        let reset = QuotaMath.resetText(until: window.resetsAt) ?? "无重置时间"
        return "\(window.remainingPercent)% \(window.label) \(reset)"
    }.joined(separator: " | ")
    let plan = quota.plan.map { " \($0)" } ?? ""
    return "\(quota.name)\(plan): \(windows)"
}

@MainActor
private func renderPreview(to url: URL) {
    let model = QuotaModel()
    model.gpt = ProviderQuota(
        name: "GPT",
        plan: "Pro",
        windows: [
            WindowQuota(
                id: "week",
                label: "每周",
                remainingPercent: 56,
                resetsAt: Date().addingTimeInterval(4 * 24 * 3600 + 5 * 3600)
            ),
        ],
        message: nil
    )
    model.grok = ProviderQuota(
        name: "Grok",
        plan: "Grok Bot Plan",
        windows: [
            WindowQuota(
                id: "week",
                label: "每周",
                remainingPercent: 18,
                resetsAt: Date().addingTimeInterval(2 * 24 * 3600 + 3 * 3600)
            ),
        ],
        message: nil
    )
    model.updated = Date()
    let renderer = ImageRenderer(content: WidgetView(model: model).frame(width: 300))
    renderer.scale = 2
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("preview failed\n", stderr)
        return
    }
    try? png.write(to: url)
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var launchAtLogin = LaunchAtLogin.isEnabled
    @Published var note = ""

    func reload() {
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchAtLogin = LaunchAtLogin.isEnabled
            note = enabled ? "下次登录这台 Mac 时会自动打开" : "已关闭，下次登录不会自动打开"
        } catch {
            launchAtLogin = LaunchAtLogin.isEnabled
            note = "没能更改开机自启动"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("开机自启动", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .font(.system(size: 14, weight: .medium))
            Text("登录这台 Mac 时自动打开桌面小组件。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.note.isEmpty {
                Text(model.note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 380, height: 168, alignment: .topLeading)
    }
}

struct WidgetView: View {
    @ObservedObject var model: QuotaModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            provider(model.gpt, tint: Color(red: 0.49, green: 0.86, blue: 0.67))
            divider
            provider(model.grok, tint: Color(red: 0.78, green: 0.86, blue: 1.0))
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: 300, alignment: .leading)
        .background(card)
        .preferredColorScheme(.dark)
        .contextMenu {
            Button("刷新") { model.refreshNow() }
            Button(model.gpt.windows.isEmpty ? "登录 GPT" : "切换 GPT 账号") { model.signInGPT() }
            Button(model.grok.windows.isEmpty ? "登录 Grok" : "切换 Grok 账号") { model.signInGrok() }
            Button(model.floating ? "贴回桌面" : "浮在窗口上方") {
                model.setFloating(!model.floating)
            }
            Button("设置…") { model.showSettings() }
            Divider()
            Button("退出") { model.quit() }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("TOKENEATER")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.42))
            Spacer()
            if model.refreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
        }
        .padding(.bottom, 12)
    }

    private func provider(_ quota: ProviderQuota, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(quota.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if let plan = quota.plan {
                    Text(plan)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
            }
            if let account = quota.account, !account.isEmpty {
                Text(account)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if quota.windows.isEmpty {
                Text(quota.message ?? "没有数据")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            } else {
                ForEach(quota.windows) { window in
                    windowBlock(window, tint: tint)
                }
                if let message = quota.message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func windowBlock(_ window: WindowQuota, tint: Color) -> some View {
        let color = meterColor(remaining: window.remainingPercent, tint: tint)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(window.remainingPercent)%")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .monospacedDigit()
                Text("剩余")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text(window.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule()
                        .fill(color)
                        .frame(width: max(6, geo.size.width * CGFloat(window.remainingPercent) / 100))
                }
            }
            .frame(height: 6)
            if let reset = QuotaMath.resetText(until: window.resetsAt) {
                Text(reset)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.46))
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(height: 1)
            .padding(.vertical, 8)
    }

    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(footerText(now: context.date))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.32))
                .padding(.top, 10)
        }
    }

    private func footerText(now: Date) -> String {
        guard let updated = model.updated else { return "拖动可移动 · 右键有菜单" }
        let seconds = Int(now.timeIntervalSince(updated))
        if seconds < 15 { return "刚刚更新 · 拖动可移动" }
        if seconds < 60 { return "\(seconds) 秒前更新" }
        return "\(max(seconds / 60, 1)) 分钟前更新"
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.black.opacity(0.58))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.38), radius: 18, y: 10)
    }

    private func meterColor(remaining: Int, tint: Color) -> Color {
        if remaining <= 15 { return Color(red: 1.0, green: 0.45, blue: 0.40) }
        if remaining <= 35 { return Color(red: 1.0, green: 0.74, blue: 0.38) }
        return tint
    }
}
