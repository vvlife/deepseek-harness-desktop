// DeepSeek Harness Desktop — 自包含桌面 APP（内置 Paseo + dsh provider）。
//
// DMG 拖进「应用程序」即可用：内置 universal Node 运行时、完整 Paseo
// （daemon + Web UI + 移动端直连配对）与完整 dsh（经 ACP 桥注册为 Paseo 的
// 「DeepSeek Harness」provider）。不依赖本机 Node/Homebrew/dsh/Paseo；
// 使用私有 PASEO_HOME / DSH_HOME 与非默认端口，与本机已有实例互不干扰。
//
// 启动流程：写基础配置（listen/webUi）→ 准备 ACP 桥与 wrapper → 首跑注册
// provider → paseo daemon start → 轮询 Web UI 就绪 → WKWebView 打开。
// 首次打开**不**要求填 provider；需要时通过 ⌘, 设置页配置（也可在 Paseo
// Web UI 内操作）。移动端配对：设置页一键生成 pairing 链接与二维码。
//
// 数据目录：~/Library/Application Support/DeepSeek Harness Desktop/
//   ├── paseo-home/   （PASEO_HOME，与 ~/.paseo 无关）
//   └── dsh-home/     （DSH_HOME，与 ~/.dsh 无关）
//
// 构建：app/make-app.sh（swiftc 直编，无 Xcode 工程；arm64+x86_64 universal）。
import SwiftUI
import WebKit
import CoreImage

// ---------------------------------------------------------------------------
// 路径与全局状态
// ---------------------------------------------------------------------------
private let fm = FileManager.default
private let appSupportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  .appendingPathComponent("DeepSeek Harness Desktop", isDirectory: true)
private let paseoHomeDir = appSupportDir.appendingPathComponent("paseo-home", isDirectory: true)
private let dshHomeDir = appSupportDir.appendingPathComponent("dsh-home", isDirectory: true)

private func bundledResource(_ path: String) -> String? {
  Bundle.main.resourceURL?.appendingPathComponent(path).path
}

final class AppState: ObservableObject {
  static let shared = AppState()
  @Published var showPairing = false
  @Published var showOnboarding = false

  enum ViewMode: String {
    case paseo = "Paseo"
    case harnessWeb = "Harness Web"
  }

  /// 当前展示的界面：Paseo Web UI / dsh web（Harness Web）。
  /// 切换只是换「视图」——Paseo daemon 始终运行，移动端连接不受影响。
  @Published var viewMode: ViewMode {
    didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
  }

  private init() {
    let stored = UserDefaults.standard.string(forKey: "viewMode")
    viewMode = ViewMode(rawValue: stored ?? "") ?? .paseo
  }
}

private enum AppError: LocalizedError {
  case runtimeMissing
  case cliFailed(String, String)
  var errorDescription: String? {
    switch self {
    case .runtimeMissing:
      return "找不到内置运行时（应用包不完整，请重新下载 DMG）。"
    case .cliFailed(let step, let out):
      return "\(step) 失败：\(out.suffix(600))"
    }
  }
}

// ---------------------------------------------------------------------------
// 内置 Paseo daemon 管理
// ---------------------------------------------------------------------------
@MainActor
final class DaemonManager: ObservableObject {
  static let shared = DaemonManager()

  enum State: Equatable {
    case starting
    case running(URL)
    case failed(String)
  }

  @Published private(set) var state: State = .starting
  @Published private(set) var logTail = ""
  @Published var pairingLink: String? = nil

  private var booting = false

