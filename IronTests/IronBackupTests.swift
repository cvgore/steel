//
//  IronBackupTests.swift
//  IronTests
//
//  Created by Karim Abou Zeid on 25.03.20.
//  Copyright © 2020 Karim Abou Zeid Software. All rights reserved.
//

import XCTest
import CoreData
import WorkoutDataKit
@testable import Iron

class IronBackupTests: XCTestCase {
    var persistenContainer: NSPersistentContainer!
    var userDefaults: UserDefaults!
    var exerciseStore: ExerciseStore!

    override func setUpWithError() throws {
        // reset test folder
        let testFolder = FileManager.default.temporaryDirectory.appendingPathComponent("test", isDirectory: true)
        if FileManager.default.fileExists(atPath: testFolder.path) {
            try! FileManager.default.removeItem(at: testFolder)
        }
        try! FileManager.default.createDirectory(at: testFolder, withIntermediateDirectories: true)
        
        // reset user defaults
        UserDefaults().removePersistentDomain(forName: "test")
        userDefaults = UserDefaults(suiteName: "test")
        
        // in memory persistent container
        persistenContainer = setUpInMemoryNSPersistentContainer()
        
        // exercise store in test folder
        exerciseStore = ExerciseStore(customExercisesURL: testFolder.appendingPathComponent("custom_exercises.json"))
    }

    override func tearDownWithError() throws {
        persistenContainer.viewContext.reset()
        persistenContainer = nil
    }
    
    func testImportIronBackupV1() {
        let context = persistenContainer.viewContext
        
        let data = backupData(name: "v1")
        XCTAssertNoThrow(try IronBackup.restoreBackupData(data: data, managedObjectContext: context, exerciseStore: exerciseStore))
        
        let workoutRequest: NSFetchRequest<Workout> = Workout.fetchRequest()
        let workouts = try! context.fetch(workoutRequest)
        XCTAssertEqual(workouts.count, 209) // sanity check
        
        XCTAssertEqual(exerciseStore.customExercises.count, 4) // sanity check
    }

    func testImportIronBackupV2() {
        let context = persistenContainer.viewContext
        
        let data = backupData(name: "v2")
        XCTAssertNoThrow(try IronBackup.restoreBackupData(data: data, managedObjectContext: context, exerciseStore: exerciseStore))
        
        let workoutRequest: NSFetchRequest<Workout> = Workout.fetchRequest()
        let workouts = try! context.fetch(workoutRequest)
        XCTAssertEqual(workouts.count, 246) // sanity check
        
        XCTAssertEqual(exerciseStore.customExercises.count, 5) // sanity check
    }
    
    func testImportIronBackupV3() {
        let context = persistenContainer.viewContext

        let data = backupData(name: "v3")
        XCTAssertNoThrow(try IronBackup.restoreBackupData(data: data, managedObjectContext: context, exerciseStore: exerciseStore))

        let workoutRequest: NSFetchRequest<Workout> = Workout.fetchRequest()
        let workouts = try! context.fetch(workoutRequest)
        XCTAssertEqual(workouts.count, 246) // sanity check
        
        let workoutPlanRequest: NSFetchRequest<WorkoutPlan> = WorkoutPlan.fetchRequest()
        let workoutPlans = try! context.fetch(workoutPlanRequest)
        XCTAssertEqual(workoutPlans.count, 1) // sanity check
        
        XCTAssertEqual(exerciseStore.customExercises.count, 5) // sanity check
    }
    
    func testExportIronBackup() {
        let context = persistenContainer.viewContext
        createTestWorkoutData(context: context)
        try! context.save()
        
        XCTAssertNoThrow(try IronBackup.createBackupData(managedObjectContext: context, exerciseStore: exerciseStore))
    }

