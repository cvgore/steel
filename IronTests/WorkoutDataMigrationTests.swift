//
//  WorkoutDataMigrationTests.swift
//  IronTests
//
//  Created by Karim Abou Zeid on 26.03.20.
//  Copyright © 2020 Karim Abou Zeid Software. All rights reserved.
//

import XCTest
import CoreData
@testable import WorkoutDataKit

class WorkoutDataMigrationTests: XCTestCase {
    var testFolder: URL!
    var storeURL: URL!
    var persistentContainer: NSPersistentContainer!
    let exerciseStore = ExerciseStore(customExercisesURL: nil)
    
    override func setUpWithError() throws {
        testFolder = FileManager.default.temporaryDirectory.appendingPathComponent("test", isDirectory: true)
        storeURL = testFolder.appendingPathComponent("WorkoutData").appendingPathExtension("sqlite")
        try createCleanTestFolder()
        
        persistentContainer = NSPersistentContainer(name: "WorkoutData", managedObjectModel: WorkoutDataStorage.model)
    }
    
    override func tearDownWithError() throws {
        persistentContainer.viewContext.reset()
        for store in persistentContainer.persistentStoreCoordinator.persistentStores {
            try persistentContainer.persistentStoreCoordinator.remove(store)
        }
        try wipeTestFolder()
    }
    
    func testMigrateFromV4PreservesGraphAndOptionalMetadata() throws { try autoreleasepool { try assertAdditiveMigration(version: 4) } }
    func testMigrateFromV5PreservesLegacyOperationRetryAndGraph() throws { try autoreleasepool { try assertAdditiveMigration(version: 5) } }
    private func assertAdditiveMigration(version: Int) throws {
        let bundle = Bundle(for: WorkoutDataStorage.self)
        let directory = try XCTUnwrap(bundle.url(forResource: "WorkoutData", withExtension: "momd"))
        let oldModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: directory.appendingPathComponent("WorkoutData v\(version).mom")))
        let legacy = NSPersistentContainer(name: "WorkoutData", managedObjectModel: oldModel)
        let description = NSPersistentStoreDescription(url: storeURL)
        description.shouldAddStoreAsynchronously = false
        legacy.persistentStoreDescriptions = [description]
        var loadingError: Error?
        legacy.loadPersistentStores { _, error in loadingError = error }
        if let error = loadingError { throw error }
        let context = legacy.viewContext
        let workoutID = UUID(), exerciseID = UUID(), setID = UUID(), catalogID = UUID()
        let workout = NSEntityDescription.insertNewObject(forEntityName: "Workout", into: context)
        workout.setValue(workoutID, forKey: "uuid")
        workout.setValue(Date(timeIntervalSince1970: 1_700_000_000), forKey: "start")
        workout.setValue(true, forKey: "isCurrentWorkout")
        workout.setValue("Existing workout", forKey: "title")
        let exercise = NSEntityDescription.insertNewObject(forEntityName: "WorkoutExercise", into: context)
        exercise.setValue(exerciseID, forKey: "uuid")
        exercise.setValue(catalogID, forKey: "exerciseUuid")
        exercise.setValue(workout, forKey: "workout")
        let set = NSEntityDescription.insertNewObject(forEntityName: "WorkoutSet", into: context)
        set.setValue(setID, forKey: "uuid")
        set.setValue(exercise, forKey: "workoutExercise")
        set.setValue(8, forKey: "maxTargetRepetitions")
        set.setValue("Keep metadata", forKey: "comment")
        let sessionID = UUID(), operationID = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let legacyOperation = WorkoutOperation(id: operationID, workoutID: workoutID, exerciseID: exerciseID,
            setID: setID, expectedVersion: 0, draft: .init(weight: nil, repetitions: nil, tag: nil, rpe: 0, comment: "Keep metadata"), date: date, restDuration: 90)
        if version == 5 {
            set.setValue(true, forKey: "isCompleted")
            let session = NSEntityDescription.insertNewObject(forEntityName: "WorkoutSessionState", into: context)
            session.setValue(workoutID, forKey: "workoutID"); session.setValue(sessionID, forKey: "sessionID")
            session.setValue(1, forKey: "version"); session.setValue(date, forKey: "restStart"); session.setValue(90, forKey: "restDuration")
            let payload: [String: Any] = ["id": operationID.uuidString, "workoutID": workoutID.uuidString,
                "exerciseID": exerciseID.uuidString, "setID": setID.uuidString, "expectedVersion": 0,
                "draft": ["rpe": 0, "comment": "Keep metadata"], "date": date.timeIntervalSinceReferenceDate, "restDuration": 90]
            let receipt: [String: Any] = ["operationID": operationID.uuidString, "sessionID": sessionID.uuidString,
                "version": 1, "didComplete": true, "restStart": date.timeIntervalSinceReferenceDate, "restDuration": 90]
            let row = NSEntityDescription.insertNewObject(forEntityName: "WorkoutAppliedOperation", into: context)
            row.setValue(operationID, forKey: "operationID")
            row.setValue(try JSONSerialization.data(withJSONObject: payload), forKey: "payload")
            row.setValue(try JSONSerialization.data(withJSONObject: receipt), forKey: "receipt")
        }
        try context.save()
        context.reset()
        for store in legacy.persistentStoreCoordinator.persistentStores {
            try legacy.persistentStoreCoordinator.remove(store)
        }
        try WorkoutDataStorage.prepareSessionMigration(description)
        persistentContainer.persistentStoreDescriptions = [description]
        persistentContainer.loadPersistentStores { _, error in loadingError = error }
        if let error = loadingError { throw error }
        let snapshot = try WorkoutOperationStore(coordinator: persistentContainer.persistentStoreCoordinator).snapshot(workoutID: workoutID)
        XCTAssertEqual(snapshot.title, "Existing workout")
        XCTAssertEqual(snapshot.exercises.map(\.id), [exerciseID])
        XCTAssertEqual(snapshot.exercises.first?.exerciseID, catalogID)
        let migrated = try XCTUnwrap(snapshot.exercises.first?.sets.first)
        XCTAssertEqual(migrated.id, setID)
        XCTAssertNil(migrated.result.weight)
        XCTAssertNil(migrated.result.repetitions)
        XCTAssertNil(migrated.minTargetRepetitions)
        XCTAssertEqual(migrated.maxTargetRepetitions, 8)
        XCTAssertEqual(migrated.result.comment, "Keep metadata")
        if version == 5 {
            XCTAssertEqual(snapshot.sessionID, sessionID)
            XCTAssertEqual(snapshot.version, 1)
            XCTAssertEqual(snapshot.phase, .local)
            XCTAssertEqual(snapshot.coveredOperationIDs, [operationID])
            let store = WorkoutOperationStore(coordinator: persistentContainer.persistentStoreCoordinator)
            let receipt = try store.apply(operation: legacyOperation)
            XCTAssertEqual(receipt.disposition, .applied)
            XCTAssertEqual(receipt.sessionID, sessionID)
            XCTAssertEqual(receipt.restStart, date)
            XCTAssertEqual(try store.snapshot(workoutID: workoutID), snapshot)
        } else {
            XCTAssertNil(snapshot.sessionID)
            XCTAssertEqual(snapshot.version, 0)
        }
    }

    func testMigrateFromV1() throws {
        try prepareMigrationTest(workoutData: "modelv1_ironv1.0.0")
        
        let expectation = XCTestExpectation(description: "Load persistent stores")
        persistentContainer.loadPersistentStores { (description, error) in
            XCTAssertNil(error)
            
            let workoutRequest: NSFetchRequest<Workout> = Workout.fetchRequest()
            let workouts = try! self.persistentContainer.viewContext.fetch(workoutRequest)
            XCTAssertEqual(workouts.count, 194) // sanity check
            
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 2)
    }
    
    func testMigrateFromV2() throws {
        try prepareMigrationTest(workoutData: "modelv2_ironv1.0.7")
        
        let expectation = XCTestExpectation(description: "Load persistent stores")
        persistentContainer.loadPersistentStores { (description, error) in
            XCTAssertNil(error)
            
            let workoutRequest: NSFetchRequest<Workout> = Workout.fetchRequest()
            let workouts = try! self.persistentContainer.viewContext.fetch(workoutRequest)
            XCTAssertEqual(workouts.count, 246) // sanity check
            
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 2)
    }
    
    func testMigrateFromV3() throws {
        try prepareMigrationTest(workoutData: "modelv3_ironv1.1.0")
        
        let expectation = XCTestExpectation(description: "Load persistent stores")
        persistentContainer.loadPersistentStores { (description, error) in
            XCTAssertNil(error)
            
            let workoutRequest: NSFetchRequest<Workout> = Workout.fetchRequest()
            let workouts = try! self.persistentContainer.viewContext.fetch(workoutRequest)
            XCTAssertEqual(workouts.count, 246) // sanity check
            
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 2)
    }
}

