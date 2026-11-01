import XCTest
import CoreData
@testable import WorkoutDataKit

final class WorkoutOperationStoreTests: XCTestCase {
    private var directory: URL!
    private var container: NSPersistentContainer!
    private var workout: Workout!
    private var exercise: WorkoutExercise!
    private var set: WorkoutSet!
    private var otherExerciseID: UUID!
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = try open()
        let context = container.viewContext
        workout = Workout.create(context: context)
        workout.isCurrentWorkout = true
        workout.title = "Original"
        let begun = WorkoutExercise.create(context: context)
        begun.workout = workout
        otherExerciseID = begun.uuid
        let completed = WorkoutSet.create(context: context)
        completed.workoutExercise = begun
        completed.isCompleted = true
        completed.weightValue = 10
        completed.repetitionsValue = 5
        workout.start = date.addingTimeInterval(-60)
        exercise = WorkoutExercise.create(context: context)
        exercise.workout = workout
        exercise.comment = "Exercise metadata"
        set = WorkoutSet.create(context: context)
        set.workoutExercise = exercise
        set.minTargetRepetitionsValue = 4
        set.maxTargetRepetitionsValue = 8
        try context.save()
    }

    override func tearDownWithError() throws {
        workout = nil; exercise = nil; set = nil
        if let container = container {
            container.viewContext.reset()
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        }
        container = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func open() throws -> NSPersistentContainer {
        let result = NSPersistentContainer(name: "WorkoutData", managedObjectModel: WorkoutDataStorage.model)
        let description = NSPersistentStoreDescription(url: directory.appendingPathComponent("test.sqlite"))
        description.shouldAddStoreAsynchronously = false
        result.persistentStoreDescriptions = [description]
        var failure: Error?
        result.loadPersistentStores { _, error in failure = error }
        if let failure = failure { throw failure }
        return result
    }

    private var store: WorkoutOperationStore { WorkoutOperationStore(coordinator: container.persistentStoreCoordinator) }
    private func operation(version: Int64 = 0, id: UUID = UUID(), draft: WorkoutSetDraft? = nil) -> WorkoutOperation {
        WorkoutOperation(id: id, workoutID: workout.uuid!, exerciseID: exercise.uuid!, setID: set.uuid!,
            expectedVersion: version, draft: draft ?? WorkoutSetDraft(weight: 42.5, repetitions: 6, tag: "failure", rpe: 8, comment: "Result"),
            date: date, restDuration: 90)
    }

    func testAtomicCompletionAndReceiptSurviveReopen() throws {
        // Put the selected exercise before the begun exercise to prove the ordering rule.
        workout.removeFromWorkoutExercises(exercise)
        workout.insertIntoWorkoutExercises(exercise, at: 0)
        try container.viewContext.save()
        let op = operation()
        let receipt = try store.apply(operation: op, mergingInto: container.viewContext)
        XCTAssertTrue(receipt.didComplete)
        XCTAssertTrue(set.isCompleted)
        XCTAssertEqual(set.weightValue, 42.5)
        let reopened = try open()
        defer { for store in reopened.persistentStoreCoordinator.persistentStores { try? reopened.persistentStoreCoordinator.remove(store) } }
        let durable = WorkoutOperationStore(coordinator: reopened.persistentStoreCoordinator)
        let snapshot = try durable.snapshot(workoutID: op.workoutID)
        XCTAssertEqual(snapshot.version, 1)
        XCTAssertEqual(snapshot.sessionID, receipt.sessionID)
        XCTAssertEqual(snapshot.restStart, date)
        XCTAssertEqual(snapshot.restDuration, 90)
        XCTAssertEqual(snapshot.exercises.map(\.id), [otherExerciseID!, op.exerciseID!])
        let result = try XCTUnwrap(snapshot.exercises.last?.sets.first)
        XCTAssertEqual(result.id, op.setID)
        XCTAssertEqual(result.result, op.draft)
        XCTAssertTrue(result.isCompleted)
        XCTAssertEqual(result.minTargetRepetitions, 4)
        XCTAssertEqual(result.maxTargetRepetitions, 8)
        XCTAssertEqual(snapshot.exercises.last?.comment, "Exercise metadata")
        XCTAssertEqual(try durable.apply(operation: op), receipt)
        XCTAssertEqual(try durable.snapshot(workoutID: op.workoutID), snapshot)
    }

    func testFailureRollsBackGraphOrderRestAndReceiptAndAllowsRetry() throws {
        let op = operation()
        let before = try store.snapshot(workoutID: op.workoutID)
        enum Failure: Error { case save }
        let failing = WorkoutOperationStore(coordinator: container.persistentStoreCoordinator, beforeSave: { _ in throw Failure.save })
        XCTAssertThrowsError(try failing.apply(operation: op, mergingInto: container.viewContext))
        XCTAssertFalse(set.isCompleted)
        XCTAssertEqual(try store.snapshot(workoutID: op.workoutID), before)
        XCTAssertEqual(try store.apply(operation: op).version, 1)
    }

    func testRealValidationFailureDoesNotPersistPartialOperation() throws {
        let op = operation()
        let before = try store.snapshot(workoutID: op.workoutID)
        let failing = WorkoutOperationStore(coordinator: container.persistentStoreCoordinator, beforeSave: { context in
            let records = try context.fetch(WorkoutSet.fetchRequest())
            records.first?.weight = -1
        })
        XCTAssertThrowsError(try failing.apply(operation: op))
        XCTAssertEqual(try store.snapshot(workoutID: op.workoutID), before)
        XCTAssertEqual(try store.apply(operation: op).version, 1)
    }

    func testUnrelatedUnsavedUIChangesAreNotCommitted() throws {
        let op = operation()
        workout.title = "Unsaved title"
        _ = try store.apply(operation: op, mergingInto: container.viewContext)
        XCTAssertEqual(workout.title, "Unsaved title")
        XCTAssertTrue(container.viewContext.hasChanges)
        XCTAssertEqual(try store.snapshot(workoutID: op.workoutID).title, "Original")
        XCTAssertTrue(set.isCompleted)
    }

    func testCorrectionPreservesRestCompletionAndOrderAndOptionalValues() throws {
        let first = operation()
        _ = try store.apply(operation: first)
        let before = try store.snapshot(workoutID: first.workoutID)
        let draft = WorkoutSetDraft(weight: nil, repetitions: nil, tag: nil, rpe: 0, comment: nil)
        let receipt = try store.apply(operation: operation(version: 1, draft: draft))
        let after = try store.snapshot(workoutID: first.workoutID)
        XCTAssertFalse(receipt.didComplete)
        XCTAssertEqual(after.restStart, before.restStart)
        XCTAssertEqual(after.restDuration, before.restDuration)
        XCTAssertEqual(after.start, before.start)
        XCTAssertEqual(after.exercises.map(\.id), before.exercises.map(\.id))
        XCTAssertTrue(after.exercises.last!.sets.first!.isCompleted)
        XCTAssertEqual(after.exercises.last!.sets.first!.result, draft)
    }

    func testStaleVersionAndIDCollisionDoNotOverwriteResult() throws {
        let first = operation()
        _ = try store.apply(operation: first)
        let snapshot = try store.snapshot(workoutID: first.workoutID)
        let stale = operation()
        let receipt = try store.apply(operation: stale)
        XCTAssertEqual(receipt.disposition, .conflict)
        XCTAssertEqual(receipt.reason, .staleVersion)
        XCTAssertEqual(try store.operations(workoutID: first.workoutID, disposition: .conflict).first?.operation, stale)
        XCTAssertThrowsError(try store.apply(operation: operation(version: 1, id: first.id)))
        XCTAssertEqual(try store.snapshot(workoutID: first.workoutID), snapshot)
    }

    func testInvalidPayloadAndForeignParentLeaveNoSession() throws {
        for draft in [WorkoutSetDraft(weight: .infinity, repetitions: 5, tag: nil, rpe: 0, comment: nil),
                      WorkoutSetDraft(weight: 10, repetitions: -1, tag: nil, rpe: 0, comment: nil)] {
            XCTAssertThrowsError(try store.apply(operation: operation(draft: draft)))
        }
        let op = operation()
        let foreign = WorkoutOperation(workoutID: op.workoutID, exerciseID: otherExerciseID, setID: op.setID!,
            expectedVersion: 0, draft: op.draft!, restDuration: 90)
        XCTAssertThrowsError(try store.apply(operation: foreign))
        XCTAssertNil(try store.snapshot(workoutID: op.workoutID).sessionID)
    }

    func testTwoStoreInstancesCannotCommitTheSameBaseVersion() throws {
        let first = operation(), second = operation()
        let stores = [store, store]
        let operations = [first, second]
        let resultLock = NSLock()
        var successes = 0
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                let receipt = try stores[index].apply(operation: operations[index])
                resultLock.lock()
                if receipt.disposition == .applied { successes += 1 } else { failures += 1 }
                resultLock.unlock()
            } catch {
                resultLock.lock(); failures += 1; resultLock.unlock()
            }
        }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(try store.snapshot(workoutID: first.workoutID).version, 1)
    }

    private func joinedReplica() throws -> WorkoutReplicaStore {
        let joining = try store.beginJoining(workoutID: workout.uuid!)
        let replica = try WorkoutReplicaStore(url: directory.appendingPathComponent("watch.json"))
        try replica.adopt(snapshot: joining)
        let agreement = try store.recordSessionAgreement(workoutID: workout.uuid!, sessionID: joining.sessionID!, phase: .agreed)
        try replica.adopt(snapshot: agreement)
        try replica.agree(sessionID: joining.sessionID!)
        return replica
    }

    func testTwoDurableStoresOfflineChainOutOfOrderRestartLostReceiptsAndCoverage() throws {
        let replica = try joinedReplica()
        let base = try store.snapshot(workoutID: workout.uuid!)
        let first = try replica.submit(.saveSet(exerciseID: exercise.uuid!, setID: set.uuid!,
            draft: .init(weight: 50, repetitions: 6, tag: nil, rpe: 8, comment: nil), complete: true, restDuration: 90), date: date)
        let second = try replica.submit(.saveSet(exerciseID: exercise.uuid!, setID: set.uuid!,
            draft: .init(weight: 52, repetitions: 7, tag: "failure", rpe: 9, comment: "Offline correction"), complete: true, restDuration: 999), date: date.addingTimeInterval(30))
        let reopenedWatch = try WorkoutReplicaStore(url: directory.appendingPathComponent("watch.json"))
        XCTAssertEqual(reopenedWatch.pendingOperations, [first, second])
        let waiting = try store.apply(operation: second)
        XCTAssertEqual(waiting.disposition, .waitingForPredecessor)
        XCTAssertEqual(try store.snapshot(workoutID: workout.uuid!).version, base.version)
        let receipt1 = try store.apply(operation: first)
        XCTAssertEqual(receipt1.disposition, .applied)
        let intermediate = try store.snapshot(workoutID: workout.uuid!)
        try reopenedWatch.adopt(snapshot: intermediate)
        XCTAssertTrue(reopenedWatch.state.conflicts.isEmpty)
        XCTAssertEqual(reopenedWatch.snapshot?.exercises.last?.sets.first?.result.weight, 52)
        let reopenedPhone = try open()
        defer { for row in reopenedPhone.persistentStoreCoordinator.persistentStores { try? reopenedPhone.persistentStoreCoordinator.remove(row) } }
        let durablePhone = WorkoutOperationStore(coordinator: reopenedPhone.persistentStoreCoordinator)
        let receipt2 = try durablePhone.apply(operation: second)
        XCTAssertEqual(receipt2.disposition, .applied)
        XCTAssertFalse(receipt2.didComplete)
        XCTAssertEqual(receipt2.restStart, date)
        XCTAssertEqual(receipt2.restDuration, 90)
        XCTAssertEqual(try durablePhone.apply(operation: first), receipt1)
        XCTAssertEqual(try durablePhone.apply(operation: second), receipt2)
        try reopenedWatch.receive(receipt: receipt2)
        let final = try durablePhone.snapshot(workoutID: workout.uuid!)
        XCTAssertEqual(final.version, base.version + 2)
        XCTAssertEqual(Set(final.coveredOperationIDs), Set([first.id, second.id]))
        try reopenedWatch.adopt(snapshot: final)
        XCTAssertEqual(reopenedWatch.snapshot, final)
        XCTAssertEqual(reopenedWatch.pendingOperations, [first])
        try reopenedWatch.receive(receipt: receipt1)
        XCTAssertTrue(reopenedWatch.pendingOperations.isEmpty)
        XCTAssertEqual(try WorkoutReplicaStore(url: directory.appendingPathComponent("watch.json")).snapshot, final)
    }

    func testConcurrentPhoneCorrectionRetainsWatchCandidateAndConflictedSuccessor() throws {
        let replica = try joinedReplica()
        let first = try replica.submit(.saveSet(exerciseID: exercise.uuid!, setID: set.uuid!,
            draft: .init(weight: 70, repetitions: 8, tag: nil, rpe: 8, comment: "Watch candidate"), complete: true, restDuration: 90))
        let second = try replica.submit(.requestFinish)
        let base = try store.snapshot(workoutID: workout.uuid!)
        let phone = WorkoutOperation(workoutID: workout.uuid!, expectedVersion: base.version,
            mutation: .saveSet(exerciseID: exercise.uuid!, setID: set.uuid!, draft: .init(weight: 60, repetitions: 5, tag: nil, rpe: 7, comment: "Phone accepted"), complete: true, restDuration: 45))
        _ = try store.apply(operation: phone)
        let receipt = try store.apply(operation: first)
        XCTAssertEqual(receipt.disposition, .conflict)
        XCTAssertEqual(receipt.reason, .staleVersion)
        let successor = try store.apply(operation: second)
        XCTAssertEqual(successor.disposition, .conflict)
        XCTAssertEqual(successor.reason, .predecessorConflict)
        XCTAssertEqual(try store.operations(workoutID: workout.uuid!, disposition: .conflict).map(\.operation).count, 2)
        XCTAssertEqual(try store.apply(operation: first), receipt)
        try replica.receive(receipt: receipt)
        try replica.adopt(snapshot: store.snapshot(workoutID: workout.uuid!))
        XCTAssertEqual(replica.state.acceptedSnapshot?.exercises.last?.sets.first?.result.weight, 60)
        XCTAssertEqual(replica.snapshot?.exercises.last?.sets.first?.result.weight, 70)
        XCTAssertFalse(replica.state.conflicts.isEmpty)
        let reopened = try WorkoutReplicaStore(url: directory.appendingPathComponent("watch.json"))
        XCTAssertEqual(reopened.state, replica.state)
        XCTAssertEqual(try store.snapshot(workoutID: workout.uuid!).phase, .agreed)
    }

    func testFinishRequestAndAgreementAreDurableAndDoNotFinalizeGraph() throws { try assertTerminal(.requestFinish) }
    func testCancelRequestAndAgreementAreDurableAndDoNotFinalizeGraph() throws { try assertTerminal(.requestCancel) }
    private func assertTerminal(_ mutation: WorkoutMutation) throws {
        let replica = try joinedReplica()
        let op = try replica.submit(mutation)
        let receipt = try store.apply(operation: op)
        XCTAssertEqual(receipt.disposition, .applied)
        try replica.receive(receipt: receipt)
        let pending = try store.snapshot(workoutID: workout.uuid!)
        XCTAssertTrue([WorkoutSessionPhase.pendingFinish, .pendingCancel].contains(pending.phase))
        XCTAssertTrue(pending.isCurrentWorkout)
        let target: WorkoutSessionPhase = pending.phase == .pendingFinish ? .finished : .cancelled
        let terminal = try store.recordSessionAgreement(workoutID: workout.uuid!, sessionID: pending.sessionID!, phase: target)
        XCTAssertTrue(terminal.phase.isTerminal)
        XCTAssertTrue(terminal.isCurrentWorkout, "STEEL-8 records agreement; STEEL-13 owns graph finalization")
        try replica.adopt(snapshot: terminal)
        XCTAssertFalse(replica.state.occupiesSharedSlot)
        XCTAssertThrowsError(try replica.submit(.requestFinish))
        XCTAssertThrowsError(try store.recordSessionAgreement(workoutID: workout.uuid!, sessionID: pending.sessionID!, phase: .agreed))
        XCTAssertEqual(try store.apply(operation: op), receipt)
    }

    func testStructureOrderMetadataAndRestUseTheSameDurableVersion() throws {
        let workoutID = workout.uuid!, addedExercise = UUID(), addedSet = UUID(), secondSet = UUID()
        func apply(_ mutation: WorkoutMutation) throws {
            let version = try store.snapshot(workoutID: workoutID).version
            let receipt = try store.apply(operation: WorkoutOperation(workoutID: workoutID, expectedVersion: version, mutation: mutation))
            XCTAssertEqual(receipt.disposition, .applied)
        }
        try apply(.addExercise(id: addedExercise, exerciseID: UUID(), sets: [.init(id: addedSet)]))
        try apply(.addSet(exerciseID: addedExercise, set: .init(id: secondSet, draft: .init(weight: nil, repetitions: 0, tag: nil, rpe: 0, comment: "nil vs zero"))))
        try apply(.reorderSets(exerciseID: addedExercise, setIDs: [secondSet, addedSet]))
        try apply(.reorderExercises([addedExercise, exercise.uuid!, otherExerciseID]))
        try apply(.exerciseComment(exerciseID: addedExercise, comment: "Comment"))
        try apply(.workoutMetadata(title: "Updated", comment: "Workout comment"))
        try apply(.rest(start: date.addingTimeInterval(-500), duration: 30))
        let snapshot = try store.snapshot(workoutID: workoutID)
        XCTAssertEqual(snapshot.version, 7)
        XCTAssertEqual(snapshot.exercises.first?.sets.map(\.id), [secondSet, addedSet])
        XCTAssertNil(snapshot.exercises.first?.sets.first?.result.weight)
        XCTAssertEqual(snapshot.exercises.first?.sets.first?.result.repetitions, 0)
        XCTAssertEqual(snapshot.exercises.first?.comment, "Comment")
        XCTAssertEqual(snapshot.title, "Updated")
        XCTAssertEqual(snapshot.restStart, date.addingTimeInterval(-500))
        try apply(.removeSets(exerciseID: addedExercise, setIDs: [addedSet]))
        try apply(.removeExercises([addedExercise]))
        XCTAssertEqual(try store.snapshot(workoutID: workoutID).exercises.count, 2)
        let invalid = WorkoutOperation(workoutID: workoutID, expectedVersion: 9, mutation: .reorderExercises([exercise.uuid!, exercise.uuid!]))
        XCTAssertThrowsError(try store.apply(operation: invalid))
        XCTAssertEqual(try store.snapshot(workoutID: workoutID).version, 9)
    }

    func testOfflineEditOfDeletedSetIsDurablyRetainedAsConflict() throws {
        let replica = try joinedReplica()
        let candidate = try replica.submit(.saveSet(exerciseID: exercise.uuid!, setID: set.uuid!,
            draft: .init(weight: 99, repetitions: 9, tag: nil, rpe: 9, comment: "Preserve deleted-target candidate"), complete: true, restDuration: 90))
        let base = try store.snapshot(workoutID: workout.uuid!)
        let removal = WorkoutOperation(workoutID: workout.uuid!, expectedVersion: base.version,
            mutation: .removeSets(exerciseID: exercise.uuid!, setIDs: [set.uuid!]))
        _ = try store.apply(operation: removal)
        let accepted = try store.snapshot(workoutID: workout.uuid!)
        let receipt = try store.apply(operation: candidate)
        XCTAssertEqual(receipt.disposition, .conflict)
        XCTAssertEqual(receipt.reason, .staleVersion)
        XCTAssertEqual(try store.snapshot(workoutID: workout.uuid!), accepted)
        let reopened = try open()
        defer { for row in reopened.persistentStoreCoordinator.persistentStores { try? reopened.persistentStoreCoordinator.remove(row) } }
        let conflicts = try WorkoutOperationStore(coordinator: reopened.persistentStoreCoordinator).operations(workoutID: workout.uuid!, disposition: .conflict)
        XCTAssertEqual(conflicts.map(\.operation), [candidate])
        try replica.receive(receipt: receipt)
        try replica.adopt(snapshot: accepted)
        XCTAssertEqual(replica.state.acceptedSnapshot, accepted)
        XCTAssertEqual(replica.snapshot?.exercises.last?.sets.first?.result.weight, 99)
    }

    func testOutOfOrderStructuralSuccessorWaitsForObjectsCreatedByPredecessor() throws {
        let id = UUID(), one = UUID(), two = UUID(), predecessorID = UUID()
        let create = WorkoutOperation(id: predecessorID, workoutID: workout.uuid!, originID: "phone", sequence: 1,
            expectedVersion: 0, mutation: .addExercise(id: id, exerciseID: UUID(), sets: [.init(id: one), .init(id: two)]))
        let reorder = WorkoutOperation(workoutID: workout.uuid!, originID: "phone", sequence: 2, predecessorID: predecessorID,
            expectedVersion: 0, mutation: .reorderSets(exerciseID: id, setIDs: [two, one]))
        XCTAssertEqual(try store.apply(operation: reorder).disposition, .waitingForPredecessor)
        XCTAssertEqual(try store.operations(workoutID: workout.uuid!, disposition: .waitingForPredecessor).first?.operation, reorder)
        XCTAssertEqual(try store.apply(operation: create).disposition, .applied)
        XCTAssertEqual(try store.apply(operation: reorder).disposition, .applied)
        XCTAssertEqual(try store.snapshot(workoutID: workout.uuid!).exercises.last?.sets.map(\.id), [two, one])
    }

    func testJoiningAgreementRetryAndUnresolvedSharedSlotCannotBeReplaced() throws {
        let joined = try store.beginJoining(workoutID: workout.uuid!)
        XCTAssertEqual(try store.beginJoining(workoutID: workout.uuid!), joined)
        let early = WorkoutOperation(workoutID: workout.uuid!, sessionID: joined.sessionID, originID: "watch", sequence: 1,
            expectedVersion: joined.version, mutation: .rest(start: date, duration: 90))
        XCTAssertEqual(try store.apply(operation: early).reason, .sessionUnavailable)
        let agreed = try store.recordSessionAgreement(workoutID: workout.uuid!, sessionID: joined.sessionID!, phase: .agreed)
        XCTAssertEqual(try store.recordSessionAgreement(workoutID: workout.uuid!, sessionID: joined.sessionID!, phase: .agreed), agreed)
        // Simulate a consumer replacing the graph without resolving its shared data slot.
        workout.isCurrentWorkout = false
        workout.end = date
        set.isCompleted = true
        let next = Workout.create(context: container.viewContext)
        next.isCurrentWorkout = true; next.start = date
        try container.viewContext.save()
        XCTAssertThrowsError(try store.beginJoining(workoutID: next.uuid!))
        XCTAssertEqual(try store.snapshot(workoutID: workout.uuid!).phase, .agreed)
    }

    func testUnresolvedConflictPreventsTerminalAgreement() throws {
        _ = try joinedReplica()
        let initial = try store.snapshot(workoutID: workout.uuid!)
        let rest = WorkoutOperation(workoutID: workout.uuid!, expectedVersion: initial.version, mutation: .rest(start: date, duration: 30))
        _ = try store.apply(operation: rest)
        let stale = WorkoutOperation(workoutID: workout.uuid!, expectedVersion: initial.version, mutation: .workoutMetadata(title: "Candidate", comment: nil))
        XCTAssertEqual(try store.apply(operation: stale).disposition, .conflict)
        let current = try store.snapshot(workoutID: workout.uuid!)
        let finish = WorkoutOperation(workoutID: workout.uuid!, expectedVersion: current.version, mutation: .requestFinish)
        _ = try store.apply(operation: finish)
        XCTAssertThrowsError(try store.recordSessionAgreement(workoutID: workout.uuid!, sessionID: current.sessionID!, phase: .finished))
        XCTAssertEqual(try store.snapshot(workoutID: workout.uuid!).phase, .pendingFinish)
    }

    func testEditingDraftDoesNotMutateManagedObject() throws {
        var draft = WorkoutSetDraft(set: set)
        draft.weight = 80
        draft.repetitions = 10
        draft.comment = "Local"
        XCTAssertNil(set.weight)
        XCTAssertNil(set.repetitions)
        XCTAssertNil(set.comment)
        XCTAssertFalse(container.viewContext.hasChanges)
        try container.viewContext.save()
        XCTAssertNil(try store.snapshot(workoutID: workout.uuid!).exercises.last?.sets.first?.result.weight)
    }
}
