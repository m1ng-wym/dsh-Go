import XCTest

/// Process-level acceptance tests for Phase 1 v1.1.
///
/// This bundle drives the real Runner app through `XCUIApplication(bundleIdentifier:)`;
/// it is not a Flutter widget-test shell and it deliberately has no test host. The app
/// under test must already be installed for the destination simulator (or device):
/// `xcrun simctl install <udid> app/build/ios/iphonesimulator/Runner.app`.
final class Phase1UITests: XCTestCase {
  private static let appBundleIdentifier = "io.github.ccch1mneyyy.dshgo"
  private static let launchTimeout: TimeInterval = 60
  /// The first screen is Flutter-drawn; its accessibility tree can arrive a little
  /// after the process is in the foreground.
  private static let firstScreenTimeout: TimeInterval = 60
  private static let terminateTimeout: TimeInterval = 15

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  /// The real app launches to a first screen (welcome, connect or home) without crashing.
  func testAppLaunches() throws {
    let app = XCUIApplication(bundleIdentifier: Self.appBundleIdentifier)
    app.launch()

    XCTAssertTrue(
      waitForFirstScreen(app),
      "The real app did not show an accessible first screen (welcome/connect/home) within \(Self.firstScreenTimeout)s; state=\(app.state.rawValue)."
    )
    XCTAssertTrue(
      app.state == .runningForeground,
      "The real app is not in the foreground after launch; state=\(app.state.rawValue)."
    )
    // Evidence only: let the launch overlay finish fading so the screenshot shows the
    // first screen itself rather than the brand plate over it.
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    attachScreenshot(named: "testAppLaunches-first-screen")
  }

  /// Skeleton only: the process can be terminated and cold-launched again. No data,
  /// state or timing assertions yet; later Phase 1 tasks own those.
  func testColdRelaunchSkeleton() throws {
    let app = XCUIApplication(bundleIdentifier: Self.appBundleIdentifier)

    app.launch()
    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: Self.launchTimeout),
      "The initial launch did not reach the foreground within \(Self.launchTimeout)s."
    )

    for cycle in 1...2 {
      app.terminate()
      XCTAssertTrue(
        app.wait(for: .notRunning, timeout: Self.terminateTimeout),
        "The app did not terminate before cold relaunch \(cycle); state=\(app.state.rawValue)."
      )

      let started = Date()
      app.launch()
      XCTAssertTrue(
        app.wait(for: .runningForeground, timeout: Self.launchTimeout),
        "Cold relaunch \(cycle) did not reach the foreground within \(Self.launchTimeout)s; state=\(app.state.rawValue)."
      )
      XCTAssertTrue(
        app.state == .runningForeground,
        "Cold relaunch \(cycle) left the app outside the foreground; state=\(app.state.rawValue)."
      )
      print("[Phase1UITests] cold relaunch \(cycle) foreground after \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
    }
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    attachScreenshot(named: "testColdRelaunchSkeleton-after-two-relaunches")
  }

  /// Accepts any of the welcome / connect / home screens: enough accessible text or
  /// buttons means Flutter rendered a real screen, and the brand launch plate covering
  /// the window must be gone. A crash or a stuck launch fails.
  private func waitForFirstScreen(_ app: XCUIApplication) -> Bool {
    let deadline = Date().addingTimeInterval(Self.firstScreenTimeout)
    while Date() < deadline {
      let state = app.state
      // A crash or an external termination must not look like a slow first frame.
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

  /// The cold-start launch plate is a full-window semantics container labelled with the
  /// app name; its text is already exposed while the real page is still under the fade.
  /// Counting it as "the first screen" would accept a splash that never finished.
  private func launchPlateVisible(_ app: XCUIApplication) -> Bool {
    let plate = app.staticTexts.matching(NSPredicate(format: "label == %@", "DSH Go")).firstMatch
    guard plate.exists, let snapshot = try? plate.snapshot() else { return false }
    let window = app.windows.firstMatch
    guard window.exists else { return false }
    let bounds = window.frame
    guard bounds.width > 0, bounds.height > 0 else { return false }
    return snapshot.frame.width >= bounds.width - 1 && snapshot.frame.height >= bounds.height - 1
  }

  private func attachScreenshot(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