  /// 诊断日志（数据目录/app.log），排查启动链路用
  private let trailURL = appSupportDir.appendingPathComponent("app.log")
  nonisolated func trail(_ msg: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: trailURL) {
      h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
      try? data.write(to: trailURL)
    }
  }

  var nodePath: String? { bundledResource("runtime/node/bin/node") }
  var cliPath: String? {
    bundledResource("runtime/paseo/node_modules/@getpaseo/cli/dist/index.js")
  }
  var webUIDistPath: String? { bundledResource("runtime/paseo-app-dist") }

  /// 监听端口：首次选定后持久化（避开用户本机 Paseo 默认的 6767）
  var port: Int {
    let stored = UserDefaults.standard.integer(forKey: "paseoPort")
    if stored > 0 { return stored }
    let picked = Self.findFreePort(startingAt: 6868) ?? 6868
    UserDefaults.standard.set(picked, forKey: "paseoPort")
    return picked
  }

  var webURL: URL { URL(string: "http://127.0.0.1:\(port)/")! }

  var telemetryEnabled: Bool {
    UserDefaults.standard.bool(forKey: "telemetryEnabled")
  }

  /// 稳定的 daemon serverId：Paseo 默认在 $PASEO_HOME/server-id 随机生成，
  /// 一旦数据目录重建就会变化；而 Web UI 的 host 注册表（localStorage）拒绝
  /// 接受 serverId 与记录不符的 daemon，会陷入「连接→断开」死循环
  /// （设置页表现为 "Connect to this host to see providers"）。
  /// 这里用 PASEO_SERVER_ID 固定身份，并在身份变化时清理 Web 数据（见
  /// reconcileWebDataIfNeeded）。
  var serverId: String {
    if let stored = UserDefaults.standard.string(forKey: "paseoServerId"), !stored.isEmpty {
      return stored
    }
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    let random = String((0..<12).map { _ in alphabet.randomElement()! })
    let generated = "srv_\(random)"
    UserDefaults.standard.set(generated, forKey: "paseoServerId")
    return generated
  }

  // MARK: 生命周期

  func start() {
    guard !booting else { return }
    if case .running = state { return }
    booting = true
    state = .starting
    logTail = ""
    trail("start() 开始（port=\(port)）")
    Task {
      do {
        try prepareEnvironment()
        trail("prepareEnvironment ✔")
        try await ensureProviderRegistered()
        trail("ensureProviderRegistered ✔")
        // 默认退出不停服务，重开 APP 时 daemon 往往已在运行；
        // `paseo daemon start` 非幂等（已运行会因端口占用失败），先探测再决定是否启动
        if await Self.httpOK(webURL) {
          trail("内置服务已在运行，直接复用")
        } else {
          do {
            try await runCLI(["daemon", "start"], step: "启动内置服务")
            trail("daemon start ✔，等待 Web UI")
          } catch {
            // 端口被旧 daemon（或无 Web UI 配置的残留进程）占用：restart 会先停后启
            trail("daemon start 失败，改用 restart：\(error.localizedDescription)")
            try await runCLI(["daemon", "restart"], step: "重启内置服务")
            trail("daemon restart ✔，等待 Web UI")
          }
        }
        if await pollWebReady(seconds: 120) {
          trail("Web UI 就绪")
          await reconcileWebDataIfNeeded()
          state = .running(webURL)
        } else {
          trail("Web UI 超时未就绪")
          state = .failed("内置服务已启动，但 Web UI 长时间未就绪。可在设置页「重启服务」重试。")
        }
      } catch {
        trail("start() 失败：\(error.localizedDescription)")
        state = .failed(error.localizedDescription)
      }
      booting = false
    }
  }

  func restart() {
    guard !booting else { return }
    booting = true
    state = .starting
    Task {
      do {
        try prepareEnvironment()
        try await runCLI(["daemon", "restart"], step: "重启服务")
        if await pollWebReady(seconds: 120) {
          state = .running(webURL)
        } else {
          state = .failed("重启后 Web UI 未就绪。")
        }
      } catch {
        state = .failed(error.localizedDescription)
      }
      booting = false
    }
  }

  /// daemon serverId 变化时（数据目录重建/旧版本随机 id），Web UI localStorage
  /// 里的 host 注册表即失效且不可恢复（Paseo 拒绝采纳新 id），必须清掉让
  /// Web UI 依据 index.html 注入的连接提示重新自举。
  /// 以 /api/status 返回的「实际运行身份」为准——升级期间旧 daemon 可能仍在跑。
  private func reconcileWebDataIfNeeded() async {
    guard let actual = await fetchRunningServerId() else { return }
    let last = UserDefaults.standard.string(forKey: "webDataServerId")
    guard last != actual else { return }
    trail("serverId 变化（\(last ?? "无记录") → \(actual)），清理 Web UI 本地数据")
    let store = WKWebsiteDataStore.default()
    let types = WKWebsiteDataStore.allWebsiteDataTypes()
    await store.removeData(ofTypes: types, modifiedSince: .distantPast)
    UserDefaults.standard.set(actual, forKey: "webDataServerId")
  }

  private func fetchRunningServerId() async -> String? {
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/status")!)
    req.timeoutInterval = 5
    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          (resp as? HTTPURLResponse)?.statusCode == 200,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = obj["serverId"] as? String, !id.isEmpty else { return nil }
    return id
  }

  /// 退出兜底（非 MainActor）：仅在用户勾选「退出时停止服务」时调用
  nonisolated func stopImmediate() {
    guard let node = bundledResource("runtime/node/bin/node"),
          let cli = bundledResource("runtime/paseo/node_modules/@getpaseo/cli/dist/index.js")
    else { return }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: node)
    task.arguments = [cli, "daemon", "stop"]
    var env = ProcessInfo.processInfo.environment
    env["PASEO_HOME"] = paseoHomeDir.path
    env["HOME"] = NSHomeDirectory()
    task.environment = env
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return }
    let sem = DispatchSemaphore(value: 0)
    task.terminationHandler = { _ in sem.signal() }
    if sem.wait(timeout: .now() + 6) == .timedOut { task.terminate() }
  }

  // MARK: 首跑准备

  /// 建目录 + 写/补 config.json（listen 与 webUi；不动 relay、providers 等其他键）
  private func prepareEnvironment() throws {
    guard nodePath != nil, cliPath != nil, let webUIDist = webUIDistPath else {
      throw AppError.runtimeMissing
    }
    try fm.createDirectory(at: paseoHomeDir, withIntermediateDirectories: true,
                           attributes: [.posixPermissions: 0o700])
    try fm.createDirectory(at: dshHomeDir, withIntermediateDirectories: true,
                           attributes: [.posixPermissions: 0o700])

    let configURL = paseoHomeDir.appendingPathComponent("config.json")
    var config: [String: Any] = [:]
    if let data = fm.contents(atPath: configURL.path),
       let obj = try? JSONSerialization.jsonObject(with: data), let dict = obj as? [String: Any] {
      config = dict
    }
    var daemon = config["daemon"] as? [String: Any] ?? [:]
    daemon["listen"] = daemon["listen"] ?? "127.0.0.1:\(port)"
    config["daemon"] = daemon
    var features = config["features"] as? [String: Any] ?? [:]
    features["webUi"] = ["enabled": true, "distDir": webUIDist]
    config["features"] = features
    let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: configURL, options: .atomic)

    try prepareBridge()
  }

  /// ACP 桥拷入私有 DSH_HOME，并生成指向内置运行时的 wrapper（telemetry 随开关重写）
  func prepareBridge() throws {
    guard let node = nodePath,
          let bridgeSrc = bundledResource("installer/bridge/dsh-acp-bridge.mjs"),
          let dshShim = bundledResource("runtime/node/bin/dsh")
    else { throw AppError.runtimeMissing }
    let bridgeDir = dshHomeDir.appendingPathComponent("paseo-bridge", isDirectory: true)
    let bridgeDst = bridgeDir.appendingPathComponent("dsh-acp-bridge.mjs")
    let wrapper = bridgeDir.appendingPathComponent("bridge-wrapper.sh")
    try fm.createDirectory(at: bridgeDir, withIntermediateDirectories: true)
    if fm.fileExists(atPath: bridgeDst.path) { try fm.removeItem(at: bridgeDst) }
    try fm.copyItem(atPath: bridgeSrc, toPath: bridgeDst.path)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridgeDst.path)
    let runtimeBin = (node as NSString).deletingLastPathComponent
    let script = """
      #!/bin/sh
      # 由 DeepSeek Harness Desktop 生成：Paseo → dsh 的 ACP 桥，全部使用 APP 内置运行时。
      export DSH_HOME="\(dshHomeDir.path)"
      export DSH_BIN="\(dshShim)"
      export DSH_TELEMETRY_DISABLED="\(telemetryEnabled ? "0" : "1")"
      export PATH="\(runtimeBin):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
      exec "\(node)" "\(bridgeDst.path)"
      """
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
  }

  var bridgeWrapperPath: String {
    dshHomeDir.appendingPathComponent("paseo-bridge/bridge-wrapper.sh").path
  }

  /// 首次启动：以默认 provider（DeepSeek 官方、暂不配凭据）完成注册
  private func ensureProviderRegistered() async throws {
    let providerJSON = dshHomeDir.appendingPathComponent("paseo-bridge/provider.json")
    guard !fm.fileExists(atPath: providerJSON.path) else { return }
    try await runSetupProvider(args: ["--provider", "deepseek", "--skip-auth", "--yes",
                                      "--bridge-command", bridgeWrapperPath],
                               step: "首次注册 provider")
  }

  // MARK: 子进程

  private func processEnv() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let runtimeBin = ((nodePath ?? "") as NSString).deletingLastPathComponent
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(runtimeBin)"
    env["HOME"] = NSHomeDirectory()
    env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
    env["PASEO_HOME"] = paseoHomeDir.path
    env["DSH_HOME"] = dshHomeDir.path
    env["PASEO_SERVER_ID"] = serverId
    // daemon 持久化配置可能被 schema 归一化丢弃，Web UI 开关以 env 为准（最高优先级）
    if let dist = webUIDistPath {
      env["PASEO_WEB_UI_ENABLED"] = "1"
      env["PASEO_WEB_UI_DIST_DIR"] = dist
    }
    env["CI"] = "1"
    return env
  }

  @discardableResult
  private func runCLI(_ args: [String], step: String) async throws -> String {
    guard let node = nodePath, let cli = cliPath else { throw AppError.runtimeMissing }
    let (code, out) = await Self.runProcess(node, [cli] + args, env: processEnv())
    appendLog("$ paseo \(args.joined(separator: " "))\n\(out)")
    guard code == 0 else { throw AppError.cliFailed(step, out) }
    return out
  }

  @discardableResult
  func runSetupProvider(args: [String], step: String) async throws -> String {
    guard let node = nodePath,
          let script = bundledResource("installer/scripts/setup-provider.mjs")
    else { throw AppError.runtimeMissing }
    let (code, out) = await Self.runProcess(node, [script] + args, env: processEnv())
    appendLog("$ setup-provider \(args.joined(separator: " "))\n\(out)")
    guard code == 0 else { throw AppError.cliFailed(step, out) }
    return out
  }

  /// 生成移动端配对链接（启用 relay 并取回 offer URL）
  func generatePairingLink() async throws -> String {
    let out = try await runCLI(["daemon", "pair", "--relay"], step: "生成配对链接")
    guard let link = out.components(separatedBy: .whitespacesAndNewlines)
      .first(where: { $0.hasPrefix("https://app.paseo.sh/#offer=") || $0.hasPrefix("https://app.paseo.sh/?") || $0.contains("#offer=") })
    else { throw AppError.cliFailed("解析配对链接", out) }
    pairingLink = link
    return link
  }

  // MARK: dsh web（Harness Web 界面，与 Paseo 并存的第二视图）

  enum DshWebState: Equatable {
    case idle
    case starting
    case running
    case failed(String)
  }

  @Published private(set) var dshWebState: DshWebState = .idle
  private var dshWebProcess: Process?
  private var dshWebBooting = false

  /// dsh web 端口：独立于 Paseo 与用户本机 dsh（默认 3080），首次选定后持久化
  var dshWebPort: Int {
    let stored = UserDefaults.standard.integer(forKey: "dshWebPort")
    if stored > 0 { return stored }
    let picked = Self.findFreePort(startingAt: 3180) ?? 3180
    UserDefaults.standard.set(picked, forKey: "dshWebPort")
    return picked
  }

  var dshWebURL: URL { URL(string: "http://127.0.0.1:\(dshWebPort)/")! }

  /// 按需启动 dsh web（同一私有 DSH_HOME，Agnes/DeepSeek 凭据直接生效）。
  /// 已在运行（含 APP 异常退出遗留的进程）则直接复用；异常退出后再次进入视图会自动拉起。
  func startDshWeb() {
    if case .running = dshWebState { return }
    guard !dshWebBooting else { return }
    guard let node = nodePath,
          let dshEntry = bundledResource("runtime/dsh/lib/bin.js")
    else {
      dshWebState = .failed("找不到内置 dsh 运行时（应用包不完整）。")
      return
    }
    dshWebBooting = true
    dshWebState = .starting
    trail("startDshWeb()（port=\(dshWebPort)）")

    Task {
      defer { dshWebBooting = false }
      // 已有健康实例（上次启动的或 APP 异常退出遗留的）：直接复用，避免端口冲突
      if await Self.httpOK(dshWebURL) {
        trail("dsh web 已在运行，直接复用")
        dshWebState = .running
        return
      }
      let task = Process()
      task.executableURL = URL(fileURLWithPath: node)
      task.arguments = [dshEntry, "web", "--host", "127.0.0.1", "--port", "\(dshWebPort)"]
      var env = processEnv()
      env["DSH_TELEMETRY_DISABLED"] = telemetryEnabled ? "0" : "1"
      task.environment = env
      task.standardOutput = FileHandle.nullDevice
      task.standardError = FileHandle.nullDevice
      task.terminationHandler = { [weak self] terminated in
        Task { @MainActor in
          guard let self, self.dshWebProcess === terminated else { return }
          self.dshWebProcess = nil
          if case .running = self.dshWebState {
            self.dshWebState = .idle
            self.trail("dsh web 进程退出")
            // 用户正停在该界面：自动重新拉起（adopt-first 保证不会与残留进程冲突）
            if AppState.shared.viewMode == .harnessWeb { self.startDshWeb() }
          }
        }
      }
      do {
        try task.run()
        dshWebProcess = task
      } catch {
        dshWebState = .failed("dsh web 启动失败：\(error.localizedDescription)")
        return
      }
      let ok = await Self.pollHTTP(dshWebURL, seconds: 120)
      if ok {
        trail("dsh web 就绪")
        dshWebState = .running
      } else if let task = dshWebProcess, !task.isRunning {
        trail("dsh web 进程已退出")
        dshWebState = .failed("dsh web 启动后退出。可切回 Paseo 视图后再试。")
      } else {
        trail("dsh web 超时未就绪（进程仍在）")
        dshWebState = .failed("dsh web 启动较慢，仍在初始化。点「重试」即可（会直接接管已就位的进程）。")
      }
    }
  }

  /// 退出时停止 dsh web 子进程（主线程调用，随 APP 退出，不留孤儿进程）
  func stopDshWeb() {
    guard let task = dshWebProcess, task.isRunning else { return }
    task.terminate()
    dshWebProcess = nil
  }

  private static func pollHTTP(_ url: URL, seconds: Int) async -> Bool {
    for _ in 0..<seconds {
      if await httpOK(url) { return true }
      try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    return false
  }

  private func pollWebReady(seconds: Int) async -> Bool {
    for _ in 0..<seconds {
      if await Self.httpOK(webURL) { return true }
      try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    return false
  }

  private static func httpOK(_ url: URL) async -> Bool {
    var req = URLRequest(url: url)
    req.timeoutInterval = 5
    guard let (_, resp) = try? await URLSession.shared.data(for: req),
          let http = resp as? HTTPURLResponse else { return false }
    return http.statusCode == 200
  }

  private static func runProcess(_ executable: String, _ args: [String],
                                 env: [String: String]) async -> (Int32, String) {
    await Task.detached {
      let task = Process()
      task.executableURL = URL(fileURLWithPath: executable)
      task.arguments = args
      task.environment = env
      let pipe = Pipe()
      task.standardOutput = pipe
      task.standardError = pipe
      do { try task.run() } catch { return (Int32(-1), error.localizedDescription) }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      task.waitUntilExit()
      return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }.value
  }

  private static func findFreePort(startingAt base: Int) -> Int? {
    for port in base..<(base + 20) {
      let fd = socket(AF_INET, SOCK_STREAM, 0)
      if fd < 0 { continue }
      var addr = sockaddr_in()
      addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      addr.sin_family = sa_family_t(AF_INET)
      addr.sin_port = in_port_t(port).bigEndian
      addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
      let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
      }
      close(fd)
      if ok { return port }
    }
    return nil
  }

  private func appendLog(_ text: String) {
    logTail = String((logTail + text + "\n").suffix(12_000))
  }
}