    func testBackupRestoresHistoryGraphWithoutSessionStateAndPreservesActiveSession() throws {
        let context = persistenContainer.viewContext
        let store = WorkoutOperationStore(coordinator: persistenContainer.persistentStoreCoordinator)
        func makeWorkout(title: String) -> Workout {
            let workout = Workout.create(context: context)
            workout.title = title
            workout.comment = "Workout metadata"
            workout.start = Date(timeIntervalSince1970: 1_800_000_000)
            workout.isCurrentWorkout = true
            for index in 0..<2 {
                let exercise = WorkoutExercise.create(context: context)
                exercise.exerciseUuid = UUID()
                exercise.comment = "Exercise \(index)"
                workout.addToWorkoutExercises(exercise)
                for setIndex in 0..<2 {
                    let set = WorkoutSet.create(context: context)
                    set.isCompleted = true
                    if setIndex == 1 { set.weightValue = 0; set.repetitionsValue = 0 }
                    set.comment = "Set metadata"
                    set.minTargetRepetitionsValue = 4
                    set.maxTargetRepetitionsValue = 8
                    exercise.addToWorkoutSets(set)
                }
            }
            return workout
        }
        let history = makeWorkout(title: "History")
        try context.save()
        let historyID = try XCTUnwrap(history.uuid)
        let historyOperation = WorkoutOperation(workoutID: historyID, expectedVersion: 0,
            mutation: .rest(start: Date(timeIntervalSince1970: 1_800_000_100), duration: 90))
        let historyReceipt = try store.apply(operation: historyOperation, mergingInto: context)
        XCTAssertEqual(historyReceipt.disposition, .applied)
        history.isCurrentWorkout = false
        history.end = history.start!.addingTimeInterval(600)
        let active = makeWorkout(title: "Active")
        try context.save()
        let activeID = try XCTUnwrap(active.uuid)
        let activeOperation = WorkoutOperation(workoutID: activeID, expectedVersion: 0,
            mutation: .rest(start: Date(timeIntervalSince1970: 1_800_000_200), duration: 120))
        let activeReceipt = try store.apply(operation: activeOperation, mergingInto: context)
        XCTAssertEqual(activeReceipt.disposition, .applied)
        let expectedHistory = try store.snapshot(workoutID: historyID)
        let expectedActive = try store.snapshot(workoutID: activeID)
        XCTAssertNotNil(expectedHistory.sessionID)
        XCTAssertFalse(expectedHistory.coveredOperationIDs.isEmpty)

        let data = try IronBackup.createBackupData(managedObjectContext: context, exerciseStore: exerciseStore)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["version"] as? Int, 3)
        XCTAssertEqual(Set(payload.keys), Set(["version", "date", "customExercises", "workoutPlans", "workouts"]))
        let exportedWorkouts = try XCTUnwrap(payload["workouts"] as? [[String: Any]])
        XCTAssertEqual(exportedWorkouts.count, 1)
        let forbidden: Set<String> = ["sessionID", "sessionId", "version", "coveredOperationIDs", "operationID",
            "originID", "sequence", "predecessorID", "restStart", "restDuration", "phase", "transport"]
        func checkGraphKeys(_ value: Any) {
            if let object = value as? [String: Any] {
                XCTAssertTrue(Set(object.keys).isDisjoint(with: forbidden))
                object.values.forEach(checkGraphKeys)
            } else if let array = value as? [Any] { array.forEach(checkGraphKeys) }
        }
        checkGraphKeys(exportedWorkouts)