extension WorkoutDataMigrationTests {
    func prepareMigrationTest(workoutData: String) throws {
        // sanity check that we have a fresh copy of the database
        precondition(!FileManager.default.fileExists(atPath: storeURL.path))
        try! copyWorkoutData(name: workoutData)
        precondition(FileManager.default.fileExists(atPath: storeURL.path))
        
        // sanity check that the store files need migration
        let metadata = try! NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: storeURL, options: nil)
        precondition(WorkoutDataStorage.model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) == false)
        
        let description = NSPersistentStoreDescription(url: storeURL)
        description.shouldMigrateStoreAutomatically = true
        // Historical explicit mappings run first; the additive v4 → current step is inferred.
        try WorkoutDataStorage.prepareSessionMigration(description)
        description.shouldInferMappingModelAutomatically = true
        persistentContainer.persistentStoreDescriptions = [description]
    }
}

extension WorkoutDataMigrationTests {
    func copyWorkoutData(name: String) throws {
        let url = Bundle.init(for: Self.self).bundleURL.appendingPathComponent("workout_data").appendingPathComponent(name)
        precondition(FileManager.default.fileExists(atPath: url.path), "File \(url.path) does not exist")
        let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        try contents.forEach { try FileManager.default.copyItem(at: $0, to: testFolder.appendingPathComponent($0.lastPathComponent)) }
    }
}

extension WorkoutDataMigrationTests {
    func wipeTestFolder() throws {
        if FileManager.default.fileExists(atPath: testFolder.path) {
            try FileManager.default.removeItem(at: testFolder)
        }
    }
    
    func createCleanTestFolder() throws {
        try wipeTestFolder()
        try FileManager.default.createDirectory(at: testFolder, withIntermediateDirectories: true)
    }
}
