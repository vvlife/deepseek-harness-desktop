// DeepSeek Harness Desktop Installer — 原生 SwiftUI 图形安装器。
//
// 本质是把仓库里的 install.sh（curl|sh 同款逻辑）包进一个 Mac 窗口：
// 选 provider（DeepSeek 官方 / Agnes / 自定义 OpenAI 兼容）→ 填/留空 API Key →
// 跑 Contents/Resources/installer/install.sh 并实时显示日志 → 完成后一键打开 Paseo。
//
// 构建：app/make-app.sh（swiftc 直编，无 Xcode 工程；arm64+x86_64 universal）。
import SwiftUI

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

@MainActor
private final class InstallRunner: ObservableObject {
  @Published var log = ""
  @Published var running = false
  @Published var exitCode: Int32? = nil

  func run(provider: ProviderChoice, key: String, baseURL: String, model: String) {
    guard !running else { return }
    guard let script = Bundle.main.resourceURL?
      .appendingPathComponent("installer/install.sh").path
    else {
      log = "✘ 找不到内置 install.sh（应用包损坏？）"
      exitCode = 1
      return
    }

    var args = [script, "--yes", "--provider", provider.flag]
    if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      args.append("--skip-auth")
    } else {
      args += ["--key", key.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
    if provider == .custom {
      args += ["--base-url", baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
               "--model", model.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    env["HOME"] = NSHomeDirectory()
    env["CI"] = "1" // 禁止 install.sh 末尾自动 open Paseo（由界面按钮接管）

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = args
    task.environment = env
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe

    running = true
    exitCode = nil
    log = ""

    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
      DispatchQueue.main.async { self.log += text }
    }
    task.terminationHandler = { t in
      DispatchQueue.main.async {
        pipe.fileHandleForReading.readabilityHandler = nil
        self.running = false
        self.exitCode = t.terminationStatus
      }
    }
    do {
      try task.run()
    } catch {
      running = false
      exitCode = 1
      log = "✘ 无法启动安装进程：\(error.localizedDescription)"
    }
  }
}

private struct InstallerView: View {
  @State private var provider: ProviderChoice = .deepseek
  @State private var key = ""
  @State private var baseURL = ""
  @State private var model = ""
  @StateObject private var runner = InstallRunner()

  private var customValid: Bool {
    provider != .custom ||
      (baseURL.hasPrefix("http://") || baseURL.hasPrefix("https://")) && !model.isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      // 标题
      HStack(spacing: 10) {
        Text("🐋").font(.system(size: 34))
        VStack(alignment: .leading, spacing: 2) {
          Text("DeepSeek Harness Desktop").font(.title2.weight(.bold))
          Text("一键安装 dsh + Paseo + ACP 桥").font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }

      // provider 选择
      Picker("LLM 提供商", selection: $provider) {
        ForEach(ProviderChoice.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .disabled(runner.running)

      if provider == .custom {
        TextField("baseURL（如 https://api.example.com/v1）", text: $baseURL)
          .textFieldStyle(.roundedBorder)
          .disabled(runner.running)
        TextField("模型 id（如 gpt-4o-mini）", text: $model)
          .textFieldStyle(.roundedBorder)
          .disabled(runner.running)
      }

      // API Key
      HStack(spacing: 8) {
        SecureField(provider.keyPlaceholder, text: $key)
          .textFieldStyle(.roundedBorder)
          .disabled(runner.running)
        if let url = provider.keyPage {
          Button("获取 Key") { NSWorkspace.shared.open(url) }
            .disabled(runner.running)
        }
      }
      Text(key.isEmpty
        ? "留空则跳过凭据配置（之后可在 dsh web 的模型设置页补填）。"
        : "Key 只写入本机 ~/.dsh/.credentials.yaml（权限 0600），不会外传。")
        .font(.caption)
        .foregroundStyle(.secondary)

      // 安装按钮
      HStack {
        Button(action: {
          runner.run(provider: provider, key: key, baseURL: baseURL, model: model)
        }) {
          Label(runner.running ? "安装中…" : "开始安装",
                systemImage: runner.running ? "hourglass" : "arrow.down.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(runner.running || !customValid)
        .keyboardShortcut(.defaultAction)

        if runner.running { ProgressView().scaleEffect(0.8) }

        if let code = runner.exitCode {
          Text(code == 0 ? "✔ 安装完成" : "✘ 失败（退出码 \(code)）")
            .foregroundStyle(code == 0 ? .green : .red)
            .font(.body.weight(.bold))
        }
      }

      // 日志
      ScrollViewReader { proxy in
        ScrollView {
          Text(runner.log.isEmpty ? "安装日志会显示在这里。\n需要 macOS 12+；若未装 Node/Homebrew，请先安装其中之一。" : runner.log)
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(8)
            .id("logTail")
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onChange(of: runner.log) { _ in
          withAnimation { proxy.scrollTo("logTail", anchor: .bottom) }
        }
      }

      // 完成动作
      if runner.exitCode == 0 {
        HStack(spacing: 12) {
          Button("打开 Paseo") {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Paseo.app"))
          }
          .buttonStyle(.borderedProminent)
          Text("在 Paseo 里新建 agent，选择 “DeepSeek Harness” 即可。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(18)
    .frame(width: 640, height: 600)
  }
}

@main
private struct DSHDInstallerApp: App {
  var body: some Scene {
    WindowGroup {
      InstallerView()
    }
  }
}