        history.title = "Changed after export"
        try context.save()
        try IronBackup.restoreBackupData(data: data, managedObjectContext: context, exerciseStore: exerciseStore)
        try context.save()
        let restoredHistory = try store.snapshot(workoutID: historyID)
        XCTAssertEqual(restoredHistory.title, expectedHistory.title)
        XCTAssertEqual(restoredHistory.comment, expectedHistory.comment)
        XCTAssertEqual(restoredHistory.start, expectedHistory.start)
        XCTAssertEqual(restoredHistory.end, expectedHistory.end)
        XCTAssertEqual(restoredHistory.exercises, expectedHistory.exercises)
        XCTAssertFalse(restoredHistory.isCurrentWorkout)
        XCTAssertNil(restoredHistory.sessionID)
        XCTAssertEqual(restoredHistory.version, 0)
        XCTAssertTrue(restoredHistory.coveredOperationIDs.isEmpty)
        XCTAssertNil(restoredHistory.restStart)
        XCTAssertNil(restoredHistory.restDuration)
        XCTAssertEqual(try store.snapshot(workoutID: activeID), expectedActive)
        // A retry still resolves to the active session's original durable receipt.
        XCTAssertEqual(try store.apply(operation: activeOperation, mergingInto: context), activeReceipt)
        let allWorkouts = try context.fetch(Workout.fetchRequest())
        XCTAssertEqual(Set(allWorkouts.compactMap(\.uuid)), Set([historyID, activeID]))
    }

    func testBackupAndWorkoutJSONKeepCanonicalNamesAcrossLanguages() throws {
        let previousLanguage = WorkoutDataKit.L10n.language
        defer { WorkoutDataKit.L10n.language = previousLanguage }
        WorkoutDataKit.L10n.language = .english

        // Use a real version-3 backup containing workouts, plans and custom
        // exercises, so both nested exercise-reference encoders are exercised.
        let context = persistenContainer.viewContext
        try IronBackup.restoreBackupData(data: backupData(name: "v3"), managedObjectContext: context, exerciseStore: exerciseStore)
        try context.save()
        let workouts = try context.fetch(Workout.fetchRequest())
        let catalog = exerciseStore.exercises
        let expectedNames = Dictionary(uniqueKeysWithValues: catalog.map { ($0.uuid.uuidString, $0.title) })
        let builtIn = try XCTUnwrap(exerciseStore.builtInExercises.first)
        let englishTitle = builtIn.title
        let customNames = exerciseStore.customExercises.map { $0.title }
        XCTAssertFalse(customNames.isEmpty)

        func exportWorkouts() throws -> Data {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            encoder.userInfo[try XCTUnwrap(CodingUserInfoKey.exercisesKey)] = catalog
            return try encoder.encode(workouts)
        }

        let englishBackup = try IronBackup.createBackupData(managedObjectContext: context, exerciseStore: exerciseStore)
        let englishExport = try exportWorkouts()
        WorkoutDataKit.L10n.language = .polish
        XCTAssertNotEqual(builtIn.title, englishTitle, "The test must actually switch presentation language")
        XCTAssertEqual(exerciseStore.customExercises.map { $0.title }, customNames)
        let polishBackup = try IronBackup.createBackupData(managedObjectContext: context, exerciseStore: exerciseStore)
        let polishExport = try exportWorkouts()

        let englishObject = try XCTUnwrap(JSONSerialization.jsonObject(with: englishBackup) as? [String: Any])
        let polishObject = try XCTUnwrap(JSONSerialization.jsonObject(with: polishBackup) as? [String: Any])
        // Backup creation timestamps intentionally differ; all payload fields
        // including authored content and identifiers must remain identical.
        for key in ["version", "customExercises", "workoutPlans", "workouts"] {
            XCTAssertEqual(
                try JSONSerialization.data(withJSONObject: XCTUnwrap(englishObject[key]), options: [.sortedKeys, .fragmentsAllowed]),
                try JSONSerialization.data(withJSONObject: XCTUnwrap(polishObject[key]), options: [.sortedKeys, .fragmentsAllowed]), key)
        }
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: englishExport), options: [.sortedKeys]),
                       try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: polishExport), options: [.sortedKeys]))

        func checkReferences(_ value: Any) -> Int {
            if let object = value as? [String: Any] {
                var count = 0
                if let uuid = object["exerciseUuid"] as? String, let expected = expectedNames[uuid] {
                    XCTAssertEqual(object["exerciseName"] as? String, expected, uuid)
                    count += 1
                }
                return count + object.values.reduce(0) { $0 + checkReferences($1) }
            }
            return (value as? [Any])?.reduce(0) { $0 + checkReferences($1) } ?? 0
        }
        XCTAssertGreaterThan(checkReferences(try XCTUnwrap(polishObject["workouts"])), 0)
        XCTAssertGreaterThan(checkReferences(try XCTUnwrap(polishObject["workoutPlans"])), 0)
        XCTAssertGreaterThan(checkReferences(try JSONSerialization.jsonObject(with: polishExport)), 0)
    }
}

extension IronBackupTests {
    private func backupData(name: String) -> Data {
        let url = Bundle.init(for: Self.self).bundleURL.appendingPathComponent("iron_backups").appendingPathComponent(name).appendingPathExtension("ironbackup")
        precondition(FileManager.default.fileExists(atPath: url.path), "File \(url.path) does not exist")
        return try! Data(contentsOf: url)
    }
}
