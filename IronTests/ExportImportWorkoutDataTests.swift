//
//  ExportImportWorkoutDataTests.swift
//  IronTests
//
//  Created by Karim Abou Zeid on 26.10.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import XCTest
import CoreData
import WorkoutDataKit
@testable import Iron

class ExportImportWorkoutDataTests: XCTestCase {
    var persistenContainer: NSPersistentContainer!
    
    var encoder: JSONEncoder {
        guard let contextKey = CodingUserInfoKey.managedObjectContextKey else { fatalError() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.userInfo[contextKey] = persistenContainer.viewContext
        return encoder
    }
    
    var decoder: JSONDecoder {
        guard let contextKey = CodingUserInfoKey.managedObjectContextKey else { fatalError() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[contextKey] = persistenContainer.viewContext
        return decoder
    }

    override func setUp() {
        super.setUp()
        persistenContainer = setUpInMemoryNSPersistentContainer()
    }

    override func tearDown() {
        persistenContainer.viewContext.reset()
        persistenContainer = nil
        super.tearDown()
    }

    func testSetJSONPreservesMissingResultsAndLegacyScalars() throws {
        let context = persistenContainer.viewContext
        let missing = WorkoutSet.create(context: context)
        missing.isCompleted = true
        missing.comment = "No result"
        missing.minTargetRepetitionsValue = 4
        missing.maxTargetRepetitionsValue = 8
        let zero = WorkoutSet.create(context: context)
        zero.isCompleted = true
        zero.weightValue = 0
        zero.repetitionsValue = 0
        zero.rpeValue = 8
        zero.tagValue = .failure
        let data = try encoder.encode([missing, zero])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(payload[0]["weight"] as? Double, 0)
        XCTAssertEqual(payload[0]["repetitions"] as? Int, 0)
        XCTAssertEqual(payload[0]["weightWasNil"] as? Bool, true)
        XCTAssertEqual(payload[0]["repetitionsWereNil"] as? Bool, true)
        XCTAssertNil(payload[1]["weightWasNil"])
        XCTAssertNil(payload[1]["repetitionsWereNil"])

        let decoded = try decoder.decode([WorkoutSet].self, from: data)
        XCTAssertEqual(decoded.map(\.uuid), [missing.uuid, zero.uuid])
        XCTAssertNil(decoded[0].weight)
        XCTAssertNil(decoded[0].repetitions)
        XCTAssertEqual(decoded[0].comment, "No result")
        XCTAssertEqual(decoded[0].minTargetRepetitionsValue, 4)
        XCTAssertEqual(decoded[0].maxTargetRepetitionsValue, 8)
        XCTAssertEqual(decoded[1].weight?.doubleValue, 0)
        XCTAssertEqual(decoded[1].repetitions?.int16Value, 0)
        XCTAssertEqual(decoded[1].rpeValue, 8)
        XCTAssertEqual(decoded[1].tagValue, .failure)

        // Old payloads have no markers, and zero remains a supplied result.
        var legacy = payload[0]
        legacy.removeValue(forKey: "weightWasNil")
        legacy.removeValue(forKey: "repetitionsWereNil")
        let legacySet = try decoder.decode(WorkoutSet.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(legacySet.weight?.doubleValue, 0)
        XCTAssertEqual(legacySet.repetitions?.int16Value, 0)
    }

    func testWorkoutJSONPreservesOrderedStableGraphAndMetadata() throws {
        let context = persistenContainer.viewContext
        let workout = Workout.create(context: context)
        workout.start = Date(timeIntervalSince1970: 1_800_000_000)
        workout.end = workout.start!.addingTimeInterval(300)
        workout.title = "Authored title"
        workout.comment = "Authored comment"
        var exercises = [WorkoutExercise]()
        for _ in 0..<2 {
            let exercise = WorkoutExercise.create(context: context)
            exercise.exerciseUuid = UUID()
            exercise.comment = "Exercise comment"
            var sets = [WorkoutSet]()
            for index in 0..<2 {
                let set = WorkoutSet.create(context: context)
                set.isCompleted = true
                if index == 1 { set.weightValue = 0; set.repetitionsValue = 0 }
                set.comment = "Set comment"
                set.minTargetRepetitionsValue = 3
                set.maxTargetRepetitionsValue = 6
                sets.append(set)
            }
            exercise.workoutSets = NSOrderedSet(array: Array(sets.reversed()))
            exercises.append(exercise)
        }
        workout.workoutExercises = NSOrderedSet(array: Array(exercises.reversed()))
        try context.save()
        let decoded = try decoder.decode(Workout.self, from: encoder.encode(workout))
        XCTAssertEqual(decoded.uuid, workout.uuid)
        XCTAssertEqual(decoded.title, workout.title)
        XCTAssertEqual(decoded.comment, workout.comment)
        XCTAssertEqual(decoded.start, workout.start)
        XCTAssertEqual(decoded.end, workout.end)
        let originals = try XCTUnwrap(workout.workoutExercises?.array as? [WorkoutExercise])
        let restored = try XCTUnwrap(decoded.workoutExercises?.array as? [WorkoutExercise])
        XCTAssertEqual(restored.map(\.uuid), originals.map(\.uuid))
        for (before, after) in zip(originals, restored) {
            XCTAssertEqual(after.exerciseUuid, before.exerciseUuid)
            XCTAssertEqual(after.comment, before.comment)
            let beforeSets = try XCTUnwrap(before.workoutSets?.array as? [WorkoutSet])
            let afterSets = try XCTUnwrap(after.workoutSets?.array as? [WorkoutSet])
            XCTAssertEqual(afterSets.map(\.uuid), beforeSets.map(\.uuid))
            XCTAssertEqual(afterSets.map(WorkoutSetDraft.init(set:)), beforeSets.map(WorkoutSetDraft.init(set:)))
            XCTAssertEqual(afterSets.map(\.minTargetRepetitionsValue), beforeSets.map(\.minTargetRepetitionsValue))
            XCTAssertEqual(afterSets.map(\.maxTargetRepetitionsValue), beforeSets.map(\.maxTargetRepetitionsValue))
        }
    }

    func testReadWorkoutData() {
        let workoutDataUrl = Bundle.init(for: Self.self).bundleURL.appendingPathComponent("workout_data.json")
        precondition(FileManager.default.fileExists(atPath: workoutDataUrl.path))
        
        // check that start and end is not nil
        let workouts = try! decoder.decode([Workout].self, from: Data(contentsOf: workoutDataUrl))
        XCTAssertFalse(workouts.isEmpty)
        for workout in workouts {
            XCTAssertNotNil(workout.start)
            XCTAssertNotNil(workout.end)
            XCTAssertFalse(workout.isCurrentWorkout)
        }
        
        // check that workout is set
        let exercises = workouts.compactMap { $0.workoutExercises?.array.compactMap { $0 as? WorkoutExercise } }.flatMap { $0 }
        XCTAssertFalse(exercises.isEmpty)
        for exercise in exercises {
            XCTAssertNotNil(exercise.workout)
        }
        
        // check that workoutExercise is set
        let sets = exercises.compactMap { $0.workoutSets?.array.compactMap { $0 as? WorkoutSet } }.flatMap { $0 }
        XCTAssertFalse(sets.isEmpty)
        for set in sets {
            XCTAssertNotNil(set.workoutExercise)
            XCTAssert(set.isCompleted)
        }
        
        XCTAssertNoThrow(try persistenContainer.viewContext.save())
    }
    
    func testReadWorkoutDataStartEndMissing() {
        let workoutDataUrl = Bundle.init(for: Self.self).bundleURL.appendingPathComponent("workout_data_start_end_missing.json")
        precondition(FileManager.default.fileExists(atPath: workoutDataUrl.path))
        
        // cannot read if a workout doesn't have a start / end value
        XCTAssertThrowsError(try decoder.decode([Workout].self, from: Data(contentsOf: workoutDataUrl)))
    }
    
    func testExportWorkoutWithoutStartEnd() {
        let workout = Workout.create(context: persistenContainer.viewContext)
        // no start / end is set
        // encoding shouldn't crash but set safeStart and safeEnd
        let data = try! encoder.encode([workout])
        
        XCTAssertThrowsError(try persistenContainer.viewContext.save())
        persistenContainer.viewContext.delete(workout)
        XCTAssertNoThrow(try persistenContainer.viewContext.save())
        
        let workouts = try! decoder.decode([Workout].self, from: data)
        for workout in workouts {
            // decoded workouts must always have start end assigned
            XCTAssertNotNil(workout.start)
            XCTAssertNotNil(workout.end)
        }
        
        XCTAssertNoThrow(try persistenContainer.viewContext.save())
    }
}
