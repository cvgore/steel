import XCTest
import CoreData
import WorkoutDataKit
@testable import Iron

final class WorkoutPhoneWriterTests: XCTestCase {
    private var container: NSPersistentContainer!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var context: NSManagedObjectContext { container.viewContext }

    override func setUpWithError() throws {
        container = setUpInMemoryNSPersistentContainer()
        defaultsName = "WorkoutPhoneWriterTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsName)
        context.reset()
        container = nil
    }

    private func activeWorkout() throws -> (Workout, WorkoutExercise, WorkoutSet) {
        let workout = Workout.create(context: context)
        workout.isCurrentWorkout = true
        workout.title = "Original"
        workout.start = Date(timeIntervalSince1970: 1_800_000_000)
        let exercise = WorkoutExercise.create(context: context)
        workout.addToWorkoutExercises(exercise)
        let set = WorkoutSet.create(context: context)
        exercise.addToWorkoutSets(set)
        try context.save()
        return (workout, exercise, set)
    }

    private func timer() -> RestTimerStore {
        RestTimerStore(userDefaults: defaults, contextProvider: { [unowned self] in self.context },
                       enableEffects: false, observeLifecycle: false)
    }

    func testExistingWeightUnitsDefaultsAndCommandValuesStayCanonical() throws {
        XCTAssertEqual(WeightUnit.metric.barbellWeight, 20)
        XCTAssertEqual(WeightUnit.imperial.barbellWeight, 45)
        XCTAssertEqual(WeightUnit.metric.barbellIncrement, 2.5)
        XCTAssertEqual(WeightUnit.imperial.barbellIncrement, 5)
        XCTAssertEqual(WorkoutEditingRules.defaultRepetitions, 5)
        XCTAssertEqual(WeightUnit.convert(weight: 20, from: .metric, to: .imperial), 44.0924524, accuracy: 0.0001)
        let (workout, exercise, set) = try activeWorkout()
        let canonical = WeightUnit.convert(weight: 45, from: .imperial, to: .metric)
        try WorkoutCommandWriter(context: context).write(workout: workout,
            mutation: .saveSet(exerciseID: XCTUnwrap(exercise.uuid), setID: XCTUnwrap(set.uuid),
                draft: .init(weight: canonical, repetitions: WorkoutEditingRules.defaultRepetitions, tag: nil, rpe: 0, comment: nil), complete: true, restDuration: 90))
        XCTAssertEqual(set.weightValue, 20.41164, accuracy: 0.0000001)
        XCTAssertEqual(set.repetitionsValue, 5)
        XCTAssertEqual(WeightUnit.convert(weight: set.weightValue, from: .metric, to: .imperial), 45, accuracy: 0.000001)
    }

    func testAppliedPhoneCommitPublishesContextOperationAndReceiptOnlyOnSuccess() throws {
        let (workout, _, _) = try activeWorkout()
        let writer = WorkoutCommandWriter(context: context)
        var commits = [WorkoutCommandWriter.Commit]()
        let observer = NotificationCenter.default.addObserver(forName: WorkoutCommandWriter.didCommit,
            object: context, queue: nil) { notification in
                XCTAssertTrue((notification.object as? NSManagedObjectContext) === self.context)
                if let commit = notification.userInfo?["commit"] as? WorkoutCommandWriter.Commit { commits.append(commit) }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        let operation = WorkoutOperation(workoutID: try XCTUnwrap(workout.uuid), expectedVersion: 0,
            mutation: .workoutMetadata(title: "Committed", comment: nil))
        let receipt = try writer.apply(operation)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.operation, operation)
        XCTAssertEqual(commits.first?.receipt, receipt)
        XCTAssertThrowsError(try writer.write(workout: workout,
            mutation: .workoutMetadata(title: "Stale", comment: nil), expectedVersion: 0))
        XCTAssertEqual(commits.count, 1)
    }