// ---------------------------------------------------------------------------
// WKWebView 封装
// ---------------------------------------------------------------------------
final class WebController: ObservableObject {
  weak var webView: WKWebView?
  @Published var currentURL: URL?
  func reload() { webView?.reload() }
  func openInBrowser() {
    guard let url = webView?.url ?? currentURL else { return }
    NSWorkspace.shared.open(url)
  }
}

private struct WebView: NSViewRepresentable {
  let url: URL
  @ObservedObject var controller: WebController

  func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.preferences.setValue(true, forKey: "developerExtrasEnabled")
    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    webView.allowsMagnification = true
    controller.webView = webView
    webView.load(URLRequest(url: url))
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    if webView.url == nil { webView.load(URLRequest(url: url)) }
  }

  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let controller: WebController
    init(controller: WebController) { self.controller = controller }

    private func isLocal(_ url: URL?) -> Bool {
      guard let host = url?.host else { return false }
      return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      controller.currentURL = webView.url
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
      let url = navigationAction.request.url
      if navigationAction.targetFrame == nil, let url {
        NSWorkspace.shared.open(url) // target=_blank → 系统浏览器
        decisionHandler(.cancel)
        return
      }
      if navigationAction.navigationType == .linkActivated, let url, !isLocal(url) {
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
        return
      }
      decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
      if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
      return nil
    }
  }
}

