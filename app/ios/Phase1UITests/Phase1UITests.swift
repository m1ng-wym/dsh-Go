import XCTest

/// Process-level acceptance tests for Phase 1 v1.1 (T34b).
///
/// The bundle drives the real Runner app through `XCUIApplication(bundleIdentifier:)`;
/// it has no test host and does not build or install the app. The wrapper
/// `scripts/e2e/ios/run_ui_process.sh` builds and installs Runner.app, prepares the
/// photo library and the canonical mock model, and runs one test per app state.
final class Phase1UITests: XCTestCase {
  private static let appBundleIdentifier = "io.github.ccch1mneyyy.dshgo"
  private static let launchTimeout: TimeInterval = 90
  private static let firstScreenTimeout: TimeInterval = 90
  private static let engineTimeout: TimeInterval = 180
  private static let providerURL = "http://127.0.0.1:3901/v1"
  private static let providerKey = "sk-t34b-sentinel-0123456789abcdef"
  private static let providerModel = "mock-phase1-model"
  private static let mockReply = "mock 模型"
  private static let mockReplyEn = "mock model"

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  // MARK: - Launch smoke (kept from T34a)

  func testAppLaunches() throws {
    let app = application()
    app.launch()
    XCTAssertTrue(
      waitForFirstScreen(app),
      "The app did not show an accessible first screen within \(Self.firstScreenTimeout)s; state=\(app.state.rawValue)."
    )
    XCTAssertTrue(app.state == .runningForeground, "The app is not in the foreground; state=\(app.state.rawValue).")
    attachScreenshot("testAppLaunches-first-screen")
  }

  // MARK: - A2/B5 cold launch, engine auto-start, auto-start setting

  func testColdLaunchAutoStart() throws {
    let app = application()
    launch(app)
    XCTAssertTrue(waitForLabel(["Start", "开始"], app, 30), "Fresh install did not show the welcome screen.")
    completeOnboarding(app)
    XCTAssertTrue(waitForHome(app, 240), "First run never reached the home screen.")
    attachScreenshot("A2-first-home")

    // Cold relaunch: no onboarding, engine starts by itself.
    relaunch(app)
    XCTAssertTrue(waitForHome(app, 120), "Cold launch did not land on home.")
    XCTAssertFalse(hasLabel(["Start", "开始"], app), "Cold launch brought the welcome screen back.")
    XCTAssertTrue(waitForComposer(app, Self.engineTimeout), "The local engine never became ready after the cold launch.")
    XCTAssertTrue(openEnginePage(app), "Could not open the local engine page.")
    XCTAssertTrue(waitForEngineStatus("Running", "运行中", app, 60), "The engine is not running after the cold launch.")
    attachScreenshot("A2-cold-launch-engine-running")

    // Turn the launch auto-start off.
    let auto = autoStartSwitch(app)
    XCTAssertNotNil(auto, "The auto-start switch is missing on the engine page.")
    XCTAssertEqual(stringValue(auto), "1", "Auto-start is not on before the test turns it off.")
    auto!.tap()
    sleep(1)
    XCTAssertEqual(stringValue(autoStartSwitch(app)), "0", "Auto-start did not turn off.")
    attachScreenshot("A2-autostart-off")

    // Cold relaunch: the engine must stay stopped.
    relaunch(app)
    XCTAssertTrue(waitForHome(app, 120), "Cold launch did not land on home after turning auto-start off.")
    sway(6)
    XCTAssertTrue(openEnginePage(app), "Could not open the local engine page after the cold launch.")
    XCTAssertTrue(
      waitForEngineStatus("Stopped", "已停止", app, 45),
      "The engine did not stay stopped after launching with auto-start off."
    )
    XCTAssertFalse(hasEngineStatus("Running", "运行中", app), "The engine started although auto-start is off.")
    attachScreenshot("A2-cold-launch-engine-stopped")

    // Turn it back on and prove it starts again.
    let autoAgain = autoStartSwitch(app)
    XCTAssertNotNil(autoAgain, "The auto-start switch is missing after the cold launch.")
    autoAgain!.tap()
    sleep(1)
    XCTAssertEqual(stringValue(autoStartSwitch(app)), "1", "Auto-start did not turn back on.")
    relaunch(app)
    XCTAssertTrue(waitForHome(app, 120), "Cold launch did not land on home after turning auto-start back on.")
    XCTAssertTrue(waitForComposer(app, Self.engineTimeout), "The engine did not start after turning auto-start back on.")
    XCTAssertTrue(openEnginePage(app), "Could not open the local engine page after the final cold launch.")
    XCTAssertTrue(waitForEngineStatus("Running", "运行中", app, 60), "The engine is not running after auto-start was turned back on.")
    attachScreenshot("A2-autostart-back-on-engine-running")
  }

