//
//  GeneralTests.swift
//  IronTests
//
//  Created by Karim Abou Zeid on 14.01.18.
//  Copyright © 2018 Karim Abou Zeid Software. All rights reserved.
//

import XCTest
import SwiftUI
import WorkoutDataKit
@testable import Iron

class GeneralTests: XCTestCase {

    func testWorkoutHistoryChartRendersWithPinnedDependency() throws {
        let fixture = MockWorkoutData.metric
        let history = try fixture.context.fetch(fixture.workoutExercise.historyFetchRequest)
        let generator = WorkoutExerciseChartDataGenerator(
            workoutExercises: history,
            evaluator: WorkoutExerciseChartData.evaluator(
                for: .oneRM, weightUnit: .metric, maxRepetitionsForOneRepMax: 12))
        let entries = generator.chartDataEntries()
        XCTAssertFalse(entries.isEmpty)

        let chart = StyledLineChartView(frame: CGRect(x: 0, y: 0, width: 360, height: 240))
        chart.data = generator.lineChartData(label: "Estimated 1RM")
        chart.notifyDataSetChanged()
        chart.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: chart.bounds).image { context in
            chart.layer.render(in: context.cgContext)
        }

        XCTAssertEqual(chart.data?.entryCount, entries.count)
        XCTAssertTrue(chart.leftAxis.axisMinimum.isFinite)
        XCTAssertTrue(chart.leftAxis.axisMaximum.isFinite)
        XCTAssertGreaterThan(chart.leftAxis.axisMaximum, chart.leftAxis.axisMinimum)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Workout history chart with pinned DGCharts"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    
    override func setUp() {
        super.setUp()
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }
    
    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        super.tearDown()
    }
    
    private func loadExercises() -> [Exercise] {
        let data = try! Data(contentsOf: ExerciseStore.defaultBuiltInExercisesURL)
        return try! JSONDecoder().decode([Exercise].self, from: data)
    }
    
    func testEverkineticGroupingSpeed() {
        let exercises = loadExercises()
        self.measure {
            _ = ExerciseStore.splitIntoMuscleGroups(exercises: exercises)
        }
    }
    
    func testEverkineticGrouping() {
        let exercises = loadExercises()
        let groups = ExerciseStore.splitIntoMuscleGroups(exercises: exercises)
        var totalCount = 0
        for group in groups {
            totalCount += group.exercises.count

            for exercise in group.exercises {
                XCTAssert(exercise.muscleGroup == group.title)
            }
        }
        XCTAssert(totalCount == exercises.count)
    }

    func testEverkineticPDFsExist() {
        let exercises = loadExercises()
        for exercise in exercises {
            for pdf in exercise.pdfPaths {
                let url = ExerciseStore.defaultBuiltInExercisesResourceURL.appendingPathComponent(pdf)
                XCTAssertNoThrow(try Data(contentsOf: url))
            }
        }
    }

    func testUniq() {
        var array = ["Hello","Me","That","Me","Hello","Me","as","the"]
        
        let arrayUniqed = array.uniqed()
        XCTAssertEqual(arrayUniqed, ["Hello","Me","That","as","the"])
        
        array.uniq()
        XCTAssertEqual(array, arrayUniqed)
    }
    
    func testSortByFrequency() {
        var array = ["Hello","Me","That","Me","Hello","Me"]
        
        let arraySorted = array.sortedByFrequency()
        XCTAssertEqual(arraySorted, ["That", "Hello", "Hello", "Me", "Me", "Me"])
        
        array.sortByFrequency()
        XCTAssertEqual(array, arraySorted)
    }

    func testWeightUnitConversion() {
        // correct conversion
        XCTAssertEqual(WeightUnit.convert(weight: 20, from: .metric, to: .imperial).rounded(), 44)
        XCTAssertEqual(WeightUnit.convert(weight: 45, from: .imperial, to: .metric).rounded(), 20)
        
        // no precision loss when converting back and forth
        XCTAssertEqual(WeightUnit.convert(weight: WeightUnit.convert(weight: 20, from: .metric, to: .imperial), from: .imperial, to: .metric), 20)
        XCTAssertEqual(WeightUnit.convert(weight: WeightUnit.convert(weight: 127.5, from: .metric, to: .imperial), from: .imperial, to: .metric), 127.5)
        XCTAssertEqual(WeightUnit.convert(weight: WeightUnit.convert(weight: 123980323.59392, from: .metric, to: .imperial), from: .imperial, to: .metric), 123980323.59392)
        
        XCTAssertEqual(WeightUnit.convert(weight: WeightUnit.convert(weight: 45, from: .imperial, to: .metric), from: .metric, to: .imperial), 45)
        XCTAssertEqual(WeightUnit.convert(weight: WeightUnit.convert(weight: 900, from: .imperial, to: .metric), from: .metric, to: .imperial), 900)
        XCTAssertEqual(WeightUnit.convert(weight: WeightUnit.convert(weight: 123980323.59392, from: .imperial, to: .metric), from: .metric, to: .imperial), 123980323.59392)
    }
}