// ---------------------------------------------------------------------------
// 移动端直连子页面（Harness Web 界面工具栏「手机」图标打开）
// ---------------------------------------------------------------------------
private struct PairingSheet: View {
  @ObservedObject private var daemon = DaemonManager.shared
  @State private var busy = false
  @State private var pairError = ""
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 10) {
        Image(systemName: "iphone").font(.system(size: 28))
        VStack(alignment: .leading, spacing: 2) {
          Text("移动端直连").font(.title3.weight(.bold))
          Text("用手机 Paseo App 遥控本 APP 的 agent").font(.caption).foregroundStyle(.secondary)
        }
      }

      Text("用手机 Paseo App 扫描下方二维码（或打开配对链接），即可连到本 APP 的内置服务（经 Paseo 官方 relay，端到端加密）。配对后，Paseo 界面里的所有 agent 对话在手机与电脑之间实时同步。退出本 APP 后服务默认保持运行，手机可继续连接。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if let link = daemon.pairingLink {
        HStack(alignment: .top, spacing: 16) {
          if let qr = Self.qrImage(from: link) {
            Image(nsImage: qr)
              .resizable()
              .interpolation(.none)
              .frame(width: 168, height: 168)
              .background(Color.white)
              .clipShape(RoundedRectangle(cornerRadius: 8))
          }
          VStack(alignment: .leading, spacing: 8) {
            Text(link).font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .lineLimit(5)
            HStack {
              Button("复制链接") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
              }
              Button("在浏览器打开") { NSWorkspace.shared.open(URL(string: link)!) }
            }
            .font(.caption)
          }
        }
      }

      if !pairError.isEmpty {
        Text(pairError).font(.caption).foregroundStyle(.red)
      }

      Text("手机提示超时？relay 链路可能正在重连，点「刷新配对码」后立刻扫码重试；多次失败请检查电脑/手机网络（需能访问 relay.paseo.sh）。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack {
        Button(action: generate) {
          Label(busy ? "生成中…" : (daemon.pairingLink == nil ? "生成配对二维码" : "刷新配对码"),
                systemImage: "qrcode")
        }
        .buttonStyle(.borderedProminent)
        .disabled(busy)
        if busy { ProgressView().scaleEffect(0.8) }
        Spacer()
        Button("完成") { onClose() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 520)
    .onAppear { if daemon.pairingLink == nil, !busy { generate() } }
  }

  private func generate() {
    busy = true
    pairError = ""
    Task {
      do {
        _ = try await daemon.generatePairingLink()
      } catch {
        pairError = error.localizedDescription
      }
      busy = false
    }
  }

  static func qrImage(from string: String) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(string.data(using: .utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
  }
}

