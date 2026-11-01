import XCTest

/// Runs against the installed app through XCTest's UI automation service.
/// No app models, stores, view factories or language defaults are injected.
final class LocalizationE2ETests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        authorizeHealthIfPresented()
    }

    override func tearDownWithError() throws {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        if let app = app {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Application accessibility tree"
            tree.lifetime = .keepAlways
            add(tree)
            app.terminate()
        }
    }

    private func tab(_ english: String, _ polish: String) -> XCUIElement {
        app.tabBars.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", english, polish)).firstMatch
    }

    private func authorizeHealthIfPresented() {
        let allow = app.buttons["UIA.Health.Allow.Button"]
        if allow.waitForExistence(timeout: 3) {
            if !allow.isEnabled {
                app.cells["UIA.Health.AuthSheet.AllCategoryButton"].tap()
            }
            XCTAssertTrue(allow.isEnabled, app.debugDescription)
            allow.tap()
        }
        // iOS 27 asks for the history window on a second authorization page.
        let historyWindow = app.staticTexts["Past 30 Days and Future Data"].firstMatch
        if historyWindow.waitForExistence(timeout: 3) {
            historyWindow.tap()
            app.buttons["Allow"].firstMatch.tap()
        }
    }

    private func settings() {
        let settings = tab("Settings", "Ustawienia")
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "The production app must render its tabs")
        settings.tap()
        if app.navigationBars["General"].exists || app.navigationBars["Ogólne"].exists { return }
        let general = app.buttons.matching(NSPredicate(format: "label == 'General' OR label == 'Ogólne'")).firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 10))
        general.tap()
    }

    private func chooseLanguage(_ title: String) {
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Language' OR label BEGINSWITH 'Język'")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        picker.tap()
        let option = app.buttons.matching(identifier: title).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
        option.tap()
    }

    func testLanguageSwitchAndBilingualExerciseSearch() {
        settings()
        chooseLanguage("Polski")
        XCTAssertTrue(app.navigationBars["Ogólne"].waitForExistence(timeout: 10))
        tab("Exercises", "Ćwiczenia").tap()
        let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Wszystkie'")).firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        all.tap()
        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Overhead Press")
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Wyciskanie' AND label CONTAINS 'maszynie'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10), "English query must find a Polish exercise")
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Overhead Press".count))
        search.typeText("Wyciskanie nad głowę")
        XCTAssertTrue(result.waitForExistence(timeout: 10), "Polish query must find the same exercise")
        result.tap()
        XCTAssertTrue(app.staticTexts["MIĘŚNIE"].waitForExistence(timeout: 10))
        settings()
        chooseLanguage("English")
        XCTAssertTrue(tab("Exercises", "Ćwiczenia").waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 20), "Language choice must survive relaunch")
    }

    func testSiriStartsWorkoutInIron() {
        XCTAssertTrue(tab("Workout", "Trening").waitForExistence(timeout: 30))
        tab("Workout", "Trening").tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Start Workout' OR label == 'Rozpocznij trening'")).firstMatch.waitForExistence(timeout: 10), "Siri test requires no existing workout")
        XCUIDevice.shared.siriService.activate(voiceRecognitionText: "Start a weight lifting workout in the Iron app")
        let siriScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        siriScreenshot.name = "Siri response to Start a weight lifting workout in the Iron app"
        siriScreenshot.lifetime = .keepAlways
        add(siriScreenshot)
        let siri = XCUIApplication(bundleIdentifier: "com.apple.siri")
        let response = XCTAttachment(string: siri.debugDescription)
        response.name = "Siri accessibility response"
        response.lifetime = .keepAlways
        add(response)
        // Let Siri finish resolving the request before bringing Iron forward.
        let finish = app.buttons.matching(NSPredicate(format: "label == 'Finish Workout' OR label == 'Zakończ trening'")).firstMatch
        _ = finish.waitForExistence(timeout: 30)
        let resolved = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        resolved.name = "Siri resolved response"
        resolved.lifetime = .keepAlways
        add(resolved)
        app.activate()
        tab("Workout", "Trening").tap()
        XCTAssertTrue(finish.waitForExistence(timeout: 10), "Siri must create an actual workout, not only display its assistant UI")
        // Discard only the empty workout created by this test, using the app UI.
        let cancel = app.navigationBars.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == 'Anuluj'")).firstMatch
        if cancel.exists { cancel.tap() }
    }

    func testPolishWorkoutSavedInHistoryAfterRelaunch() {
        settings()
        chooseLanguage("Polski")
        tab("Workout", "Trening").tap()
        let start = app.buttons["Rozpocznij trening"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "Preserve any pre-existing workout; start only from idle")
        start.tap()
        let title = "E2E " + UUID().uuidString.prefix(8)
        let titleField = app.textFields["Nazwa"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10), app.debugDescription)
        titleField.tap()
        titleField.typeText(title + "\n")
        // Verify the title reaches disk before another edit can save the context.
        app.terminate()
        app.launch()
        XCTAssertTrue(tab("Workout", "Trening").waitForExistence(timeout: 20))
        tab("Workout", "Trening").tap()
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        XCTAssertEqual(titleField.value as? String, title)
        app.buttons["Dodaj ćwiczenia"].tap()
        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Overhead Press")
        let selection = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Wyciskanie' AND label CONTAINS 'maszynie'")).firstMatch
        XCTAssertTrue(selection.waitForExistence(timeout: 10), app.debugDescription)
        selection.tap()
        app.buttons["Dodaj"].tap()
        let exercise = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Wyciskanie' AND label CONTAINS 'maszynie'")).firstMatch
        XCTAssertTrue(exercise.waitForExistence(timeout: 10))
        exercise.tap()
        authorizeHealthIfPresented()
        let complete = app.buttons["Zakończ serię"].firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 10), app.debugDescription)
        let duration = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Czas treningu")).firstMatch
        XCTAssertTrue(duration.waitForExistence(timeout: 10), app.debugDescription)
        duration.tap()
        let resetStart = app.buttons["Ustaw początek na teraz"].firstMatch
        XCTAssertTrue(resetStart.waitForExistence(timeout: 10), app.debugDescription)
        resetStart.tap()
        app.buttons["Zamknij"].firstMatch.tap()
        // Known local rest commits must not make the already-open set draft stale.
        let rest = app.buttons["Czas przerwy"].firstMatch
        XCTAssertTrue(rest.waitForExistence(timeout: 10), app.debugDescription)
        rest.tap()
        XCTAssertTrue(app.navigationBars["Czas przerwy"].waitForExistence(timeout: 10))
        let minute = app.buttons["01:00"].firstMatch
        XCTAssertTrue(minute.waitForExistence(timeout: 10), app.debugDescription)
        minute.tap()
        let increase = app.buttons["+10 s"].firstMatch
        XCTAssertTrue(increase.waitForExistence(timeout: 10), app.debugDescription)
        increase.tap()
        app.buttons["Anuluj"].firstMatch.tap()
        app.buttons["Zamknij"].firstMatch.tap()
        XCTAssertTrue(complete.waitForExistence(timeout: 10))
        complete.tap()
        authorizeHealthIfPresented()
        let completed = app.images["Ukończono"].firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 10), app.debugDescription)
        // Correcting a completed set must keep the same editor, without advancing
        // to the next unfinished set or presenting a new completion action.
        completed.tap()
        let correction = app.buttons["OK"].firstMatch
        XCTAssertTrue(correction.waitForExistence(timeout: 10), app.debugDescription)
        correction.tap()
        XCTAssertTrue(correction.waitForExistence(timeout: 10), "Correction must preserve the selected set")
        XCTAssertFalse(complete.exists, "Correction must not advance to a new completion")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Zakończ trening"].tap()
        let finish = app.navigationBars.buttons["Zakończ"]
        XCTAssertTrue(finish.waitForExistence(timeout: 10), app.debugDescription)
        finish.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        app.terminate()
        app.launch()
        let history = tab("History", "Historia")
        XCTAssertTrue(history.waitForExistence(timeout: 20))
        history.tap()
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "Finished workout must persist in history after relaunch")
        saved.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Wyciskanie' AND label CONTAINS 'maszynie'")).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    }
}
