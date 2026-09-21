import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // 창을 닫아도 앱은 산다 — 훅 서버·할 일 시계가 이 프로세스에 있다. 대시보드 모양에서는 창을 별도 앱
  // (Contents/Helpers/MadangDashboard.app)이 띄우고, 이 프로세스는 독에서 빠져 서버·시계만 돈다. 그 앱의 ⌘Q가 이쪽도 끈다.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.muwidarani.madang.dashboard").first {
        app.activate(options: [.activateIgnoringOtherApps])
      } else {
        for window in sender.windows {
          window.makeKeyAndOrderFront(self)
        }
        sender.activate(ignoringOtherApps: true)
      }
    }
    return true
  }

  /// 독·⌘Tab으로 앞에 오면 창 앱에 넘긴다 — 사람 눈에는 Madang 하나다.
  override func applicationDidBecomeActive(_ notification: Notification) {
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.muwidarani.madang.dashboard").first {
      app.activate(options: [.activateIgnoringOtherApps])
    }
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// 답 완료 알림 — [MainFlutterWindow]가 채널을 만들며 넣어 준다. 델리게이트는 앱이 사는 동안 하나여야 해서 여기 둔다.
  static var notifyBridge: FlutterMethodChannel?
  static let notifier = Notifier()

  // ⚠️ 2026-09-16~17에 여기 있던 「첫 응답자 되돌리기·재세움·한/영 보정·입력기 갈아 끼우기·키 진단」은 전부 지웠다(1.89.0).
  // 그 코드들은 Flutter 창 안에 WKWebView를 얹었을 때 한글이 자모로 갈라지던 것을 잡으려던 시도였는데, 원인은 같은 프로세스의
  // Flutter 엔진이었고(맨 WKWebView 앱은 정상) 대시보드를 별도 프로세스로 빼자 사라졌다. 되살리지 않는다 — 되살릴 일이 생기면
  // 그건 다시 같은 프로세스에 웹뷰를 넣었다는 뜻이다.
}
