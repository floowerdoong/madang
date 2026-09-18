import Cocoa
import WebKit

// ══════════════════════════════════════════════════════════════════════════════════════════════
// Madang 대시보드 창 — Flutter 없는 별도 프로세스 (1.88.2, 2026-09-17)
//
// 왜 따로 있나: 같은 프로세스에 Flutter 엔진이 떠 있으면 WKWebView에서 애플 한글 입력기가 조합을 안 걸어 자모가 낱자로
// 갈라졌다(대표 실측 9/17 — 맨 WKWebView 앱은 멀쩡, 네이티브 창을 Flutter 프로세스 안에 띄워도 갈라짐. Flutter 뷰를
// 떼어내면 엔진이 SIGSEGV). 그래서 창은 이 작은 앱이 띄우고, 서버·시계·훅은 Madang(Flutter) 프로세스가 돈다.
//
// 인자: MadangDashboard <url> [x y w h]   — 자리는 Dart가 launch_mode.json에서 읽어 넘기고, 바뀌면 여기서 서버에 POST한다.
// 이 창의 ⌘Q는 Madang 본 프로세스도 같이 끈다(본 프로세스가 이 앱의 종료를 지켜본다).
// ══════════════════════════════════════════════════════════════════════════════════════════════

/// 파일 끌어놓기를 페이지의 `cwDropPaths`로 넘기는 웹뷰 — 경로를 아는 것이 앱 창의 값어치다(브라우저는 복사본을 올린다).
class DashWebView: WKWebView {
  var hoverAt = Date.distantPast