    func testSelectedDraftCanFollowLocalRestThenCompleteWithoutLosingDraft() throws {
        let (workout, exercise, set) = try activeWorkout()
        let writer = WorkoutCommandWriter(context: context)
        let base = try writer.snapshot(workout: workout)
        let operation = WorkoutOperation(workoutID: base.workoutID, expectedVersion: base.version,
            mutation: .rest(start: Date(timeIntervalSince1970: 1_000), duration: 90))
        let receipt = try writer.apply(operation)
        let next = try XCTUnwrap(WorkoutDraftRevision(version: base.version, sessionID: base.sessionID)
            .following(.init(operation: operation, receipt: receipt), workoutID: base.workoutID,
                       exerciseID: XCTUnwrap(exercise.uuid), setID: XCTUnwrap(set.uuid)))
        let draft = WorkoutSetDraft(weight: 42, repetitions: 6, tag: nil, rpe: 0, comment: "Draft survived rest")
        try writer.write(workout: workout, mutation: .saveSet(exerciseID: XCTUnwrap(exercise.uuid),
            setID: XCTUnwrap(set.uuid), draft: draft, complete: true, restDuration: 90), expectedVersion: next.version)
        XCTAssertTrue(set.isCompleted)
        XCTAssertEqual(set.weightValue, 42)
        XCTAssertEqual(set.comment, draft.comment)
    }