// ---------------------------------------------------------------------------
// 首次启动引导（Host 与 provider 配置说明）
// ---------------------------------------------------------------------------
private struct OnboardingView: View {
  @ObservedObject private var daemon = DaemonManager.shared
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 10) {
        Text("🐋").font(.system(size: 34))
        VStack(alignment: .leading, spacing: 2) {
          Text("欢迎使用 DeepSeek Harness Desktop").font(.title3.weight(.bold))
          Text("30 秒了解它是怎么工作的").font(.caption).foregroundStyle(.secondary)
        }
      }

      GroupBox {
        VStack(alignment: .leading, spacing: 8) {
          Label("内置 Host 已自动就绪，无需手动配置", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
          Text("APP 自带 Paseo 服务（Host），启动后窗口里的 Web UI 会自动连接它（127.0.0.1:\(daemon.port)）。你不需要在 Web UI 里手动「添加 Host」；如果看到 \"Connect to this host…\"，说明服务还在启动，稍等片刻或点工具栏「重载」即可。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } label: {
        Text("① Host（不用管）").font(.headline)
      }

      GroupBox {
        VStack(alignment: .leading, spacing: 8) {
          Text("要让 agent 真正对话，需要配一个 LLM 提供商：顶部切到「Harness Web」界面 → 打开其内置设置（左侧边栏齿轮/「模型」）→ 填入 DeepSeek 官方或 Agnes 的 API Key 保存即可。配一次，两个界面通用。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } label: {
        Text("② 配 LLM 提供商（用之前配一次）").font(.headline)
      }

      GroupBox {
        VStack(alignment: .leading, spacing: 8) {
          Text("顶部切到「Harness Web」界面 → 右上角手机图标 → 生成配对二维码，用手机 Paseo App 扫码即可远程连到本 APP 的内置服务。Paseo 界面里的 agent 对话在手机与电脑之间实时同步；退出 APP 后服务默认保持运行，手机可继续连接。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } label: {
        Text("③ 移动端直连（可选）").font(.headline)
      }

      HStack {
        Spacer()
        Button("开始使用") { onClose() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 560)
  }
}

// ---------------------------------------------------------------------------
// 主窗口
// ---------------------------------------------------------------------------
private struct ContentView: View {
  @ObservedObject private var appState = AppState.shared
  @ObservedObject private var daemon = DaemonManager.shared
  @StateObject private var paseoWeb = WebController()
  @StateObject private var harnessWeb = WebController()
  /// Harness Web 的 WebView 一旦创建就常驻（隐藏而非销毁），切换界面不丢会话状态
  @State private var harnessWebCreated = false

  private var activeWeb: WebController {
    appState.viewMode == .harnessWeb ? harnessWeb : paseoWeb
  }

  var body: some View {
    Group {
      switch daemon.state {
      case .starting:
        VStack(spacing: 14) {
          Text("🐋").font(.system(size: 56))
          ProgressView()
          Text("正在启动内置 Paseo 服务…")
            .foregroundStyle(.secondary)
          Text("首次启动需初始化，约需十几秒。").font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .running(let url):
        ZStack {
          // Paseo 视图常驻：守护进程与移动端连接不受界面切换影响
          WebView(url: url, controller: paseoWeb)
            .opacity(appState.viewMode == .paseo ? 1 : 0)
            .allowsHitTesting(appState.viewMode == .paseo)

          if appState.viewMode == .harnessWeb {
            harnessWebContent
          }
        }
        .onAppear {
          if appState.viewMode == .harnessWeb, daemon.dshWebState != .running {
            daemon.startDshWeb()
          }
        }
        .onChange(of: appState.viewMode) { mode in
          if mode == .harnessWeb, daemon.dshWebState != .running {
            daemon.startDshWeb()
          }
        }
        .onChange(of: daemon.dshWebState) { state in
          if state == .running { harnessWebCreated = true }
        }
      case .failed(let message):
        VStack(alignment: .leading, spacing: 12) {
          Label("内置服务未能运行", systemImage: "exclamationmark.triangle.fill")
            .font(.title3.weight(.bold))
          Text(message).foregroundStyle(.secondary)
          if !daemon.logTail.isEmpty {
            ScrollView {
              Text(daemon.logTail)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
          }
          HStack {
            Button("重试 / 重启服务") { daemon.restart() }.buttonStyle(.borderedProminent)
            Button("打开数据目录") { NSWorkspace.shared.open(appSupportDir) }
          }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .frame(minWidth: 960, idealWidth: 1100, maxWidth: .infinity,
           minHeight: 640, idealHeight: 760, maxHeight: .infinity)
    .toolbar {
      ToolbarItemGroup(placement: .principal) {
        Picker("界面", selection: $appState.viewMode) {
          Text(AppState.ViewMode.paseo.rawValue).tag(AppState.ViewMode.paseo)
          Text(AppState.ViewMode.harnessWeb.rawValue).tag(AppState.ViewMode.harnessWeb)
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
        .disabled(!isDaemonRunning)
      }
      ToolbarItemGroup {
        if appState.viewMode == .harnessWeb {
          Button { appState.showPairing = true } label: { Label("移动端直连", systemImage: "iphone") }
            .disabled(!isDaemonRunning)
        }
        Button { activeWeb.reload() } label: { Label("重载", systemImage: "arrow.clockwise") }
          .keyboardShortcut("r", modifiers: .command)
          .disabled(activeWeb.webView == nil)
        Button { activeWeb.openInBrowser() } label: { Label("在浏览器打开", systemImage: "safari") }
          .disabled(activeWeb.webView == nil)
      }
    }
    .sheet(isPresented: $appState.showPairing) {
      PairingSheet { appState.showPairing = false }
    }
    .sheet(isPresented: $appState.showOnboarding) {
      OnboardingView {
        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
        appState.showOnboarding = false
      }
    }
    .onAppear {
      daemon.start()
      if !UserDefaults.standard.bool(forKey: "hasSeenOnboarding") {
        appState.showOnboarding = true
      }
    }
  }

  /// Harness Web 视图内容（dsh web）。WebView 常驻，仅首次进入时拉起服务。
  @ViewBuilder
  private var harnessWebContent: some View {
    switch daemon.dshWebState {
    case .running where harnessWebCreated:
      WebView(url: daemon.dshWebURL, controller: harnessWeb)
    case .failed(let message):
      VStack(spacing: 12) {
        Label("Harness Web 未能运行", systemImage: "exclamationmark.triangle.fill")
          .font(.title3.weight(.bold))
        Text(message).foregroundStyle(.secondary)
        Button("重试") { daemon.startDshWeb() }.buttonStyle(.borderedProminent)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
    default:
      VStack(spacing: 14) {
        ProgressView()
        Text("正在启动 Harness Web…").foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
    }
  }

  /// 工具栏 disabled 绑定用
  private var isDaemonRunning: Bool {
    if case .running = daemon.state { return true }
    return false
  }
}

// ---------------------------------------------------------------------------
// App 入口
// ---------------------------------------------------------------------------
private final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationDidFinishLaunching(_ notification: Notification) {
    // 不依赖窗口 onAppear（窗口未激活/未显示时 onAppear 不会触发），
    // 守护进程启动必须确定性发生
    Task { @MainActor in DaemonManager.shared.start() }
  }
  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated {
      // dsh web 是 APP 直接拉起的子进程，退出时必停（移动端不走它，无需保留）
      DaemonManager.shared.stopDshWeb()
    }
    // 默认保持内置 Paseo 服务运行（移动端可继续连接）；用户勾选「退出时停止服务」才停
    if UserDefaults.standard.bool(forKey: "stopDaemonOnQuit") {
      DaemonManager.shared.stopImmediate()
    }
  }
}

@main
private struct DSHDesktopApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    WindowGroup("DeepSeek Harness Desktop") {
      ContentView()
    }
  }
}