  override init(frame: CGRect, configuration: WKWebViewConfiguration) {
    super.init(frame: frame, configuration: configuration)
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  private func point(_ sender: NSDraggingInfo) -> (Int, Int) {
    let p = convert(sender.draggingLocation, from: nil)
    return (Int(p.x.rounded()), Int((isFlipped ? p.y : bounds.height - p.y).rounded()))
  }

  // ⚠️ 페이지 안에서 끄는 것(카드 → 서랍)은 WebKit이 처리해야 한다 — 가로채면 보드·리스트의 끌어놓기가 통째로 죽는다
  // (대표 제보 9/17 「백로그 서랍으로 못 옮긴다」). 밖(파인더)에서 온 파일 끌기만 우리가 받는다.
  private func isExternalFiles(_ sender: NSDraggingInfo) -> Bool {
    sender.draggingSource == nil && sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard isExternalFiles(sender) else { return super.draggingEntered(sender) }
    evaluateJavaScript("cwDropHint(true)")
    return .copy
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard isExternalFiles(sender) else { return super.draggingUpdated(sender) }
    let now = Date()
    if now.timeIntervalSince(hoverAt) > 0.09 {
      hoverAt = now
      let (x, y) = point(sender)
      evaluateJavaScript("cwDropHover(\(x), \(y))")
    }
    return .copy
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    if let s = sender, !isExternalFiles(s) { super.draggingExited(sender); return }
    evaluateJavaScript("cwDropHint(false)")
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    isExternalFiles(sender) ? true : super.prepareForDragOperation(sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard isExternalFiles(sender) else { return super.performDragOperation(sender) }
    evaluateJavaScript("cwDropHint(false)")
    let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    guard !urls.isEmpty else { return false }
    let paths = urls.map { $0.path }
    guard let data = try? JSONSerialization.data(withJSONObject: paths), let json = String(data: data, encoding: .utf8) else { return false }
    let (x, y) = point(sender)
    evaluateJavaScript("cwDropPaths(\(json), \(x), \(y))")
    return true
  }
}

class Dash: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSWindowDelegate {
  var window: NSWindow!
  var web: DashWebView!
  var home: URL!
  var port = 9876
  var intended = NSRect.zero
  let openedAt = Date()
  var saveTimer: Timer?
  var retryTimer: Timer?

  /// 진단 로그는 두지 않는다 — 키 입력이 남는 파일이라 1.89.1에서 뺐다. 필요하면 사파리 개발자 도구(isInspectable)로 본다.
  func log(_ s: String) {}


  func applicationDidFinishLaunching(_ n: Notification) {
    let args = CommandLine.arguments
    guard args.count >= 2, let url = URL(string: args[1]) else {
      NSLog("MadangDashboard: url 인자가 없다")
      NSApp.terminate(nil)
      return
    }
    home = url
    port = url.port ?? 9876
    // 본체(Madang)가 꺼지면 창도 닫는다 — 서버 없는 창이 혼자 남지 않게(9/17).
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
      guard let gone = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
      if gone.bundleIdentifier == "com.muwidarani.madang" { NSApp.terminate(nil) }
    }
    var frame: NSRect
    if args.count >= 6, let x = Double(args[2]), let y = Double(args[3]), let w = Double(args[4]), let h = Double(args[5]) {
      // Dart는 왼쪽 위 원점 — AppKit은 왼쪽 아래 원점.
      let screenH = NSScreen.screens.first?.frame.height ?? 0
      frame = NSRect(x: x, y: screenH - y - h, width: w, height: h)
    } else {
      let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
      let w = min(1440, vis.width * 0.8), h = min(900, vis.height * 0.85)
      frame = NSRect(x: vis.midX - w / 2, y: vis.midY - h / 2, width: w, height: h)
    }
    intended = frame

    let cfg = WKWebViewConfiguration()
    let ucc = WKUserContentController()
    // 페이지는 webview_flutter가 넣어 주던 `cwFocus.postMessage(...)` 모양으로 부른다 — 같은 이름을 만들어 준다.
    let shim = ["cwFocus", "cwDbg", "cwBg"].map {
      "window.\($0) = {postMessage: function(m){ try{ window.webkit.messageHandlers.\($0).postMessage(String(m)); }catch(e){} }};"
    }.joined(separator: "\n")
    ucc.addUserScript(WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    for name in ["cwFocus", "cwDbg", "cwBg"] { ucc.add(self, name: name) }
    cfg.userContentController = ucc
    web = DashWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: cfg)
    web.navigationDelegate = self
    web.uiDelegate = self
    web.autoresizingMask = [.width, .height]
    if #available(macOS 13.3, *) { web.isInspectable = true }

    window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = args.count >= 7 ? args[6] : "Madang"
    window.minSize = NSSize(width: 720, height: 520)
    window.contentView = web
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.backgroundColor = .white
    window.setFrame(frame, display: true)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    web.load(URLRequest(url: url))
    log("창 떴다 \(url) frame=\(frame)")
  }

  // 창을 닫아도 앱은 산다(숨김) — 독 아이콘으로 다시 띄운다. 끄는 것은 ⌘Q(본 프로세스도 같이 꺼진다).
  func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    return true
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    window.orderOut(nil)
    return false
  }

  func windowDidMove(_ notification: Notification) { rememberFrame() }
  func windowDidResize(_ notification: Notification) {
    rememberFrame()
    tellScreen()
  }