  // MARK: - B2 install resume

  func testInstallResume() throws {
    let app = application()
    launch(app)
    XCTAssertTrue(waitForLabel(["Start", "开始"], app, 30), "Fresh install did not show the welcome screen.")
    settle(2)
    XCTAssertTrue(tapStartStable(app), "The welcome screen did not advance after Start.")
    XCTAssertTrue(
      waitForAnyLabel(["Where should DSH run?", "DSH 在哪里运行？"], app, 30),
      "The runtime choice did not appear after Start."
    )
    dismissSystemAlerts(app)
    selectLocalRuntime(app)
    XCTAssertTrue(tapAny(["Continue", "继续"], app, 20), "The runtime choice did not offer Continue.")
    let percent = waitForInstallPercent(app, 20)
    XCTAssertNotNil(percent, "The install progress never appeared; the interruption test needs a running install.")
    XCTAssertLessThan(percent ?? 100, 100, "The install reached 100% before it could be interrupted.")
    attachScreenshot("B2-install-in-progress")
    print("[Phase1UITests] interrupted install at \(percent ?? -1)%")

    app.terminate()
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "The app did not terminate during the install.")
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: Self.launchTimeout), "The app did not come back after the interruption.")
    XCTAssertTrue(waitForFirstScreen(app), "No screen after relaunching into the interrupted install.")
    XCTAssertFalse(
      hasLabel(["Start", "开始"], app),
      "The relaunch fell back to the welcome screen; the install was not resumed."
    )
    XCTAssertTrue(
      waitForAnyLabelContaining(
        ["Installation incomplete", "Install failed", "安装未完成", "安装失败", "Retry", "重试",
         "Preparing runtime", "正在准备运行环境", "Choose a look", "选择外观"],
        app, 120
      ),
      "The relaunch did not show the interrupted install state."
    )
    attachScreenshot("B2-after-interruption")
    driveOnboardingToHome(app, 300)
    XCTAssertTrue(waitForHome(app, 30), "The resumed install never reached home.")
    XCTAssertTrue(waitForComposer(app, Self.engineTimeout), "The engine did not start after the resumed install.")
    XCTAssertTrue(openEnginePage(app), "Could not open the engine page after the resumed install.")
    XCTAssertTrue(waitForEngineStatus("Running", "运行中", app, 60), "The engine is not running after the resumed install.")
    attachScreenshot("B2-resume-complete")
  }

  // MARK: - B6 failure diagnostics

  func testFailureDiagnostics() throws {
    let app = application()
    launch(app, firstScreen: false)
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: Self.launchTimeout), "The app did not launch with the broken runtime.")
    sleep(12)
    XCTAssertEqual(app.state, .runningForeground, "The app left the foreground after the runtime failure; state=\(app.state.rawValue).")
    XCTAssertTrue(waitForHome(app, 60), "The app did not stay on the home screen after the runtime failure.")
    XCTAssertTrue(openEnginePage(app), "Could not open the engine page to read the failure.")
    XCTAssertTrue(
      waitForAnyLabelContaining(
        ["Couldn’t start", "启动失败", "DSH couldn’t start", "DSH 启动失败", "Engine error", "引擎出错",
         "The local engine exited", "本机引擎已退出", "Runtime not installed", "运行环境未安装",
         "Installation incomplete", "安装未完成", "引擎出错了"],
        app, 60
      ),
      "No readable failure text appeared on the engine page."
    )
    XCTAssertTrue(
      waitForAnyLabelContaining(["View logs", "查看日志", "Logs", "日志"], app, 20),
      "The failure offers no log entry."
    )
    XCTAssertTrue(
      waitForAnyLabelContaining(["Start again", "重新启动", "Retry", "重试", "Start", "启动"], app, 20),
      "The failure offers no retry action."
    )
    XCTAssertEqual(app.state, .runningForeground, "The app crashed after the runtime failure.")
    attachScreenshot("B6-readable-failure")
  }

  // MARK: - B7 logs page: no credentials, copy works

  func testLogsRedactionAndCopy() throws {
    let app = application()
    launch(app)
    XCTAssertTrue(waitForHome(app, 240), "Could not reach home for the logs check.")
    XCTAssertTrue(waitForComposer(app, Self.engineTimeout), "The engine did not become ready for the logs check.")
    XCTAssertTrue(openEnginePage(app), "Could not open the engine page for the logs check.")
    XCTAssertTrue(waitForEngineStatus("Running", "运行中", app, 60), "The engine is not running, so there are no logs.")
    XCTAssertTrue(scrollToButtonContaining(["Copy all", "复制全部"], app, 6), "The log copy control never became visible.")

    let text = visibleText(app)
    assertNoCredentials(text, "logs page")
    attachScreenshot("B7-logs-page")

    let copy = buttonContaining(["Copy all", "复制全部"], app)
    XCTAssertNotNil(copy, "The Copy all control is missing.")
    copy!.tap()
    settle(2)
    dismissSystemAlerts(app)
    attachScreenshot("B7-logs-copied")
    // The SnackBar confirmation and the system pasteboard are not reliably
    // readable from the UI-test process (the simulator shares its pasteboard
    // with the Mac and reading it can prompt). The tap above is the copy; the
    // wrapper verifies the clipboard content after the run.
    print("[Phase1UITests] tapped Copy all; the wrapper verifies simctl pbpaste")
  }

  // MARK: - D6/D8 Photos attachment

  func testPhotosAttachment() throws {
    let app = application()
    launch(app)
    XCTAssertTrue(waitForLabel(["Start", "开始"], app, 30), "Fresh install did not show the welcome screen.")
    completeOnboarding(app, configureProvider: true)
    XCTAssertTrue(waitForHome(app, 300), "Onboarding with a model provider did not reach home.")
    XCTAssertTrue(waitForComposer(app, Self.engineTimeout), "The engine did not become ready for the attachment test.")
    selectMockModelIfPossible(app)
    attachScreenshot("D6-home-before-attach")

    XCTAssertTrue(waitForHome(app, 30), "Home did not come back after the model sheet.")
    XCTAssertTrue(
      waitForAnyLabelContaining(["Mock Phase1", "mock-phase1"], app, 20),
      "The mock model was not selected in the chat header."
    )
    XCTAssertTrue(waitForComposer(app, Self.engineTimeout), "The engine is not ready for the attachment test.")
    XCTAssertTrue(
      waitForButtonContaining(["Add image or file", "添加图片或文件"], app, 30),
      "The attach button is missing."
    )
    sleep(2)
    XCTAssertTrue(tapAny(["Photos", "相册"], app, 15), "The Photos entry is missing from the attach panel.")
    sleep(6)
    attachScreenshot("D6-photos-picker")
    let picked = pickFirstPhoto(app)
    XCTAssertTrue(picked, "Could not select the first photo in the system picker.")
    sleep(4)
    XCTAssertTrue(
      waitForAnyLabelContaining(["Remove “", "Remove 「", "移除“", "移除「"], app, 20),
      "The picked photo did not appear in the attachment tray."
    )
    attachScreenshot("D6-attachment-tray")

    let composer = textFieldLabel(["Message DSH…", "给 DSH 发消息…"], app)
    XCTAssertNotNil(composer, "The composer field is missing.")
    composer!.tap()
    sleep(1)
    let message = "T34b photo attachment"
    app.typeText(message)
    sleep(1)
    XCTAssertTrue(tapAny(["Send", "发送"], app, 15), "The send button is missing.")
    XCTAssertTrue(waitForAnyLabelContaining([message], app, 20), "The sent message did not appear in the chat.")
    XCTAssertFalse(
      waitForAnyLabelContaining(["Remove “", "Remove 「", "移除“", "移除「"], app, 2),
      "The attachment stayed in the tray after sending."
    )
    XCTAssertTrue(
      waitForAnyLabelContaining([Self.mockReply, Self.mockReplyEn, "Phase 1"], app, 60),
      "The canonical mock model did not answer the message with the attachment."
    )
    attachScreenshot("D8-sent-with-attachment")
  }

  // MARK: - G1/G2 dark and English cold launches

  func testChineseBaseline() throws {
    let app = application()
    launch(app)
    XCTAssertTrue(waitForLabel(["开始"], app, 30), "The Chinese baseline did not show Chinese labels.")
    attachScreenshot("G2-chinese-baseline")
  }

  func testDarkColdLaunch() throws {
    let app = application()
    launch(app)
    let luminance = meanLuminance()
    print("[Phase1UITests] dark launch mean luminance=\(luminance)")
    XCTAssertLessThan(luminance, 0.35, "The cold launch is not in a dark theme (mean luminance \(luminance)).")
    attachScreenshot("G1-dark-cold-launch")
    relaunch(app)
    let second = meanLuminance()
    XCTAssertLessThan(second, 0.35, "The second dark cold launch is not dark (mean luminance \(second)).")
    attachScreenshot("G1-dark-cold-relaunch")
  }

  func testEnglishColdLaunch() throws {
    let app = application()
    launch(app)
    XCTAssertTrue(waitForLabel(["Start"], app, 30), "The English cold launch did not show the English welcome screen.")
    XCTAssertFalse(hasLabel(["开始"], app), "Chinese labels are still visible after switching the system language to English.")
    let text = visibleText(app)
    XCTAssertTrue(
      text.contains("DeepSeek agent") || text.contains("Start") || text.contains("Chats"),
      "No English welcome/chat label found after switching the system language."
    )
    attachScreenshot("G2-english-cold-launch")
  }

  func testSE3ColdLaunchDark() throws {
    let app = application()
    launch(app)
    XCTAssertLessThan(
      app.windows.firstMatch.frame.width,
      390,
      "This test is meant for the SE3 destination (a 375-point-wide screen)."
    )
    let luminance = meanLuminance()
    print("[Phase1UITests] SE3 dark launch mean luminance=\(luminance)")
    XCTAssertLessThan(luminance, 0.35, "The SE3 cold launch is not dark (mean luminance \(luminance)).")
    attachScreenshot("SE3-dark-cold-launch")
    relaunch(app)
    let second = meanLuminance()
    XCTAssertLessThan(second, 0.35, "The SE3 second dark cold launch is not dark (mean luminance \(second)).")
    attachScreenshot("SE3-dark-cold-relaunch")
  }

  // MARK: - Onboarding

  private func completeOnboarding(_ app: XCUIApplication, configureProvider: Bool = false) {
    settle(2)
    XCTAssertTrue(tapStartStable(app), "The welcome screen did not advance after Start.")
    XCTAssertTrue(
      waitForAnyLabel(["Where should DSH run?", "DSH 在哪里运行？"], app, 30),
      "The runtime choice did not appear after Start."
    )
    dismissSystemAlerts(app)
    selectLocalRuntime(app)
    XCTAssertTrue(tapAny(["Continue", "继续"], app, 20), "The runtime choice did not offer Continue.")
    settle(3)
    dismissSystemAlerts(app)
    if !waitForAnyLabel(["Choose a look", "选择外观"], app, 40) {
      _ = tapAny(["Continue", "继续"], app, 10)
      dismissSystemAlerts(app)
    }
    XCTAssertTrue(tapAny(["Continue", "继续"], app, 30), "The appearance step did not offer Continue.")
    settle(2)
    dismissSystemAlerts(app)
    XCTAssertTrue(
      waitForAnyLabel(["What should DSH Go help with?", "想让 DSH Go 帮你做哪些事"], app, 40),
      "The access step did not appear."
    )
    dismissSystemAlerts(app)
    XCTAssertTrue(tapAny(["Skip", "跳过"], app, 20), "The access step did not offer Skip.")
    settle(3)
    dismissSystemAlerts(app)
    XCTAssertTrue(
      waitForAnyLabel(["Connect DeepSeek", "连接 DeepSeek"], app, 40),
      "The connect step did not appear."
    )
    dismissSystemAlerts(app)
    if configureProvider {
      XCTAssertTrue(tapAny(["Other providers", "其他模型渠道"], app, 30), "The connect step did not offer other providers.")
      configureProviderForm(app)
    } else {
      XCTAssertTrue(tapAny(["Set up later", "稍后设置"], app, 30), "The connect step did not offer Set up later.")
    }
    driveOnboardingToHome(app, 300)
  }

  private func tapStartStable(_ app: XCUIApplication) -> Bool {
    for _ in 0..<4 {
      guard tapAny(["Start", "开始"], app, 5) else { continue }
      settle(3)
      if !hasLabel(["Start", "开始"], app) { return true }
      dismissSystemAlerts(app)
    }
    return false
  }

  private func settle(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
  }

  private func dismissSystemAlerts(_ app: XCUIApplication) {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    for candidate in [app, springboard] {
      let alerts = candidate.alerts
      guard alerts.count > 0 else { continue }
      let alert = alerts.element(boundBy: 0)
      for label in ["Allow", "允许", "OK", "好", "Don’t Allow", "不允许"] {
        let buttons = alert.buttons.matching(NSPredicate(format: "label == %@", label))
        if buttons.count > 0 {
          buttons.element(boundBy: 0).tap()
          settle(1)
          return
        }
      }
    }
  }

  private func selectLocalRuntime(_ app: XCUIApplication) {
    let local = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "This phone", "本机")
    )
    if local.count > 0 {
      let card = local.element(boundBy: 0)
      if card.isEnabled && !isSelected(card) {
        card.tap()
        sleep(1)
      }
    }
  }

  private func isSelected(_ element: XCUIElement) -> Bool {
    let value = String(describing: element.value).lowercased()
    return value.contains("selected") || value == "1"
  }

  /// Taps whatever first-run step is on screen until home is showing.
  private func driveOnboardingToHome(_ app: XCUIApplication, _ timeout: TimeInterval) {
    let deadline = Date().addingTimeInterval(timeout)
    var steps = 0
    while Date() < deadline && steps < 60 {
      if isHome(app) { return }
      dismissSystemAlerts(app)
      if tapAny(["Start", "开始"], app, 1) { steps += 1; sleep(2); continue }
      if tapAny(["Continue", "继续"], app, 1) { steps += 1; sleep(2); continue }
      if tapAny(["Skip", "跳过"], app, 1) { steps += 1; sleep(2); continue }
      if tapAny(["Set up later", "稍后设置"], app, 1) { steps += 1; sleep(2); continue }
      if tapAny(["Retry", "重试"], app, 1) { steps += 1; sleep(3); continue }
      sleep(1)
    }
  }

  private func configureProviderForm(_ app: XCUIApplication) {
    XCTAssertTrue(waitForLabel(["Add provider", "添加渠道"], app, 30), "The provider form did not open.")
    sleep(1)
    fillTextField(["https://api.example.com/v1"], text: Self.providerURL, app)
    closeKeyboard(app)
    sleep(1)
    let key = textFieldLabel(["sk-…"], app, secure: true) ?? textFieldLabel(["sk-…"], app)
    XCTAssertNotNil(key, "The provider API key field is missing.")
    key!.tap()
    sleep(2)
    XCTAssertTrue(app.keyboards.count > 0, "The API key field did not take keyboard focus.")
    app.typeText(Self.providerKey)
    closeKeyboard(app)
    sleep(1)
    scrollToText(["Add manually", "手动添加"], app, 6)
    XCTAssertTrue(tapTextLabel(["Add manually", "手动添加"], app), "Add manually is missing.")
    sleep(2)
    XCTAssertTrue(
      waitForLabel(["Model ID", "模型 ID"], app, 15) || app.keyboards.count > 0,
      "The manual model dialog did not open."
    )
    if app.keyboards.count > 0 {
      app.typeText(Self.providerModel)
    } else if let field = textFieldLabel(["Model ID", "模型 ID"], app) {
      field.tap()
      sleep(1)
      field.typeText(Self.providerModel)
    }
    sleep(1)
    XCTAssertTrue(tapAny(["Add", "添加"], app, 10), "The manual model dialog has no Add button.")
    sleep(2)
    XCTAssertTrue(waitForAnyLabelContaining([Self.providerModel], app, 20), "The model was not added to the provider form.")
    let save = buttonContaining(["Save", "保存"], app)
    XCTAssertNotNil(save, "The provider form has no Save button.")
    save!.tap()
    sleep(3)
  }

  // MARK: - Home, settings, engine

  private func isHome(_ app: XCUIApplication) -> Bool {
    if hasLabel(["Chats", "对话列表"], app) { return true }
    return buttonContaining(["Add image or file", "添加图片或文件"], app) != nil
  }

  @discardableResult
  private func waitForHome(_ app: XCUIApplication, _ timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if isHome(app) { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
    return isHome(app)
  }

  private func waitForComposer(_ app: XCUIApplication, _ timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if textFieldLabel(["Message DSH…", "给 DSH 发消息…"], app) != nil { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(1))
    }
    return false
  }





  @discardableResult
  private func openEnginePage(_ app: XCUIApplication) -> Bool {
    if autoStartSwitch(app) != nil { return true }
    guard tapTextLabel(["Chats", "对话列表"], app) else { return false }
    sleep(2)
    let engine = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Local engine", "本机引擎"))
    guard engine.count > 0 else { return false }
    let button = engine.element(boundBy: 0)
    if button.isHittable { button.tap() } else { button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
    sleep(2)
    return autoStartSwitch(app) != nil
  }

  private func autoStartSwitch(_ app: XCUIApplication) -> XCUIElement? {
    let query = app.switches.matching(
      NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Start when DSH Go opens", "打开 App 时自动启动")
    )
    guard query.count > 0 else { return nil }
    return query.element(boundBy: 0)
  }

  private func hasEngineStatus(_ label: String, _ zh: String, _ app: XCUIApplication) -> Bool {
    let query = app.staticTexts.matching(
      NSPredicate(format: "label == %@ OR label == %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@",
                  label, zh, "\(label) ·", "\(zh) ·")
    )
    return query.count > 0
  }

  private func waitForEngineStatus(_ label: String, _ zh: String, _ app: XCUIApplication, _ timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if hasEngineStatus(label, zh, app) { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
    return hasEngineStatus(label, zh, app)
  }

  // MARK: - Photos

  private func selectMockModelIfPossible(_ app: XCUIApplication) {
    guard let chip = buttonContaining(["Model:", "模型："], app) else { return }
    chip.tap()
    // The sheet shows the provider's display name and a title-cased model name
    // ("Mock Phase1 Model"), not the raw id.
    let needles = [Self.providerModel, "Mock Phase1 Model", "Phase1 Model"]
    let deadline = Date().addingTimeInterval(35)
    while Date() < deadline {
      if let mock = buttonContaining(needles, app) ?? staticContaining(needles, app) {
        mock.tap()
        settle(2)
        // Selecting a model does not dismiss the sheet. Its Close control covers
        // the scrim at {0,573}-{402,874}; the sheet starts around y=620, so tap
        // the exposed strip of Close above the sheet, then the scrim itself.
        for _ in 0..<3 {
          if isHome(app) { return }
          app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.677)).tap()
          settle(2)
          if isHome(app) { return }
          app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
          settle(2)
        }
        return
      }
      RunLoop.current.run(until: Date().addingTimeInterval(1))
    }
    let tree = visibleText(app)
    let attachment = XCTAttachment(string: tree)
    attachment.name = "D6-model-sheet-labels"
    attachment.lifetime = .keepAlways
    add(attachment)
    if let close = buttonContaining(["Close", "关闭"], app) {
      close.tap()
      settle(2)
    }
  }

  private func pickFirstPhoto(_ app: XCUIApplication) -> Bool {
    // The image_picker PHPicker runs in a remote view; try the app's own tree first.
    if app.cells.count > 0 {
      app.cells.element(boundBy: 0).tap()
      sleep(1)
      if tapAny(["Add", "添加", "Done", "完成"], app, 10) { return true }
      // Some pickers dismiss on selection.
      if app.cells.count == 0 { return true }
    }
    if app.images.count > 0 {
      app.images.element(boundBy: 0).tap()
      sleep(1)
      if tapAny(["Add", "添加", "Done", "完成"], app, 10) { return true }
      if app.images.count == 0 { return true }
    }
    // The picker can be hosted by Photos' own process.
    let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
    if photos.cells.count > 0 {
      photos.cells.element(boundBy: 0).tap()
      sleep(1)
      if tapAny(["Add", "添加", "Done", "完成"], photos, 10) { return true }
    }
    print("[Phase1UITests] picker tree: buttons=\(app.buttons.count) cells=\(app.cells.count) images=\(app.images.count)")
    for i in 0..<min(app.buttons.count, 20) {
      print("[Phase1UITests] picker button[\(i)]=\(app.buttons.element(boundBy: i).label)")
    }
    return false
  }

  private func assertNoCredentials(_ text: String, _ where_: String) {
    // A masked value (token=•••) is not a credential; a real one is a long
    // ASCII token after the marker.
    let patterns = [
      "sk-[A-Za-z0-9_-]{12,}",
      "Bearer [A-Za-z0-9._~+/=-]{12,}",
      "token=[A-Za-z0-9._~+/=-]{8,}",
    ]
    for pattern in patterns {
      XCTAssertNil(
        text.range(of: pattern, options: .regularExpression),
        "\(where_) exposes a credential-shaped value matching \(pattern)."
      )
    }
    XCTAssertFalse(text.contains(Self.providerKey), "\(where_) exposes the saved provider key.")
  }

  // MARK: - Generic element helpers

  private func application() -> XCUIApplication {
    XCUIApplication(bundleIdentifier: Self.appBundleIdentifier)
  }

  private func launch(_ app: XCUIApplication, firstScreen: Bool = true) {
    app.launch()
    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: Self.launchTimeout),
      "The app did not reach the foreground within \(Self.launchTimeout)s; state=\(app.state.rawValue)."
    )
    if firstScreen {
      XCTAssertTrue(waitForFirstScreen(app), "No accessible first screen within \(Self.firstScreenTimeout)s.")
    }
  }

  private func relaunch(_ app: XCUIApplication) {
    app.terminate()
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 20), "The app did not terminate before the cold relaunch.")
    launch(app)
  }

  private func waitForLabel(_ labels: [String], _ app: XCUIApplication, _ timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if hasLabel(labels, app) { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }
    return hasLabel(labels, app)
  }

  private func hasLabel(_ labels: [String], _ app: XCUIApplication) -> Bool {
    for label in labels {
      if app.buttons.matching(NSPredicate(format: "label == %@", label)).count > 0 { return true }
      if app.staticTexts.matching(NSPredicate(format: "label == %@", label)).count > 0 { return true }
      if app.otherElements.matching(NSPredicate(format: "label == %@", label)).count > 0 { return true }
    }
    return false
  }

  private func waitForAnyLabel(_ labels: [String], _ app: XCUIApplication, _ timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if hasLabel(labels, app) { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }
    return hasLabel(labels, app)
  }

  private func waitForAnyLabelContaining(_ needles: [String], _ app: XCUIApplication, _ timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if containsAnyLabel(needles, app) { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }
    return containsAnyLabel(needles, app)
  }

  private func containsAnyLabel(_ needles: [String], _ app: XCUIApplication) -> Bool {
    for needle in needles {
      if app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", needle)).count > 0 { return true }
      if app.buttons.matching(NSPredicate(format: "label CONTAINS %@", needle)).count > 0 { return true }
      if app.otherElements.matching(NSPredicate(format: "label CONTAINS %@", needle)).count > 0 { return true }
    }
    return false
  }

  @discardableResult
  private func tapAny(_ labels: [String], _ app: XCUIApplication, _ timeout: TimeInterval = 10) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      for label in labels {
        let buttons = app.buttons.matching(NSPredicate(format: "label == %@", label))
        if buttons.count > 0 {
          let element = buttons.element(boundBy: 0)
          if element.isHittable { element.tap(); return true }
          element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
          return true
        }
        let texts = app.staticTexts.matching(NSPredicate(format: "label == %@", label))
        if texts.count > 0 {
          let element = texts.element(boundBy: 0)
          if element.isHittable { element.tap(); return true }
          element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
          return true
        }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    } while Date() < deadline
    return false
  }

  private func tapTextLabel(_ labels: [String], _ app: XCUIApplication) -> Bool {
    for label in labels {
      let texts = app.staticTexts.matching(NSPredicate(format: "label == %@", label))
      if texts.count > 0 {
        let element = texts.element(boundBy: 0)
        if element.isHittable { element.tap(); return true }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
      }
    }
    return false
  }

  private func waitForButtonContaining(_ needles: [String], _ app: XCUIApplication, _ timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let button = buttonContaining(needles, app), button.isHittable { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
    return buttonContaining(needles, app)?.isHittable ?? false
  }

  private func buttonContaining(_ needles: [String], _ app: XCUIApplication) -> XCUIElement? {
    for needle in needles {
      let query = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", needle))
      if query.count > 0 { return query.element(boundBy: 0) }
    }
    return nil
  }

  private func staticContaining(_ needles: [String], _ app: XCUIApplication) -> XCUIElement? {
    for needle in needles {
      let query = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", needle))
      if query.count > 0 { return query.element(boundBy: 0) }
    }
    return nil
  }

  private func tapButtonContaining(_ needles: [String], _ app: XCUIApplication) -> Bool {
    for needle in needles {
      let query = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", needle))
      if query.count > 0 {
        let element = query.element(boundBy: 0)
        if element.isHittable { element.tap() } else { element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        return true
      }
    }
    return false
  }

  private func textFieldLabel(_ labels: [String], _ app: XCUIApplication, secure: Bool = false) -> XCUIElement? {
    for label in labels {
      let query = secure
        ? app.secureTextFields.matching(NSPredicate(format: "label == %@", label))
        : app.textFields.matching(NSPredicate(format: "label == %@", label))
      if query.count > 0 { return query.element(boundBy: 0) }
    }
    return nil
  }

  private func fillTextField(_ labels: [String], text: String, _ app: XCUIApplication) {
    for _ in 0..<5 {
      guard let field = textFieldLabel(labels, app) else {
        app.swipeUp()
        sleep(1)
        continue
      }
      if !field.isHittable { app.swipeUp(); sleep(1); continue }
      field.tap()
      var focused = false
      for _ in 0..<25 {
        if app.textFields.matching(NSPredicate(format: "hasKeyboardFocus == 1")).count > 0 {
          focused = true
          break
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
      }
      if focused {
        field.typeText(text)
        return
      }
      sleep(1)
    }
    XCTFail("Could not focus the text field \(labels).")
  }

  private func closeKeyboard(_ app: XCUIApplication) {
    guard app.keyboards.count > 0 else { return }
    let done = app.keyboards.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "done", "Done")).firstMatch
    if done.exists {
      done.tap()
    } else {
      app.typeText("\n")
    }
    let deadline = Date().addingTimeInterval(10)
    while app.keyboards.count > 0 && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }
  }

  private func scrollToText(_ labels: [String], _ app: XCUIApplication, _ max: Int) {
    for _ in 0..<max {
      for label in labels {
        let query = app.staticTexts.matching(NSPredicate(format: "label == %@", label))
        if query.count > 0 && query.element(boundBy: 0).isHittable { return }
      }
      app.swipeUp()
      sleep(1)
    }
  }

  private func scrollToButtonContaining(_ needles: [String], _ app: XCUIApplication, _ max: Int) -> Bool {
    for _ in 0..<max {
      if let button = buttonContaining(needles, app), button.isHittable { return true }
      app.swipeUp()
      sleep(1)
    }
    return buttonContaining(needles, app)?.isHittable ?? false
  }

  private func visibleText(_ app: XCUIApplication) -> String {
    var text = app.debugDescription
    let texts = app.staticTexts
    for i in 0..<texts.count { text += "\n" + texts.element(boundBy: i).label }
    let buttons = app.buttons
    for i in 0..<buttons.count { text += "\n" + buttons.element(boundBy: i).label }
    return text
  }

  private func waitForInstallPercent(_ app: XCUIApplication, _ timeout: TimeInterval) -> Int? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let buttons = app.buttons
      for index in 0..<buttons.count {
        let label = buttons.element(boundBy: index).label
        guard label.contains("已完成") || label.contains("Preparing the runtime") else { continue }
        if let range = label.range(of: "[0-9]{1,3}%", options: .regularExpression) {
          return Int(label[range].replacingOccurrences(of: "%", with: ""))
        }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }
    return nil
  }

  private func stringValue(_ element: XCUIElement?) -> String {
    guard let element else { return "" }
    return String(describing: element.value ?? "")
  }

  private func sway(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
  }

  // MARK: - Accessibility / screenshots

  private func waitForFirstScreen(_ app: XCUIApplication) -> Bool {
    let deadline = Date().addingTimeInterval(Self.firstScreenTimeout)
    while Date() < deadline {
      let state = app.state
      if state == .notRunning { return false }
      if state == .runningForeground {
        let texts = app.staticTexts.count
        let buttons = app.buttons.count
        if texts + buttons > 0, !launchPlateVisible(app) {
          print("[Phase1UITests] first screen reachable: state=\(state.rawValue) staticTexts=\(texts) buttons=\(buttons)")
          return true
        }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
    return false
  }

  private func launchPlateVisible(_ app: XCUIApplication) -> Bool {
    let query = app.staticTexts.matching(NSPredicate(format: "label == %@", "DSH Go"))
    guard query.count > 0 else { return false }
    let plate = query.element(boundBy: 0)
    guard let snapshot = try? plate.snapshot() else { return false }
    let window = app.windows.firstMatch
    guard window.exists else { return false }
    let bounds = window.frame
    guard bounds.width > 0, bounds.height > 0 else { return false }
    return snapshot.frame.width >= bounds.width - 1 && snapshot.frame.height >= bounds.height - 1
  }

  private func attachScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func meanLuminance() -> Double {
    let image = XCUIScreen.main.screenshot().image
    guard let cgImage = image.cgImage else { return 1 }
    let width = 16
    let height = 16
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
      guard let context = CGContext(
        data: buffer.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
      ) else { return false }
      context.interpolationQuality = .low
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return 1 }
    var total = 0.0
    for index in stride(from: 0, to: pixels.count, by: 4) {
      let r = Double(pixels[index]) / 255
      let g = Double(pixels[index + 1]) / 255
      let b = Double(pixels[index + 2]) / 255
      total += 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
    return total / Double(width * height)
  }
}
