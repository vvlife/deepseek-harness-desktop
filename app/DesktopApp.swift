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
  @Published var showSettings = false
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
        try await runCLI(["daemon", "start"], step: "启动内置服务")
        trail("daemon start ✔，等待 Web UI")
        if await pollWebReady(seconds: 120) {
          trail("Web UI 就绪")
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
// 设置页（provider / 凭据 / 移动端配对 / 遥测）
// ---------------------------------------------------------------------------
private enum ProviderChoice: String, CaseIterable, Identifiable {
  case deepseek = "DeepSeek 官方"
  case agnes = "Agnes AI"
  case custom = "自定义端点"
  var id: String { rawValue }
  var flag: String {
    switch self {
    case .deepseek: return "deepseek"
    case .agnes: return "agnes"
    case .custom: return "custom"
    }
  }
  var keyPage: URL? {
    switch self {
    case .deepseek: return URL(string: "https://platform.deepseek.com/api_keys")
    case .agnes: return URL(string: "https://platform.agnes-ai.com")
    case .custom: return nil
    }
  }
  var keyPlaceholder: String {
    switch self {
    case .deepseek: return "sk-...（DeepSeek API Key）"
    case .agnes: return "sk-...（Agnes API Key）"
    case .custom: return "sk-...（该端点的 API Key）"
    }
  }
}

private struct SettingsView: View {
  @State private var provider: ProviderChoice = .deepseek
  @State private var key = ""
  @State private var baseURL = ""
  @State private var model = ""
  @State private var telemetry = UserDefaults.standard.bool(forKey: "telemetryEnabled")
  @State private var stopOnQuit = UserDefaults.standard.bool(forKey: "stopDaemonOnQuit")
  @State private var busy = false
  @State private var status = ""
  @State private var pairBusy = false
  @State private var pairError = ""
  @ObservedObject private var daemon = DaemonManager.shared

  private var customValid: Bool {
    provider != .custom ||
      ((baseURL.hasPrefix("http://") || baseURL.hasPrefix("https://")) && !model.isEmpty)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text("LLM 提供商").font(.headline)
        Picker("LLM 提供商", selection: $provider) {
          ForEach(ProviderChoice.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        if provider == .custom {
          TextField("baseURL（如 https://api.example.com/v1）", text: $baseURL)
            .textFieldStyle(.roundedBorder)
          TextField("模型 id（如 gpt-4o-mini）", text: $model)
            .textFieldStyle(.roundedBorder)
        }

        HStack(spacing: 8) {
          SecureField(provider.keyPlaceholder, text: $key)
            .textFieldStyle(.roundedBorder)
          if let url = provider.keyPage {
            Button("获取 Key") { NSWorkspace.shared.open(url) }
          }
        }
        Text(key.isEmpty
          ? "Key 留空则只保存 provider 选择，不改动已有凭据。"
          : "Key 只写入本机 APP 私有的 .credentials.yaml（权限 0600），不会外传。")
          .font(.caption)
          .foregroundStyle(.secondary)

        HStack(spacing: 10) {
          Button(action: saveProvider) {
            Label(busy ? "保存中…" : "保存并重启服务", systemImage: "checkmark.circle")
          }
          .buttonStyle(.borderedProminent)
          .disabled(busy || pairBusy || !customValid)
          .keyboardShortcut(.defaultAction)
          if busy { ProgressView().scaleEffect(0.8) }
        }

        Divider()
        Text("移动端直连（Paseo App 配对）").font(.headline)
        Text("生成配对链接/二维码，用手机 Paseo App 扫码即可连到本 APP 的内置服务（经官方 relay）。退出本 APP 后服务默认保持运行，移动端可继续连接。")
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack(spacing: 10) {
          Button(action: generatePairing) {
            Label(pairBusy ? "生成中…" : "生成配对二维码", systemImage: "qrcode")
          }
          .disabled(busy || pairBusy)
          if pairBusy { ProgressView().scaleEffect(0.8) }
        }
        if let link = daemon.pairingLink {
          HStack(alignment: .top, spacing: 14) {
            if let qr = Self.qrImage(from: link) {
              Image(nsImage: qr)
                .resizable()
                .interpolation(.none)
                .frame(width: 132, height: 132)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 6) {
              Text(link).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(4)
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

        Divider()
        Toggle("允许 dsh 匿名遥测（默认关闭）", isOn: $telemetry)
          .font(.caption)
          .onChange(of: telemetry) { v in
            UserDefaults.standard.set(v, forKey: "telemetryEnabled")
            try? daemon.prepareBridge()
          }
        Toggle("退出 APP 时停止内置服务（默认保持运行，供移动端连接）", isOn: $stopOnQuit)
          .font(.caption)
          .onChange(of: stopOnQuit) { v in
            UserDefaults.standard.set(v, forKey: "stopDaemonOnQuit")
          }
        HStack {
          Button("打开数据目录") { NSWorkspace.shared.open(appSupportDir) }
          Spacer()
          Button("重启服务") { daemon.restart() }
        }
        .font(.callout)

        if !status.isEmpty {
          Divider()
          ScrollView {
            Text(status)
              .font(.system(.caption, design: .monospaced))
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
          }
          .frame(maxHeight: 160)
          .background(Color(nsColor: .textBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }
      }
      .padding(20)
    }
    .frame(width: 640, height: 640)
  }

  private func providerArgs() -> [String] {
    var args = ["--provider", provider.flag, "--yes"]
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      args.append("--skip-auth")
    } else {
      args += ["--key", trimmed]
    }
    if provider == .custom {
      args += ["--base-url", baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
               "--model", model.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
    args += ["--bridge-command", daemon.bridgeWrapperPath]
    return args
  }

  private func saveProvider() {
    busy = true
    status = ""
    Task {
      do {
        let out = try await daemon.runSetupProvider(args: providerArgs(), step: "保存 provider")
        status = out
        daemon.restart()
      } catch {
        status = error.localizedDescription
      }
      busy = false
    }
  }

  private func generatePairing() {
    pairBusy = true
    pairError = ""
    Task {
      do {
        _ = try await daemon.generatePairingLink()
      } catch {
        pairError = error.localizedDescription
      }
      pairBusy = false
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
// 主窗口
// ---------------------------------------------------------------------------
private struct ContentView: View {
  @ObservedObject private var appState = AppState.shared
  @ObservedObject private var daemon = DaemonManager.shared
  @StateObject private var web = WebController()

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
        WebView(url: url, controller: web)
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
      ToolbarItemGroup {
        Button { web.reload() } label: { Label("重载", systemImage: "arrow.clockwise") }
          .keyboardShortcut("r", modifiers: .command)
          .disabled(web.webView == nil)
        Button { web.openInBrowser() } label: { Label("在浏览器打开", systemImage: "safari") }
          .disabled(web.webView == nil)
        Button { appState.showSettings = true } label: { Label("设置", systemImage: "gear") }
      }
    }
    .sheet(isPresented: $appState.showSettings) {
      SettingsView()
    }
    .onAppear { daemon.start() }
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
    // 默认保持内置服务运行（移动端可继续连接）；用户勾选「退出时停止服务」才停
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
    .commands {
      CommandGroup(replacing: .appSettings) {
        Button("设置…") { AppState.shared.showSettings = true }
          .keyboardShortcut(",", modifiers: .command)
      }
    }
  }
}