  /// 자리·크기를 서버(launch_mode.json)에 적는다 — 0.6초 몰아서. 켠 뒤 10초 안의 키움(창 정리 앱)은 적지 않고 되돌린다.
  func rememberFrame() {
    saveTimer?.invalidate()
    saveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
      guard let self = self, self.window.isVisible, !self.window.isMiniaturized else { return }
      let f = self.window.frame
      if Date().timeIntervalSince(self.openedAt) < 10 {
        if abs(f.width - self.intended.width) > 2 || abs(f.height - self.intended.height) > 2 {
          self.window.setFrame(self.intended, display: true)
        }
        return
      }
      let screenH = NSScreen.screens.first?.frame.height ?? 0
      let body: [String: Double] = ["x": f.origin.x, "y": screenH - f.origin.y - f.height, "w": f.width, "h": f.height]
      guard let data = try? JSONSerialization.data(withJSONObject: body), var req = URLComponents(string: "http://127.0.0.1:\(self.port)/todo/app/frame")?.url.map({ URLRequest(url: $0) }) else { return }
      req.httpMethod = "POST"
      req.httpBody = data
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      URLSession.shared.dataTask(with: req).resume()
    }
  }

  func tellScreen() {
    let w = Double(window.screen?.frame.width ?? 0)
    if w > 0 { web.evaluateJavaScript("if(window.cwScreen) cwScreen(\(Int(w)))") }
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
    let inside = (url.host == "127.0.0.1" || url.host == "localhost") && (url.port ?? 80) == port && !url.path.hasSuffix(".csv")
    if url.scheme == "about" || inside {
      decisionHandler(.allow)
    } else {
      NSWorkspace.shared.open(url)   // 바깥 링크·CSV는 기본 브라우저로
      decisionHandler(.cancel)
    }
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
    return nil
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { tellScreen() }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { retry() }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { retry() }

  /// 서버가 아직 안 열렸으면 1초 뒤 다시 연다.
  func retry() {
    retryTimer?.invalidate()
    retryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
      guard let self = self else { return }
      self.web.load(URLRequest(url: self.home))
    }
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    let body = "\(message.body)"
    switch message.name {
    case "cwDbg":
      log("page \(body)")
    case "cwBg":
      let nums = body.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
      if nums.count >= 3 {
        let c = NSColor(red: CGFloat(nums[0]) / 255, green: CGFloat(nums[1]) / 255, blue: CGFloat(nums[2]) / 255, alpha: 1)
        window.backgroundColor = c
        if #available(macOS 12.0, *) { web.underPageBackgroundColor = c }
      }
    default:
      if body == "jamo" { log("페이지가 낱자를 봤다") }
    }
  }
}

let app = NSApplication.shared
let dash = Dash()
app.delegate = dash
app.setActivationPolicy(.accessory)  // 독 아이콘은 본체(Madang)가 맡는다 — 사람 눈에는 한 앱(9/17)

// 메뉴 막대 — ⌘A·⌘C·⌘V는 「편집」 메뉴의 단축키가 첫 응답자(웹뷰)에 selectAll:·copy:·paste:를 보내서 동작한다.
// 코드로 띄운 앱에는 메뉴가 없어 단축키가 전부 안 먹었다(대표 제보 9/17). target이 nil이면 응답자 체인을 탄다.
func menu(_ title: String, _ items: [(String, Selector, String, NSEvent.ModifierFlags)]) -> NSMenuItem {
  let m = NSMenu(title: title)
  for (t, sel, key, mods) in items {
    let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
    i.keyEquivalentModifierMask = mods
    m.addItem(i)
  }
  let top = NSMenuItem()
  top.submenu = m
  return top
}
let bar = NSMenu()
bar.addItem(menu("Madang", [
  ("Madang 가리기", #selector(NSApplication.hide(_:)), "h", .command),
  ("Madang 종료", #selector(NSApplication.terminate(_:)), "q", .command),
]))
bar.addItem(menu("편집", [
  ("실행 취소", Selector(("undo:")), "z", .command),
  ("실행 복귀", Selector(("redo:")), "z", [.command, .shift]),
  ("오려두기", #selector(NSText.cut(_:)), "x", .command),
  ("복사", #selector(NSText.copy(_:)), "c", .command),
  ("붙여넣기", #selector(NSText.paste(_:)), "v", .command),
  ("전체 선택", #selector(NSText.selectAll(_:)), "a", .command),
]))
bar.addItem(menu("윈도우", [
  ("최소화", #selector(NSWindow.performMiniaturize(_:)), "m", .command),
  ("닫기", #selector(NSWindow.performClose(_:)), "w", .command),
]))
app.mainMenu = bar

app.run()