    func testRemoteChangeThenLocalRestCannotAdvanceStaleSelectedDraft() throws {
        let (workout, exercise, set) = try activeWorkout()
        let writer = WorkoutCommandWriter(context: context)
        let store = WorkoutOperationStore(coordinator: container.persistentStoreCoordinator)
        let joining = try store.beginJoining(workoutID: XCTUnwrap(workout.uuid), mergingInto: context)
        try store.recordSessionAgreement(workoutID: XCTUnwrap(workout.uuid), sessionID: XCTUnwrap(joining.sessionID),
                                         phase: .agreed, mergingInto: context)
        let base = try writer.snapshot(workout: workout)
        let remote = WorkoutOperation(workoutID: base.workoutID, sessionID: base.sessionID, originID: "watch", sequence: 1,
            expectedVersion: base.version,
            mutation: .exerciseComment(exerciseID: try XCTUnwrap(exercise.uuid), comment: "Remote update"))
        var phoneNotifications = 0
        let observer = NotificationCenter.default.addObserver(forName: WorkoutCommandWriter.didCommit,
            object: context, queue: nil) { _ in phoneNotifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let remoteReceipt = try writer.apply(remote)
        XCTAssertEqual(remoteReceipt.disposition, .applied)
        XCTAssertEqual(phoneNotifications, 0)
        let current = try writer.snapshot(workout: workout)
        let local = WorkoutOperation(workoutID: base.workoutID, sessionID: current.sessionID, expectedVersion: current.version,
            mutation: .rest(start: Date(timeIntervalSince1970: 2_000), duration: 120))
        let receipt = try writer.apply(local)
        XCTAssertNil(WorkoutDraftRevision(version: base.version, sessionID: base.sessionID)
            .following(.init(operation: local, receipt: receipt), workoutID: base.workoutID,
                       exerciseID: try XCTUnwrap(exercise.uuid), setID: try XCTUnwrap(set.uuid)))
        XCTAssertThrowsError(try writer.write(workout: workout, mutation: .saveSet(exerciseID: XCTUnwrap(exercise.uuid),
            setID: XCTUnwrap(set.uuid), draft: .empty, complete: true, restDuration: 90), expectedVersion: base.version))
        XCTAssertFalse(set.isCompleted)
    }

    func testSelectedDraftDoesNotFollowChangesToItsResultOrDeletion() throws {
        let workoutID = UUID(), exerciseID = UUID(), setID = UUID(), sessionID = UUID()
        let revision = WorkoutDraftRevision(version: 4, sessionID: sessionID)
        let mutations: [WorkoutMutation] = [
            .saveSet(exerciseID: exerciseID, setID: setID, draft: .empty, complete: true, restDuration: 90),
            .removeSets(exerciseID: exerciseID, setIDs: [setID]), .removeExercises([exerciseID])]
        for mutation in mutations {
            let operation = WorkoutOperation(workoutID: workoutID, sessionID: sessionID, expectedVersion: 4, mutation: mutation)
            let receipt = WorkoutOperationReceipt(operationID: operation.id, sessionID: sessionID, version: 5,
                didComplete: false, restStart: nil, restDuration: nil)
            XCTAssertNil(revision.following(.init(operation: operation, receipt: receipt),
                workoutID: workoutID, exerciseID: exerciseID, setID: setID))
        }
    }

    func testWorkoutTimeChangeUsesBoundaryAndKeepsSelectedDraftUsable() throws {
        let (workout, exercise, set) = try activeWorkout()
        let writer = WorkoutCommandWriter(context: context)
        let base = try writer.snapshot(workout: workout)
        let newStart = try XCTUnwrap(base.start).addingTimeInterval(-120)
        let pause = newStart.addingTimeInterval(60)
        let operation = WorkoutOperation(workoutID: base.workoutID, sessionID: base.sessionID,
            expectedVersion: base.version, mutation: .workoutTime(start: newStart, end: pause))
        let receipt = try writer.apply(operation)
        XCTAssertFalse(receipt.didComplete)
        XCTAssertTrue(workout.isCurrentWorkout)
        XCTAssertEqual(workout.start, newStart)
        XCTAssertEqual(workout.end, pause)
        XCTAssertFalse(context.hasChanges)
        let saved = try writer.snapshot(workout: workout)
        XCTAssertEqual(saved.start, newStart)
        XCTAssertEqual(saved.end, pause)
        let revision = try XCTUnwrap(WorkoutDraftRevision(version: base.version, sessionID: base.sessionID)
            .following(.init(operation: operation, receipt: receipt), workoutID: base.workoutID,
                exerciseID: XCTUnwrap(exercise.uuid), setID: XCTUnwrap(set.uuid)))
        XCTAssertEqual(revision.version, receipt.version)
        XCTAssertThrowsError(try writer.write(workout: workout,
            mutation: .workoutTime(start: pause.addingTimeInterval(1), end: pause)))
        XCTAssertEqual(try writer.snapshot(workout: workout), saved)
        try writer.write(workout: workout, mutation: .workoutTime(start: newStart, end: nil))
        XCTAssertNil(workout.end)
        XCTAssertTrue(workout.isCurrentWorkout)
    }

    func testStaleMetadataDraftCannotOverwriteCommittedChange() throws {
        let (workout, _, _) = try activeWorkout()
        let writer = WorkoutCommandWriter(context: context)
        let base = try writer.snapshot(workout: workout)
        let draft = "Local draft"
        try writer.write(workout: workout, mutation: .workoutMetadata(title: "Remote title", comment: "Remote comment"))
        XCTAssertThrowsError(try writer.write(workout: workout,
            mutation: .workoutMetadata(title: draft, comment: base.comment), expectedVersion: base.version))
        XCTAssertEqual(draft, "Local draft")
        XCTAssertEqual(workout.title, "Remote title")
        XCTAssertEqual(workout.comment, "Remote comment")
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try writer.snapshot(workout: workout).title, "Remote title")
    }

    func testReorderUsingCapturedVersionCannotUndoConcurrentOrder() throws {
        let (workout, first, _) = try activeWorkout()
        let second = WorkoutExercise.create(context: context)
        workout.addToWorkoutExercises(second)
        try context.save()
        let writer = WorkoutCommandWriter(context: context)
        let base = try writer.snapshot(workout: workout)
        let firstID = try XCTUnwrap(first.uuid)
        let secondID = try XCTUnwrap(second.uuid)
        try writer.write(workout: workout, mutation: .reorderExercises([secondID, firstID]), expectedVersion: base.version)
        XCTAssertThrowsError(try writer.write(workout: workout,
            mutation: .reorderExercises(base.exercises.map(\.id)), expectedVersion: base.version))
        XCTAssertEqual(try writer.snapshot(workout: workout).exercises.map(\.id), [secondID, firstID])
        XCTAssertEqual((workout.workoutExercises?.array as? [WorkoutExercise])?.compactMap(\.uuid), [secondID, firstID])
    }

