import Cocoa
import FlutterMacOS
import UserNotifications

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // 창을 투명하게 만든다.
    //
    // Dart에서 backgroundColor를 transparent로 줘도 검은 판이 남는다.
    // NSWindow가 기본적으로 불투명하고 그 위의 FlutterViewController도
    // 자기 배경을 칠하기 때문이다. 둘 다 여기서 꺼야 바탕화면이 비친다.
    self.isOpaque = false
    self.backgroundColor = .clear
    self.hasShadow = false
    flutterViewController.backgroundColor = .clear

    RegisterGeneratedPlugins(registry: flutterViewController)

    // ── 대시보드 창은 별도 앱이 띄운다 (1.88.2) ──
    // 같은 프로세스에 Flutter 엔진이 있으면 WKWebView에서 애플 한글 입력기가 조합을 안 걸어 자모가 갈라졌다(2026-09-17 실측 —
    // 맨 WKWebView 앱은 정상, Flutter 뷰를 떼어내면 엔진이 죽는다). Dart가 서버를 띄운 뒤 'open'으로 부르면
    // Contents/Helpers/MadangDashboard.app을 실행하고 이 프로세스는 독에서 빠진다(서버·시계·훅만). 그 앱이 꺼지면 같이 꺼진다.
    let dashChannel = FlutterMethodChannel(name: "cw/dash", binaryMessenger: flutterViewController.engine.binaryMessenger)
    dashChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "open":
        guard let a = call.arguments as? [String: Any], let urlText = a["url"] as? String else {
          result(FlutterError(code: "arg", message: "url이 없다", details: nil)); return
        }
        for w in NSApplication.shared.windows where w is MainFlutterWindow { w.orderOut(nil) }
        // 독 아이콘은 이 앱(Madang)이 맡는다 — 창 앱은 LSUIElement라 아이콘이 없다. 독·⌘Tab으로 이 앱이 앞에 오면 창 앱을 앞으로 부른다(9/17 한 앱으로 보이게).
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MadangDashboard.app")
        var args = [urlText]
        if let f = a["frame"] as? [Double], f.count == 4 { args += f.map { String($0) } } else { args += ["-", "-", "-", "-"] }
        args.append((a["title"] as? String) ?? "Madang")
        let conf = NSWorkspace.OpenConfiguration()
        conf.arguments = args
        conf.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: helper, configuration: conf) { app, err in
          if let err = err { NSLog("Madang: 대시보드 앱을 못 띄웠다 — \(err)"); return }
          guard let pid = app?.processIdentifier else { return }
          // 내가 띄운 그 창이 꺼질 때만 같이 꺼진다 — 남아 있던 옛 창을 닫았다고 서버가 내려가면 안 된다(9/17).
          DispatchQueue.main.async {
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
              guard let gone = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
              if gone.processIdentifier == pid { NSApp.terminate(nil) }
            }
          }
        }
        result(true)
      case "show":
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.muwidarani.madang.dashboard").first {
          app.activate(options: [.activateIgnoringOtherApps])
        }
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // ── 답 완료 알림 (cw/notify) ── 앱이 직접 보낸다 — 「스크립트 편집기」가 아니라 Madang 이름·아이콘으로 뜨고, 누르면 그 대화가 열린다.
    let notifyChannel = FlutterMethodChannel(name: "cw/notify", binaryMessenger: flutterViewController.engine.binaryMessenger)
    AppDelegate.notifyBridge = notifyChannel
    let center = UNUserNotificationCenter.current()
    center.delegate = AppDelegate.notifier
    notifyChannel.setMethodCallHandler { call, result in
      guard call.method == "post", let a = call.arguments as? [String: Any] else { result(FlutterMethodNotImplemented); return }
      center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        guard granted else { result(false); return }
        let c = UNMutableNotificationContent()
        c.title = (a["title"] as? String) ?? "Madang"
        c.body = (a["body"] as? String) ?? ""
        c.sound = .default
        if let p = a["path"] as? String { c.userInfo = ["path": p] }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { err in
          result(err == nil)
        }
      }
    }

    super.awakeFromNib()
  }
}

/// 알림 클릭 — 대시보드 앱(별도 프로세스)을 앞으로 부르고, 어느 세션인지 Dart에 알린다(페이지가 그 대화를 연다).
class Notifier: NSObject, UNUserNotificationCenterDelegate {
  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    if #available(macOS 11.0, *) { completionHandler([.banner, .sound]) } else { completionHandler([.alert, .sound]) }
  }
  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    let path = response.notification.request.content.userInfo["path"] as? String ?? ""
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.muwidarani.madang.dashboard").first {
      app.activate(options: [.activateIgnoringOtherApps])
    } else {
      for w in NSApplication.shared.windows { w.makeKeyAndOrderFront(nil) }
      NSApp.activate(ignoringOtherApps: true)
    }
    AppDelegate.notifyBridge?.invokeMethod("clicked", arguments: ["path": path])
    completionHandler()
  }
}
