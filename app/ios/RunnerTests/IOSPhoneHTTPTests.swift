import XCTest
@testable import Runner

/// Regression coverage for the iOS stop crash: retiring the phone bridge while a
/// poll request is in flight cancelled the request, but `data(for:)` could create
/// its task after the session was invalidated, which throws an uncatchable
/// NSInvalidArgumentException. These requests hang in a stub protocol so the
/// retire always lands inside the request, not before or after it.
@MainActor
final class IOSPhoneHTTPTests: XCTestCase {
  private final class Hanging: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var started = 0
    private static let lock = NSLock()
    static func take() -> Int {
      lock.lock(); defer { lock.unlock() }
      return started
    }
    static func reset() {
      lock.lock(); started = 0; lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
      Self.lock.lock(); Self.started += 1; Self.lock.unlock()
    }
    override func stopLoading() {}
  }

  private static func configuration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [Hanging.self]
    config.timeoutIntervalForRequest = 5
    return config
  }

  private func makeHTTP() -> IOSPhoneHTTP {
    let http = IOSPhoneHTTP(configuration: { Self.configuration() })
    http.open()
    return http
  }

  private func send(_ http: IOSPhoneHTTP, route: String) async throws -> (Int, Data) {
    try await http.post(to: URL(string: "http://127.0.0.1:1")!, token: "synthetic",
      runId: "synthetic-run", route: route, values: [:])
  }

  private func waitForRequests(_ count: Int) async throws {
    for _ in 0..<400 {
      if Hanging.take() >= count { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("stub protocol never received \(count) request(s)")
  }

  private func expectCancelled(_ result: Result<(Int, Data), Error>, _ line: UInt = #line) {
    switch result {
    case .success:
      XCTFail("retired request unexpectedly succeeded", line: line)
    case .failure(let error):
      XCTAssertEqual((error as? URLError)?.code, .cancelled, "\(error)", line: line)
    }
  }

  /// The crash sequence: retire() on the main actor while poll's POST is in
  /// flight. Every round opens a fresh session, so each retire invalidates a
  /// session that still has requests pending.
  func testRetireDuringInFlightRequestsCancelsThemRepeatedly() async throws {
    for round in 0..<20 {
      Hanging.reset()
      let http = makeHTTP()
      let claim = Task { try await send(http, route: "claim") }
      let begin = Task { try await send(http, route: "begin") }
      try await waitForRequests(2)
      XCTAssertEqual(Hanging.take(), 2, "round \(round)")
      // Exactly where EngineChannel.retirePhone() lands during an engine stop.
      http.retire()
      expectCancelled(await claim.result)
      expectCancelled(await begin.result)
    }
  }

  /// A cancelled Task must not leave its request waiting for the timeout.
  func testCancellingTaskCancelsItsInFlightRequest() async throws {
    Hanging.reset()
    let http = makeHTTP()
    let claim = Task { try await send(http, route: "claim") }
    try await waitForRequests(1)
    claim.cancel()
    expectCancelled(await claim.result)
    http.retire()
  }

  /// After retirement no request may reach the invalidated session at all.
  func testRetiredSessionRejectsFurtherRequests() async throws {
    Hanging.reset()
    let http = makeHTTP()
    http.retire()
    let result = await Task { try await send(http, route: "claim") }.result
    expectCancelled(result)
    XCTAssertEqual(Hanging.take(), 0)
  }
}
