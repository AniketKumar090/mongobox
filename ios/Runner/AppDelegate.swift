import Flutter
import UIKit
import Darwin

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let voiceBackendChannelName = "com.example.mongobox/voice_backend_launcher"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let didFinish = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: voiceBackendChannelName,
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        guard call.method == "startVoiceBackend" else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.handleVoiceBackendStart(call: call, result: result)
      }
    }

    return didFinish
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  private func handleVoiceBackendStart(call: FlutterMethodCall, result: @escaping FlutterResult) {
#if targetEnvironment(simulator)
    guard
      let args = call.arguments as? [String: Any],
      let host = args["host"] as? String,
      let port = args["port"] as? Int
    else {
      result(
        FlutterError(
          code: "invalid_args",
          message: "Missing voice backend launch arguments.",
          details: nil
        )
      )
      return
    }

    guard let scriptPath = findVoiceBackendStartScript() else {
      result(
        FlutterError(
          code: "script_missing",
          message: "Could not find voice-backend/start.py on the host machine.",
          details: nil
        )
      )
      return
    }

    result(spawnVoiceBackend(scriptPath: scriptPath, host: host, port: port))
#else
    result(
      FlutterError(
        code: "unsupported",
        message: "Host-side backend auto-start is only available in the iOS simulator.",
        details: nil
      )
    )
#endif
  }

  private func findVoiceBackendStartScript() -> String? {
    let environment = ProcessInfo.processInfo.environment
    var candidates = [
      environment["FLUTTER_APPLICATION_PATH"],
      environment["PWD"],
    ].compactMap { $0 }

    if let hostHome = currentUserHomeDirectory() {
      candidates.append(contentsOf: [
        "\(hostHome)/Documents/GitHub/mongobox",
        "\(hostHome)/Developer/mongobox",
        "\(hostHome)/Projects/mongobox",
        "\(hostHome)/Code/mongobox",
      ])
    }

    for base in candidates {
      let standardizedBase = URL(fileURLWithPath: base).standardizedFileURL.path
      let direct = "\(standardizedBase)/voice-backend/start.py"
      if FileManager.default.fileExists(atPath: direct) {
        return direct
      }
      if standardizedBase.hasSuffix("/voice-backend"),
         FileManager.default.fileExists(atPath: "\(standardizedBase)/start.py") {
        return "\(standardizedBase)/start.py"
      }
    }

    return nil
  }

  private func currentUserHomeDirectory() -> String? {
    let environmentHome = (ProcessInfo.processInfo.environment["HOME"] ?? "").trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    if environmentHome.hasPrefix("/Users/") {
      return environmentHome
    }

    guard let passwordEntry = getpwuid(getuid()), let directory = passwordEntry.pointee.pw_dir else {
      return nil
    }
    return String(cString: directory)
  }

  private func spawnVoiceBackend(scriptPath: String, host: String, port: Int) -> Bool {
    let scriptDir = URL(fileURLWithPath: scriptPath).deletingLastPathComponent().path
    let venvPython3 = "\(scriptDir)/.venv/bin/python3"
    let venvPython = "\(scriptDir)/.venv/bin/python"
    let pythonExecutable: String

    if FileManager.default.fileExists(atPath: venvPython3) {
      pythonExecutable = venvPython3
    } else if FileManager.default.fileExists(atPath: venvPython) {
      pythonExecutable = venvPython
    } else {
      pythonExecutable = "/usr/bin/python3"
    }

    let logPath = "\(NSTemporaryDirectory())mongobox_voice_backend.log"
    let escapedDir = shellEscape(scriptDir)
    let escapedPython = shellEscape(pythonExecutable)
    let escapedScript = shellEscape(scriptPath)
    let escapedHost = shellEscape(host)
    let escapedLog = shellEscape(logPath)
    let command =
      "cd \(escapedDir) && MONGOBOX_AUTO_BOOT=1 \(escapedPython) \(escapedScript) --host \(escapedHost) --port \(port) > \(escapedLog) 2>&1 &"

    let shell = "/bin/zsh"
    var pid = pid_t()
    var argv = [
      strdup(shell),
      strdup("-lc"),
      strdup(command),
      nil,
    ]
    defer {
      for case let pointer? in argv {
        free(pointer)
      }
    }

    let status = argv.withUnsafeMutableBufferPointer { buffer -> Int32 in
      posix_spawn(&pid, shell, nil, nil, buffer.baseAddress, nil)
    }
    if status != 0 {
      NSLog("Voice backend auto-start failed with status %d", status)
      return false
    }

    NSLog("Voice backend auto-start requested from simulator. pid=%d cwd=%@", pid, scriptDir)
    return true
  }

  private func shellEscape(_ value: String) -> String {
    if value.isEmpty {
      return "''"
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
