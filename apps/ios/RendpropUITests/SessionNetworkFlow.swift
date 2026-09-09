import XCTest

/// Real screens + real loopback HTTP; the server cuts only signup connections.
/// Run only on a disposable simulator, never a device containing customer data.
final class SessionNetworkFlow: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:18765")!
    private var app: XCUIApplication!

    private func control(_ path: String) throws -> [String: Any] {
        let done = expectation(description: path)
        var result: Result<[String: Any], Error>!
        URLSession.shared.dataTask(with: base.appendingPathComponent("__control/\(path)")) { data, response, error in
            defer { done.fulfill() }
            do {
                if let error { throw error }
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let data, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { throw URLError(.badServerResponse) }
                result = .success(object)
            } catch { result = .failure(error) }
        }.resume()
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(result).get()
    }

    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { app?.terminate(); app = nil }

    private func launch(_ surface: String) throws {
        XCTAssertEqual(try control("reset")["ok"] as? Bool, true)
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-sessionNetworkTesting", "-hasOnboarded", "YES"]
        app.launchEnvironment["RENDP_TEST_URL"] = base.absoluteString
        app.launchEnvironment["RENDP_TEST_RUN"] = UUID().uuidString
        app.launchEnvironment["RENDP_TEST_SURFACE"] = surface
        app.launch()
        XCTAssertFalse(app.staticTexts["phase1.fixture.error"].exists)
    }

    private func tap(_ id: String, maxSwipes: Int = 12) throws {
        let button = app.buttons[id].firstMatch
        for _ in 0..<maxSwipes {
            if button.exists && button.isHittable { button.tap(); return }
            app.swipeUp()
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing action: \(id)\n\(app.debugDescription)")
        XCTAssertTrue(button.isHittable, "Unreachable action: \(id)")
        button.tap()
    }

    private func recoverAndAssert(_ route: String, expectedCalls: Int = 1) throws {
        let notice = app.otherElements["session.connection.notice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 15), "No connection retry UI\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["session.connection.retry"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sign in with Apple")).firstMatch.exists)
        let before = try control("state")
        XCTAssertEqual(before["blocked"] as? Bool, true)
        XCTAssertEqual(before["accepted"] as? Int, 0)
        let beforeRequests = before["requests"] as? [String:Int] ?? [:]
        XCTAssertGreaterThan(beforeRequests["/auth/v1/signup"] ?? 0, 0)
        XCTAssertEqual(beforeRequests[route] ?? 0, 0, "Feature ran before a session")
        XCTAssertEqual(try control("unblock")["ok"] as? Bool, true)
        // No tap after network recovery. Poll the local server, not the button.
        let deadline = Date().addingTimeInterval(90)
        var state: [String:Any] = [:]
        repeat {
            state = try control("state")
            if ((state["requests"] as? [String:Int])?[route] ?? 0) >= expectedCalls { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
        XCTAssertEqual((state["requests"] as? [String:Int])?[route], expectedCalls, "Original action did not resume exactly once")
        XCTAssertEqual(state["accepted"] as? Int, 1, "More than one anonymous session minted")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sign in with Apple")).firstMatch.exists)
    }

    func testPublishRecoversWithoutSecondTap() throws {
        try launch("publish")
        try tap("render.publish")
        try recoverAndAssert("/functions/v1/renders/publish-app")
        XCTAssertTrue(app.buttons["Share your link"].waitForExistence(timeout: 15))
    }

    func testPhotoRecoversWithoutSecondTap() throws {
        try launch("photo")
        try tap("studio.edit.declutter")
        // The real studio preselects all photos for fan-out edits.
        try tap("studio.batchApply")
        try recoverAndAssert("/functions/v1/ai-photo", expectedCalls: 2)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 photos changed")).firstMatch.waitForExistence(timeout: 15))
    }

    func testAerialRecoversWithoutSecondTap() throws {
        try launch("aerial")
        try tap("phase1.aerialGenerate")
        try recoverAndAssert("/functions/v1/ai-video/aerial")
        XCTAssertTrue(app.staticTexts["Aerial ready"].waitForExistence(timeout: 45))
    }

    func testReelRecoversWithoutSecondTap() throws {
        try launch("reel")
        try tap("reel.photo.fixture-0")
        try tap("reel.photo.fixture-1")
        try tap("phase1.reelGenerate")
        try recoverAndAssert("/functions/v1/ai-video/reel-clip", expectedCalls: 2)
        XCTAssertTrue(app.staticTexts["Your reel is ready"].waitForExistence(timeout: 60))
    }
}