final class PolishLocalizationTests: XCTestCase {
    func testAutomaticAndExplicitLanguageResolution() {
        XCTAssertEqual(Iron.AppLanguage.automatic.resolved(preferredLanguages: ["pl-PL", "en-US"]), "pl")
        XCTAssertEqual(Iron.AppLanguage.automatic.resolved(preferredLanguages: ["fr-FR", "pl-PL"]), "en")
        XCTAssertEqual(Iron.AppLanguage.automatic.resolved(preferredLanguages: []), "en")
        XCTAssertEqual(Iron.AppLanguage.english.resolved(preferredLanguages: ["pl-PL"]), "en")
        XCTAssertEqual(Iron.AppLanguage.polish.resolved(preferredLanguages: ["en-US"]), "pl")
    }

    func testCatalogCoverageIdentitySearchAndStableEncoding() throws {
        let originalLanguage = WorkoutDataKit.L10n.language
        defer { WorkoutDataKit.L10n.language = originalLanguage }
        let englishData = try Data(contentsOf: ExerciseStore.defaultBuiltInExercisesURL)
        let polishURL = ExerciseStore.defaultBuiltInExercisesResourceURL.appendingPathComponent("exercises-pl.json")
        let english = try XCTUnwrap(JSONSerialization.jsonObject(with: englishData) as? [[String: Any]])
        let polish = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: polishURL)) as? [[String: Any]])
        XCTAssertEqual(english.count, 159)
        XCTAssertEqual(polish.count, english.count)
        XCTAssertEqual(Set(polish.compactMap { $0["uuid"] as? String }).count, english.count)
        let exercises = try JSONDecoder().decode([Exercise].self, from: englishData)
        WorkoutDataKit.L10n.language = .english
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(exercises)
        for (source, translated) in zip(english, polish) {
            XCTAssertEqual(source["uuid"] as? String, translated["uuid"] as? String)
            XCTAssertEqual(source["id"] as? Int, translated["id"] as? Int)
            for key in ["primary", "secondary", "equipment", "pdf", "png", "references"] {
                XCTAssertEqual(source[key] as? [String], translated[key] as? [String], key)
            }
            XCTAssertNotEqual(source["title"] as? String, translated["title"] as? String)
            for key in ["alias", "steps", "tips"] {
                let original = source[key] as? [String] ?? []
                let localized = translated[key] as? [String] ?? []
                XCTAssertEqual(original.count, localized.count, "\(key): \(source["title"] ?? "")")
                for (sourceText, localizedText) in zip(original, localized) {
                    // ID 239 contains a source-only HTML nonbreaking-space slot.
                    let hasInstruction = !sourceText.replacingOccurrences(of: "&nbsp;", with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if hasInstruction { XCTAssertFalse(localizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
            }
        }
        for language in [WorkoutDataKit.AppLanguage.polish, .english] {
            WorkoutDataKit.L10n.language = language
            for (index, exercise) in exercises.enumerated() {
                let polishTitle = try XCTUnwrap(polish[index]["title"] as? String)
                let englishTitle = try XCTUnwrap(english[index]["title"] as? String)
                XCTAssertEqual(exercise.title, language == .polish ? polishTitle : englishTitle)
                for name in exercise.searchNames {
                    let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl"))
                    XCTAssertTrue(ExerciseStore.filter(exercises: exercises, using: folded).contains(where: { $0.uuid == exercise.uuid }), name)
                }
            }
            XCTAssertEqual(try encoder.encode(exercises), before, "Language must not alter backup data")
        }
    }

    func testCustomExerciseContentRemainsUnchanged() throws {
        let originalLanguage = WorkoutDataKit.L10n.language
        defer { WorkoutDataKit.L10n.language = originalLanguage }
        let data = Data("""
        [{"uuid":"AA3C081D-2A51-4E20-B112-3B5C265B0A28","id":10000,"title":"My overhead press","alias":["My alias"],"primer":"My notes","primary":["deltoid"],"secondary":[],"equipment":[],"steps":["My step"],"tips":["My tip"]}]
        """.utf8)
        let custom = try XCTUnwrap(JSONDecoder().decode([Exercise].self, from: data).first)
        WorkoutDataKit.L10n.language = .polish
        XCTAssertEqual(custom.title, "My overhead press")
        XCTAssertEqual(custom.description, "My notes")
        XCTAssertEqual(custom.steps, ["My step"])
        XCTAssertEqual(custom.tips, ["My tip"])
        XCTAssertEqual(custom.searchNames, ["My overhead press", "My alias"])
    }

    func testSelectedLanguageResourceLookupAndFallback() {
        let previous = Iron.L10n.language
        defer { Iron.L10n.language = previous }
        Iron.L10n.language = .polish
        XCTAssertEqual(Iron.L10n.string("Settings", bundle: Bundle(for: ExerciseStore.self)), "Ustawienia")
        XCTAssertEqual(Iron.L10n.string("unregistered fallback key"), "unregistered fallback key")
        Iron.L10n.language = .english
        XCTAssertEqual(Iron.L10n.string("Settings"), "Settings")
    }
}


extension PolishLocalizationTests {
    /// Exercises the actual SwiftUI roots and captures reviewable evidence of
    /// a live preference change, plus Polish exercise detail and settings UI.
    func testLiveLanguageSwitchSnapshots() throws {
        let previous = Iron.L10n.language
        defer { Iron.L10n.language = previous }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = UIScreen.main.bounds
        let state = SceneState()
        state.selectedTab = .exercises
        Iron.SettingsStore.shared.language = .polish
        window.rootViewController = UIHostingController(rootView: ContentView().environmentObject(state))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        func snapshot(_ name: String) {
            let ready = expectation(description: name)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ready.fulfill() }
            wait(for: [ready], timeout: 3)
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        snapshot("Polish exercise groups")
        Iron.SettingsStore.shared.language = .english
        XCTAssertEqual(state.selectedTab, .exercises)
        snapshot("English restored on live root")
        Iron.SettingsStore.shared.language = .polish
        let exercise = try XCTUnwrap(ExerciseStore.shared.builtInExercises.first)
        window.rootViewController = UIHostingController(rootView:
            NavigationView { ExerciseDetailView(exercise: exercise) }
                .environmentObject(Iron.SettingsStore.shared)
                .environmentObject(ExerciseStore.shared)
                .environment(\.managedObjectContext, WorkoutDataStorage.shared.persistentContainer.viewContext)
                .environment(\.locale, Iron.L10n.locale))
        snapshot("Polish exercise detail")
        window.rootViewController = UIHostingController(rootView:
            NavigationView { GeneralSettingsView() }
                .environmentObject(Iron.SettingsStore.shared)
                .environment(\.locale, Iron.L10n.locale))
        snapshot("Polish language settings")
    }
}