    func testRejectedSetSaveLeavesManagedFieldsAndDurableResultUnchanged() throws {
        let (workout, exercise, set) = try activeWorkout()
        let writer = WorkoutCommandWriter(context: context)
        let before = try writer.snapshot(workout: workout)
        let draft = WorkoutSetDraft(weight: WorkoutEditingRules.maximumWeight + 1,
            repetitions: 5, tag: nil, rpe: 0, comment: "Unsaved draft")
        XCTAssertThrowsError(try writer.write(workout: workout,
            mutation: .saveSet(exerciseID: XCTUnwrap(exercise.uuid), setID: XCTUnwrap(set.uuid),
                               draft: draft, complete: true, restDuration: 90)))
        XCTAssertNil(set.weight)
        XCTAssertNil(set.repetitions)
        XCTAssertNil(set.comment)
        XCTAssertFalse(set.isCompleted)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try writer.snapshot(workout: workout), before)
    }

    func testExpiredDurableRestRestoresOriginalAbsoluteInterval() throws {
        let (workout, _, _) = try activeWorkout()
        let expiredStart = Date(timeIntervalSince1970: 1_000)
        try WorkoutCommandWriter(context: context).write(workout: workout,
            mutation: .rest(start: expiredStart, duration: 90))
        defaults.restTimerStart = Date()
        defaults.restTimerDuration = 300
        let timer = timer()
        timer.restoreCommittedRest()
        XCTAssertEqual(timer.restTimerStart, expiredStart)
        XCTAssertEqual(timer.restTimerDuration, 90)
        XCTAssertEqual(timer.restTimerEnd, expiredStart.addingTimeInterval(90))
        XCTAssertFalse(timer.operationError)
    }

    func testDurableCancellationClearsStaleDefaultsAfterRestore() throws {
        let (workout, _, _) = try activeWorkout()
        try WorkoutCommandWriter(context: context).write(workout: workout, mutation: .rest(start: nil, duration: nil))
        defaults.restTimerStart = Date(timeIntervalSince1970: 1_000)
        defaults.restTimerDuration = 90
        let timer = timer()
        timer.restoreCommittedRest()
        XCTAssertNil(timer.restTimerStart)
        XCTAssertNil(timer.restTimerDuration)
        XCTAssertNil(timer.restTimerEnd)
    }

    func testManualTimerWithoutActiveWorkoutUsesDefaults() throws {
        let timer = timer()
        let start = Date(timeIntervalSince1970: 2_000)
        XCTAssertTrue(timer.setRest(start: start, duration: 120))
        timer.restoreCommittedRest()
        XCTAssertEqual(timer.restTimerStart, start)
        XCTAssertEqual(timer.restTimerDuration, 120)
        XCTAssertFalse(timer.operationError)
        timer.cancel()
        XCTAssertNil(timer.restTimerStart)
        XCTAssertNil(timer.restTimerDuration)
    }

    func testRestActionBasedOnStalePresentationDoesNotOverwriteRemoteRest() throws {
        let (workout, _, _) = try activeWorkout()
        let writer = WorkoutCommandWriter(context: context)
        let start = Date(timeIntervalSince1970: 3_000)
        try writer.write(workout: workout, mutation: .rest(start: start, duration: 90))
        let timer = timer()
        timer.restoreCommittedRest()
        try writer.write(workout: workout, mutation: .rest(start: start, duration: 180))
        XCTAssertFalse(timer.setRest(start: timer.restTimerStart, duration: 100))
        XCTAssertTrue(timer.operationError)
        XCTAssertEqual(timer.restTimerDuration, 180)
        XCTAssertEqual(try writer.snapshot(workout: workout).restDuration, 180)
        XCTAssertTrue(timer.setRest(start: timer.restTimerStart, duration: 190))
        XCTAssertEqual(try writer.snapshot(workout: workout).restDuration, 190)
    }
}
