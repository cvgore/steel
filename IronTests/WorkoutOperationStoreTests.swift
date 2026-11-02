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

    func testTransportJoinRetriesUseOneDurableSession() throws {
        let joining = try store.beginJoining(workoutID: workout.uuid!)
        let message = WorkoutSyncMessage.joined(workoutID: workout.uuid!, sessionID: joining.sessionID!)
        let reply = try XCTUnwrap(store.receiveSync(message))
        guard case let .snapshot(agreed) = reply else { return XCTFail("Expected snapshot") }
        XCTAssertEqual(agreed.phase, .agreed)
        XCTAssertEqual(agreed.sessionID, joining.sessionID)
        XCTAssertEqual(try store.receiveSync(message), reply)
        let reopened = try open()
        defer { for persistent in reopened.persistentStoreCoordinator.persistentStores { try? reopened.persistentStoreCoordinator.remove(persistent) } }
        XCTAssertEqual(try WorkoutOperationStore(coordinator: reopened.persistentStoreCoordinator).receiveSync(message), reply)
    }

    func testTransportReplaysOutOfOrderOfflineChainWithoutLosingResults() throws {
        let replicaURL = directory.appendingPathComponent("watch.json")
        let watch = try WorkoutReplicaStore(url: replicaURL)
        let joining = try store.beginJoining(workoutID: workout.uuid!)
        let join = try XCTUnwrap(watch.receiveSync(.snapshot(joining)))
        _ = try watch.receiveSync(XCTUnwrap(store.receiveSync(join)))
        let one = try watch.submit(.saveSet(exerciseID: exercise.uuid!, setID: set.uuid!,
            draft: .init(weight: 42, repetitions: 5, tag: nil, rpe: 8, comment: "offline"), complete: true, restDuration: 90), date: date)
        let two = try watch.submit(.saveSet(exerciseID: exercise.uuid!, setID: set.uuid!,
            draft: .init(weight: 44, repetitions: 6, tag: nil, rpe: 8, comment: "correction"), complete: true, restDuration: 90), date: date.addingTimeInterval(30))
        _ = try store.receiveSync(.operation(two))
        let reply = try XCTUnwrap(store.receiveSync(.operation(one)))
        let reopened = try WorkoutReplicaStore(url: replicaURL)
        _ = try reopened.receiveSync(reply)
        XCTAssertTrue(reopened.pendingOperations.isEmpty)
        XCTAssertTrue(reopened.state.conflicts.isEmpty)
        XCTAssertEqual(reopened.snapshot?.exercises.last?.sets.first?.result.weight, 44)
        XCTAssertEqual(reopened.snapshot?.restStart, date)
        XCTAssertEqual(reopened.snapshot?.restDuration, 90)
        XCTAssertEqual(try store.receiveSync(.operation(one)), reply)
        XCTAssertEqual(try store.snapshot(workoutID: workout.uuid!).version, joining.version + 3)
    }

    func testConflictResolutionPreservesInputsAndRetriesDurably() throws {
        let joining = try store.beginJoining(workoutID: workout.uuid!)
        let agreed = try store.recordSessionAgreement(workoutID: workout.uuid!, sessionID: joining.sessionID!, phase: .agreed)
        let remote = WorkoutOperation(workoutID: workout.uuid!, sessionID: agreed.sessionID, originID: "watch",
            sequence: 1, expectedVersion: agreed.version, mutation: .saveSet(exerciseID: exercise.uuid!, setID: set.uuid!,
                draft: .init(weight: 44, repetitions: 6, tag: nil, rpe: 8, comment: "Watch candidate"), complete: true, restDuration: 90), date: date)
        _ = try store.apply(operation: operation(version: agreed.version))
        XCTAssertEqual(try store.apply(operation: remote).disposition, .conflict)
        let version = try store.snapshot(workoutID: workout.uuid!).version
        let decision = WorkoutOperation(workoutID: workout.uuid!, sessionID: agreed.sessionID, expectedVersion: version,
            mutation: .resolveConflict(operationID: remote.id, useCandidate: true))
        let receipt = try store.apply(operation: decision)
        XCTAssertEqual(receipt.disposition, .applied)
        XCTAssertEqual(try store.snapshot(workoutID: workout.uuid!).exercises.last?.sets.first?.result.weight, 44)
        XCTAssertEqual(try store.snapshot(workoutID: workout.uuid!).resolvedOperationIDs, [remote.id])
        XCTAssertEqual(try store.operations(workoutID: workout.uuid!, disposition: .conflict).first?.operation, remote)
        XCTAssertEqual(try store.apply(operation: decision), receipt)
        let reopened = try open()
        defer { for persistent in reopened.persistentStoreCoordinator.persistentStores { try? reopened.persistentStoreCoordinator.remove(persistent) } }
        XCTAssertEqual(try WorkoutOperationStore(coordinator: reopened.persistentStoreCoordinator).apply(operation: decision), receipt)
    }

    func testKeepingPhoneConflictResultRemovesOverlayButPreservesWatchInput() throws {
        let watchURL = directory.appendingPathComponent("watch.json")
        let watch = try WorkoutReplicaStore(url: watchURL)
        let joining = try store.beginJoining(workoutID: workout.uuid!)
        let join = try XCTUnwrap(watch.receiveSync(.snapshot(joining)))
        _ = try watch.receiveSync(XCTUnwrap(store.receiveSync(join)))
        let remote = try watch.submit(.saveSet(exerciseID: exercise.uuid!, setID: set.uuid!,
            draft: .init(weight: 99, repetitions: 8, tag: nil, rpe: 8, comment: "conflicting Watch input"), complete: true, restDuration: 90))
        _ = try store.apply(operation: operation(version: joining.version + 1))
        _ = try watch.receiveSync(XCTUnwrap(store.receiveSync(.operation(remote))))
        let current = try store.snapshot(workoutID: workout.uuid!)
        let decision = WorkoutOperation(workoutID: workout.uuid!, sessionID: joining.sessionID, expectedVersion: current.version,
            mutation: .resolveConflict(operationID: remote.id, useCandidate: false))
        _ = try store.apply(operation: decision)
        _ = try watch.receiveSync(.snapshot(store.snapshot(workoutID: workout.uuid!)))
        let reopened = try WorkoutReplicaStore(url: watchURL)
        XCTAssertEqual(reopened.snapshot?.exercises.last?.sets.first?.result.weight, 42.5)
        XCTAssertEqual(reopened.state.operations, [remote])
        XCTAssertEqual(reopened.state.receipts.first?.disposition, .conflict)
        XCTAssertEqual(reopened.state.acceptedSnapshot?.resolvedOperationIDs, [remote.id])
        let next = try reopened.submit(.saveSet(exerciseID: exercise.uuid!, setID: set.uuid!,
            draft: .init(weight: 45, repetitions: 7, tag: nil, rpe: 8, comment: nil), complete: true, restDuration: 90))
        XCTAssertNil(next.predecessorID)
        XCTAssertEqual(next.expectedVersion, current.version + 1)
    }

    func testOfflineFinishReconcilesBeforePruningAndSurvivesLostReply() throws {
        let watch = try joinedReplica()
        let id = workout.uuid!
        let save = try watch.submit(.saveSet(exerciseID: exercise.uuid!, setID: set.uuid!,
            draft: .init(weight: 50, repetitions: 6, tag: nil, rpe: 0, comment: "retained"), complete: true, restDuration: 90), date: date)
        let finish = try watch.submit(.requestFinish, date: date.addingTimeInterval(30))
        XCTAssertEqual(watch.snapshot?.phase, .pendingFinish)
        XCTAssertNil(watch.terminalReadiness)
        XCTAssertEqual(try store.snapshot(workoutID: id).phase, .agreed)
        _ = try store.receiveSync(.operation(finish)) // deliberately reversed transport order
        let update = try XCTUnwrap(store.receiveSync(.operation(save)))
        XCTAssertTrue(try store.snapshot(workoutID: id).isCurrentWorkout)
        let restarted = try WorkoutReplicaStore(url: directory.appendingPathComponent("watch.json"))
        let ready = try XCTUnwrap(restarted.receiveSync(update))
        XCTAssertEqual(restarted.snapshot?.exercises.last?.sets.first?.result.weight, 50)
        let terminalReply = try XCTUnwrap(store.receiveSync(ready)) // pretend reply was lost
        XCTAssertEqual(try store.receiveSync(ready), terminalReply)
        _ = try restarted.receiveSync(terminalReply)
        let terminal = try store.snapshot(workoutID: id)
        XCTAssertEqual(terminal.phase, .finished)
        XCTAssertFalse(terminal.isCurrentWorkout)
        XCTAssertNil(terminal.restStart)
        XCTAssertEqual(terminal.end, date.addingTimeInterval(30))
        XCTAssertEqual(terminal.exercises.flatMap(\.sets).count, 2)
        XCTAssertTrue(terminal.exercises.flatMap(\.sets).allSatisfy(\.isCompleted))
        XCTAssertEqual(restarted.snapshot?.phase, .finished)
        XCTAssertEqual(try store.apply(operation: finish).disposition, .applied)
        XCTAssertTrue(try store.watchOwnedWorkoutIDs().contains(id))
    }

    func testCancelDeletesGraphButRetainsDurableTombstoneAndReceipts() throws {
        let watch = try joinedReplica()
        let id = workout.uuid!
        let cancel = try watch.submit(.requestCancel)
        let ready = try XCTUnwrap(watch.receiveSync(XCTUnwrap(store.receiveSync(.operation(cancel)))))
        let reply = try XCTUnwrap(store.receiveSync(ready, mergingInto: container.viewContext))
        _ = try watch.receiveSync(reply)
        XCTAssertTrue(workout.isDeleted || workout.managedObjectContext == nil)
        XCTAssertEqual(try container.viewContext.fetch(Workout.fetchRequest()).count, 0)
        let reopened = try open()
        defer { for persistent in reopened.persistentStoreCoordinator.persistentStores { try? reopened.persistentStoreCoordinator.remove(persistent) } }
        let recovered = WorkoutOperationStore(coordinator: reopened.persistentStoreCoordinator)
        XCTAssertEqual(try recovered.snapshot(workoutID: id).phase, .cancelled)
        XCTAssertEqual(try recovered.receiveSync(ready), reply)
        XCTAssertEqual(try recovered.apply(operation: cancel).disposition, .applied)
        let late = WorkoutOperation(workoutID: id, sessionID: cancel.sessionID, originID: cancel.originID,
            sequence: cancel.sequence + 1, predecessorID: cancel.id, expectedVersion: cancel.expectedVersion,
            mutation: .requestFinish)
        XCTAssertEqual(try recovered.apply(operation: late).disposition, .conflict)
        XCTAssertEqual(try recovered.snapshot(workoutID: id).phase, .cancelled)
        XCTAssertNil(try recovered.activeSharedSnapshot())
    }

    func testPhoneFinishWaitsForOfflineCorrectionAndExplicitDecision() throws {
        let watch = try joinedReplica()
        let local = try watch.submit(.saveSet(exerciseID: exercise.uuid!, setID: set.uuid!,
            draft: .init(weight: 77, repetitions: 8, tag: nil, rpe: 0, comment: "offline"), complete: true, restDuration: 90))
        let base = try store.snapshot(workoutID: workout.uuid!)
        _ = try store.apply(operation: .init(workoutID: base.workoutID, sessionID: base.sessionID,
            expectedVersion: base.version, mutation: .requestFinish))
        _ = try watch.receiveSync(.snapshot(store.snapshot(workoutID: base.workoutID)))
        XCTAssertNil(watch.terminalReadiness)
        _ = try watch.receiveSync(XCTUnwrap(store.receiveSync(.operation(local))))
        XCTAssertNil(watch.terminalReadiness)
        let pending = try store.snapshot(workoutID: base.workoutID)
        XCTAssertTrue(pending.isCurrentWorkout)
        _ = try store.apply(operation: .init(workoutID: base.workoutID, sessionID: base.sessionID,
            expectedVersion: pending.version, mutation: .resolveConflict(operationID: local.id, useCandidate: true)))
        let update = try XCTUnwrap(store.receiveSync(.request(workoutID: base.workoutID, sessionID: base.sessionID)))
        let ready = try XCTUnwrap(watch.receiveSync(update))
        _ = try watch.receiveSync(XCTUnwrap(store.receiveSync(ready)))
        XCTAssertEqual(watch.snapshot?.exercises.last?.sets.first?.result.weight, 77)
        XCTAssertEqual(watch.snapshot?.phase, .finished)
    }

    func testReadinessCannotFinalizeAfterNewConflictAndTransactionFailureRollsBack() throws {
        let watch = try joinedReplica()
        let finish = try watch.submit(.requestFinish)
        let ready = try XCTUnwrap(watch.receiveSync(XCTUnwrap(store.receiveSync(.operation(finish)))))
        let pending = try store.snapshot(workoutID: workout.uuid!)
        let failing = WorkoutOperationStore(coordinator: container.persistentStoreCoordinator) { _ in throw CocoaError(.fileWriteUnknown) }
        XCTAssertThrowsError(try failing.receiveSync(ready))
        XCTAssertEqual(try store.snapshot(workoutID: workout.uuid!), pending)
        let late = WorkoutOperation(workoutID: pending.workoutID, sessionID: pending.sessionID,
            expectedVersion: pending.version, mutation: .workoutMetadata(title: "racing", comment: nil))
        XCTAssertEqual(try store.apply(operation: late).disposition, .conflict)
        let blocked = try XCTUnwrap(store.receiveSync(ready))
        _ = try watch.receiveSync(blocked)
        XCTAssertNil(watch.terminalReadiness)
        XCTAssertTrue(try store.snapshot(workoutID: pending.workoutID).isCurrentWorkout)
    }

    func testJoiningFinishCommitsRequestPruningAndTombstoneTogether() throws {
        let id = workout.uuid!
        let joining = try store.beginJoining(workoutID: id)
        let finish = WorkoutOperation(workoutID: id, sessionID: joining.sessionID,
            expectedVersion: joining.version, mutation: .requestFinish, date: date)
        let failing = WorkoutOperationStore(coordinator: container.persistentStoreCoordinator) { _ in throw CocoaError(.fileWriteUnknown) }
        XCTAssertThrowsError(try failing.apply(operation: finish))
        XCTAssertEqual(try store.snapshot(workoutID: id).phase, .joining)
        XCTAssertTrue(try store.operations(workoutID: id).isEmpty)
        let receipt = try store.apply(operation: finish)
        XCTAssertEqual(try store.snapshot(workoutID: id).phase, .finished)
        XCTAssertFalse(try store.snapshot(workoutID: id).isCurrentWorkout)
        XCTAssertEqual(try store.apply(operation: finish), receipt)
    }

    func testTerminalAdoptionSchedulesHealthEffectBeforeNextSessionArchivesIt() throws {
        let watch = try joinedReplica()
        let finish = try watch.submit(.requestFinish)
        let ready = try XCTUnwrap(watch.receiveSync(XCTUnwrap(store.receiveSync(.operation(finish)))))
        _ = try watch.receiveSync(XCTUnwrap(store.receiveSync(ready)))
        let id = workout.uuid!
        XCTAssertEqual(watch.state.healthEffects?[id], .pending)
        let next = WorkoutSessionSnapshot(workoutID: UUID(), sessionID: UUID(), version: 1, phase: .joining,
            title: nil, comment: nil, start: date, end: nil, isCurrentWorkout: true,
            restStart: nil, restDuration: nil, exercises: [])
        try watch.adopt(snapshot: next)
        let restarted = try WorkoutReplicaStore(url: directory.appendingPathComponent("watch.json"))
        XCTAssertEqual(restarted.state.healthEffects?[id], .pending)
        XCTAssertTrue(try restarted.claimHealthEffect(workoutID: id))
        XCTAssertFalse(try restarted.claimHealthEffect(workoutID: id))
        XCTAssertEqual(restarted.snapshot?.workoutID, next.workoutID)
    }

    func testNextJoinOvertakingLostTerminalReplyRecoversWithoutLosingEitherSession() throws {
        let watch = try joinedReplica()
        let finish = try watch.submit(.requestFinish)
        let ready = try XCTUnwrap(watch.receiveSync(XCTUnwrap(store.receiveSync(.operation(finish)))))
        let terminal = try XCTUnwrap(store.receiveSync(ready)) // lost reply
        let next = WorkoutSessionSnapshot(workoutID: UUID(), sessionID: UUID(), version: 1, phase: .joining,
            title: nil, comment: nil, start: date, end: nil, isCurrentWorkout: true,
            restStart: nil, restDuration: nil, exercises: [])
        XCTAssertEqual(try watch.receiveSync(.snapshot(next)), .request(workoutID: workout.uuid!, sessionID: finish.sessionID))
        try watch.retainTrackingStart(workoutID: next.workoutID, start: date.addingTimeInterval(20))
        XCTAssertNil(watch.trackingStartToResume, "Do not replace unresolved A measurements")
        XCTAssertEqual(watch.snapshot?.workoutID, workout.uuid!)
        let restarted = try WorkoutReplicaStore(url: directory.appendingPathComponent("watch.json"))
        XCTAssertEqual(restarted.state.deferredSnapshot, next)
        XCTAssertEqual(try restarted.receiveSync(terminal), .joined(workoutID: next.workoutID, sessionID: next.sessionID!))
        XCTAssertEqual(restarted.snapshot?.workoutID, next.workoutID)
        XCTAssertNil(restarted.state.deferredSnapshot)
        XCTAssertEqual(restarted.state.archivedSessions.first?.operations, [finish])
        XCTAssertEqual(restarted.state.healthEffects?[workout.uuid!], .pending)
        XCTAssertEqual(restarted.trackingStartToResume?.workoutID, next.workoutID)
        XCTAssertEqual(restarted.trackingStartToResume?.start, next.start, "Use the agreed journal date")
        let resumed = try WorkoutReplicaStore(url: directory.appendingPathComponent("watch.json"))
        XCTAssertEqual(resumed.trackingStartToResume?.workoutID, next.workoutID)
        try resumed.acknowledgeTrackingStart(workoutID: next.workoutID)
        XCTAssertNil(try WorkoutReplicaStore(url: directory.appendingPathComponent("watch.json")).trackingStartToResume)
        try resumed.retainTrackingStart(workoutID: workout.uuid!, start: date)
        XCTAssertNil(resumed.state.deferredTrackingStarts?[workout.uuid!], "Late starts cannot restart terminal A")
    }

    func testHealthRecoveryProbesLaterEffectsDespiteAnUnreadableOrBlockedOlderEffect() throws {
        let watch = try joinedReplica()
        let blocked = UUID(), hidden = UUID(), found = UUID(), active = UUID()
        try watch.recordHealthEffect(.blocked, workoutID: blocked)
        try watch.recordHealthEffect(.uncertain, workoutID: hidden)
        try watch.recordHealthEffect(.uncertain, workoutID: found)
        try watch.recordHealthEffect(.saving, workoutID: active)
        var queried = Set<UUID>()
        var completed = Set<UUID>()
        watch.recoverHealthEffects(excluding: [active], findSaved: { id, reply in
            queried.insert(id); reply(id == found)
        }, completion: { id, result in
            if case .failure(let error) = result { XCTFail("Unexpected recovery failure: \(error)") }
            completed.insert(id)
        })
        XCTAssertEqual(queried, [hidden, found])
        XCTAssertEqual(completed, queried)
        XCTAssertEqual(watch.state.healthEffects?[blocked], .blocked)
        XCTAssertEqual(watch.state.healthEffects?[hidden], .uncertain)
        XCTAssertEqual(watch.state.healthEffects?[found], .saved)
        XCTAssertEqual(watch.state.healthEffects?[active], .saving)
    }

    func testCollectionIntentSurvivesDuplicateStartAndFailedAsynchronousCollection() throws {
        let watch = try joinedReplica(), id = workout.uuid!
        try watch.retainTrackingStart(workoutID: id, start: date)
        var gate = WorkoutMeasurementGate()
        XCTAssertFalse(gate.beginCollection(workoutID: id))
        XCTAssertTrue(gate.beginRecovery())
        gate.finishRecovery(succeeded: true)
        XCTAssertTrue(gate.beginCollection(workoutID: id))
        // HKSession can already report running before beginCollection completes.
        XCTAssertFalse(gate.beginCollection(workoutID: id))
        XCTAssertFalse(gate.canAcknowledge(workoutID: id))
        XCTAssertFalse(gate.finishCollection(workoutID: id, succeeded: false))
        XCTAssertNotNil(try WorkoutReplicaStore(url: directory.appendingPathComponent("watch.json")).trackingStartToResume)
        XCTAssertTrue(gate.beginCollection(workoutID: id))
        XCTAssertTrue(gate.finishCollection(workoutID: id, succeeded: true))
        XCTAssertTrue(gate.canAcknowledge(workoutID: id))
        try watch.acknowledgeTrackingStart(workoutID: id)
        XCTAssertNil(watch.trackingStartToResume)
    }

    func testFailedTrackingAcknowledgmentRetainsIntentUntilDurableRetry() throws {
        let watch = try joinedReplica(), id = workout.uuid!
        try watch.retainTrackingStart(workoutID: id, start: date)
        let url = directory.appendingPathComponent("watch.json")
        var failWrite = true
        let retrying = try WorkoutReplicaStore(url: url, write: { data, url in
            if failWrite { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        })
        XCTAssertThrowsError(try retrying.acknowledgeTrackingStart(workoutID: id))
        XCTAssertNotNil(retrying.trackingStartToResume)
        XCTAssertNotNil(try WorkoutReplicaStore(url: url).trackingStartToResume)
        failWrite = false
        try retrying.acknowledgeTrackingStart(workoutID: id)
        XCTAssertNil(retrying.trackingStartToResume)
        XCTAssertNil(try WorkoutReplicaStore(url: url).trackingStartToResume)
    }

    func testDelayedRecoveryBlocksPreparationAndRetainedStartUntilOwnerIsAttached() throws {
        let watch = try joinedReplica(), id = workout.uuid!
        try watch.retainTrackingStart(workoutID: id, start: date)
        var gate = WorkoutMeasurementGate()
        XCTAssertFalse(gate.canPrepare)
        XCTAssertTrue(gate.beginRecovery())
        XCTAssertFalse(gate.beginRecovery(), "Repeated lifecycle callbacks must share one recovery")
        XCTAssertFalse(gate.beginCollection(workoutID: id))
        XCTAssertNotNil(watch.trackingStartToResume)
        gate.finishRecovery(succeeded: false)
        XCTAssertFalse(gate.canPrepare, "Recovery errors do not establish absence of an active workout")
        XCTAssertTrue(gate.beginRecovery())
        gate.finishRecovery(succeeded: true, collectingID: id)
        XCTAssertTrue(gate.canPrepare)
        XCTAssertTrue(gate.canAcknowledge(workoutID: id), "Recovered collecting builder is reused")
        try watch.acknowledgeTrackingStart(workoutID: id)
        XCTAssertNil(watch.trackingStartToResume)
    }

    func testHealthClaimIsDurableAndNeverRetriesUncertainEffect() throws {
        let watch = try joinedReplica()
        let finish = try watch.submit(.requestFinish)
        let ready = try XCTUnwrap(watch.receiveSync(XCTUnwrap(store.receiveSync(.operation(finish)))))
        _ = try watch.receiveSync(XCTUnwrap(store.receiveSync(ready)))
        let id = workout.uuid!
        XCTAssertTrue(try watch.claimHealthEffect(workoutID: id))
        let restarted = try WorkoutReplicaStore(url: directory.appendingPathComponent("watch.json"))
        XCTAssertEqual(restarted.state.healthEffects?[id], .saving)
        XCTAssertFalse(try restarted.claimHealthEffect(workoutID: id))
        try restarted.recordHealthEffect(.uncertain, workoutID: id)
        try restarted.retryBlockedHealthEffect(workoutID: id)
        XCTAssertFalse(try restarted.claimHealthEffect(workoutID: id))
        XCTAssertEqual(try store.snapshot(workoutID: id).phase, .finished)
    }

    func testHealthClaimWriteFailureCannotInvokeEffectAndBlockedCanRetryExplicitly() throws {
        let watch = try joinedReplica()
        let finish = try watch.submit(.requestFinish)
        let ready = try XCTUnwrap(watch.receiveSync(XCTUnwrap(store.receiveSync(.operation(finish)))))
        _ = try watch.receiveSync(XCTUnwrap(store.receiveSync(ready)))
        let id = workout.uuid!
        let failing = try WorkoutReplicaStore(url: directory.appendingPathComponent("watch.json"), write: { _, _ in throw CocoaError(.fileWriteUnknown) })
        XCTAssertThrowsError(try failing.claimHealthEffect(workoutID: id))
        XCTAssertEqual(failing.state.healthEffects?[id], .pending)
        try watch.recordHealthEffect(.blocked, workoutID: id)
        XCTAssertFalse(try watch.claimHealthEffect(workoutID: id))
        try watch.retryBlockedHealthEffect(workoutID: id)
        XCTAssertTrue(try watch.claimHealthEffect(workoutID: id))
    }

    func testSnapshotUsesExistingPersonalRecordRule() throws {
        exercise.exerciseUuid = UUID()
        try container.viewContext.save()
        _ = try store.apply(operation: operation(), mergingInto: container.viewContext)
        let projected = try store.snapshot(workoutID: workout.uuid!)
        XCTAssertEqual(projected.exercises.last?.sets.first?.isPersonalRecord, false)
        XCTAssertEqual(projected.exercises.last?.sets.first?.isPersonalRecord, set.isPersonalRecord)
    }

    func testDelayedOldSessionReplyDoesNotSelectItAsActiveSession() throws {
        let oldID = workout.uuid!
        let joining = try store.beginJoining(workoutID: oldID)
        let agreed = try store.recordSessionAgreement(workoutID: oldID, sessionID: joining.sessionID!, phase: .agreed)
        _ = try store.apply(operation: .init(workoutID: oldID, sessionID: agreed.sessionID, expectedVersion: agreed.version, mutation: .requestFinish))
        _ = try store.recordSessionAgreement(workoutID: oldID, sessionID: agreed.sessionID!, phase: .finished, mergingInto: container.viewContext)
        let next = Workout.create(context: container.viewContext)
        next.isCurrentWorkout = true
        next.start = date.addingTimeInterval(600)
        try container.viewContext.save()
        let current = try store.beginJoining(workoutID: next.uuid!)
        guard case let .snapshot(terminal)? = try store.receiveSync(.joined(workoutID: oldID, sessionID: joining.sessionID!)) else {
            return XCTFail("Late join must return the terminal marker")
        }
        XCTAssertEqual(terminal.phase, .finished)
        _ = try store.receiveSync(.request(workoutID: oldID, sessionID: joining.sessionID))
        XCTAssertEqual(try store.activeSharedSnapshot()?.workoutID, next.uuid)
        XCTAssertEqual(try store.activeSharedSnapshot()?.sessionID, current.sessionID)
    }

    func testTransportedRecordFlagsRecalculateLaterSetsAndTies() throws {
        let catalogID = UUID()
        exercise.exerciseUuid = catalogID
        let history = Workout.create(context: container.viewContext)
        history.start = date.addingTimeInterval(-3600); history.end = date.addingTimeInterval(-3500)
        let historicalExercise = WorkoutExercise.create(context: container.viewContext)
        historicalExercise.workout = history; historicalExercise.exerciseUuid = catalogID
        let previous = WorkoutSet.create(context: container.viewContext)
        previous.workoutExercise = historicalExercise; previous.isCompleted = true
        previous.weightValue = 40; previous.repetitionsValue = 5
        let later = WorkoutSet.create(context: container.viewContext)
        later.workoutExercise = exercise
        try container.viewContext.save()
        _ = try store.apply(operation: operation())
        _ = try store.apply(operation: .init(workoutID: workout.uuid!, exerciseID: exercise.uuid!, setID: later.uuid!, expectedVersion: 1,
            draft: .init(weight: 42.5, repetitions: 6, tag: nil, rpe: 0, comment: nil), restDuration: 90))
        XCTAssertEqual(try store.snapshot(workoutID: workout.uuid!).exercises.last?.sets.map(\.isPersonalRecord), [true, false])
        _ = try store.apply(operation: operation(version: 2, draft: .init(weight: 41, repetitions: 5, tag: nil, rpe: 0, comment: nil)))
        XCTAssertEqual(try store.snapshot(workoutID: workout.uuid!).exercises.last?.sets.map(\.isPersonalRecord), [true, true])
        _ = try store.apply(operation: operation(version: 3, draft: .init(weight: 40, repetitions: 5, tag: nil, rpe: 0, comment: nil)))
        XCTAssertEqual(try store.snapshot(workoutID: workout.uuid!).exercises.last?.sets.map(\.isPersonalRecord), [false, true])
        // A stronger correction to the earlier set removes the later set's record.
        _ = try store.apply(operation: operation(version: 4, draft: .init(weight: 50, repetitions: 8, tag: nil, rpe: 0, comment: nil)))
        XCTAssertEqual(try store.snapshot(workoutID: workout.uuid!).exercises.last?.sets.map(\.isPersonalRecord), [true, false])
    }

    func testConcurrentCorrectionAndFinishRequireDurableResolutionBeforeAgreement() throws {
        _ = try store.apply(operation: operation())
        let joining = try store.beginJoining(workoutID: workout.uuid!)
        let agreed = try store.recordSessionAgreement(workoutID: workout.uuid!, sessionID: joining.sessionID!, phase: .agreed)
        let watch = try WorkoutReplicaStore(url: directory.appendingPathComponent("watch.json"))
        _ = try watch.receiveSync(.snapshot(agreed))
        let correction = try watch.submit(.saveSet(exerciseID: exercise.uuid!, setID: set.uuid!,
            draft: .init(weight: 48, repetitions: 7, tag: nil, rpe: 8, comment: "offline correction"), complete: true, restDuration: 180))
        _ = try store.apply(operation: .init(workoutID: workout.uuid!, sessionID: agreed.sessionID,
            expectedVersion: agreed.version, mutation: .requestFinish))
        _ = try watch.receiveSync(XCTUnwrap(store.receiveSync(.operation(correction))))
        XCTAssertThrowsError(try store.recordSessionAgreement(workoutID: workout.uuid!, sessionID: agreed.sessionID!, phase: .finished))
        let before = try store.snapshot(workoutID: workout.uuid!)
        _ = try store.apply(operation: .init(workoutID: workout.uuid!, sessionID: agreed.sessionID,
            expectedVersion: before.version, mutation: .resolveConflict(operationID: correction.id, useCandidate: true)))
        let resolved = try store.snapshot(workoutID: workout.uuid!)
        XCTAssertEqual(resolved.phase, .pendingFinish)
        XCTAssertEqual(resolved.restStart, date)
        XCTAssertEqual(resolved.restDuration, 90)
        let terminal = try store.recordSessionAgreement(workoutID: workout.uuid!, sessionID: agreed.sessionID!, phase: .finished)
        _ = try watch.receiveSync(.snapshot(terminal))
        XCTAssertEqual(watch.snapshot?.phase, .finished)
        XCTAssertEqual(watch.snapshot?.exercises.last?.sets.first?.result.weight, 48)
        XCTAssertNil(watch.snapshot?.restStart)
        XCTAssertEqual(watch.state.operations, [correction])
    }

    func testPhoneDraftConflictIsAdvertisedInSharedSnapshotAndClearedByDecision() throws {
        _ = try store.apply(operation: operation())
        let stale = operation()
        XCTAssertEqual(try store.apply(operation: stale).disposition, .conflict)
        let snapshot = try store.snapshot(workoutID: workout.uuid!)
        XCTAssertEqual(snapshot.unresolvedConflictIDs, [stale.id])
        _ = try store.apply(operation: .init(workoutID: workout.uuid!, sessionID: snapshot.sessionID,
            expectedVersion: snapshot.version, mutation: .resolveConflict(operationID: stale.id, useCandidate: false)))
        XCTAssertNil(try store.snapshot(workoutID: workout.uuid!).unresolvedConflictIDs)
        // Other stale phone edits can be explicitly dismissed before repeating them in their editor.
        let metadata = WorkoutOperation(workoutID: workout.uuid!, sessionID: snapshot.sessionID,
            expectedVersion: 0, mutation: .workoutMetadata(title: "Stale title", comment: "Retained input"))
        XCTAssertEqual(try store.apply(operation: metadata).disposition, .conflict)
        let current = try store.snapshot(workoutID: workout.uuid!)
        _ = try store.apply(operation: .init(workoutID: workout.uuid!, sessionID: current.sessionID,
            expectedVersion: current.version, mutation: .resolveConflict(operationID: metadata.id, useCandidate: false)))
        XCTAssertNil(try store.snapshot(workoutID: workout.uuid!).unresolvedConflictIDs)
        XCTAssertEqual(try store.operations(workoutID: workout.uuid!, disposition: .conflict).last(where: { $0.operation.id == metadata.id })?.operation, metadata)
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
        XCTAssertEqual(try store.snapshot(workoutID: first.workoutID).domainSnapshot, snapshot.domainSnapshot)
        XCTAssertEqual(try store.snapshot(workoutID: first.workoutID).unresolvedConflictIDs, [stale.id])
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

    func testEditAfterPartialCoverageKeepsOfflineChainAcrossRestart() throws {
        let replica = try joinedReplica()
        let base = try store.snapshot(workoutID: workout.uuid!)
        let first = try replica.submit(.workoutMetadata(title: "First", comment: nil))
        let second = try replica.submit(.workoutMetadata(title: "Second", comment: nil))
        let firstReceipt = try store.apply(operation: first)
        try replica.adopt(snapshot: store.snapshot(workoutID: workout.uuid!))

        let reopenedWatch = try WorkoutReplicaStore(url: directory.appendingPathComponent("watch.json"))
        let third = try reopenedWatch.submit(.workoutMetadata(title: "Third", comment: "After partial coverage"))
        XCTAssertEqual(third.predecessorID, second.id)
        XCTAssertEqual(try store.apply(operation: third).disposition, .waitingForPredecessor)
        let secondReceipt = try store.apply(operation: second)
        XCTAssertEqual(secondReceipt.disposition, .applied)
        let thirdReceipt = try store.apply(operation: third)
        XCTAssertEqual(thirdReceipt.disposition, .applied)
        XCTAssertEqual(thirdReceipt.version, base.version + 3)
        XCTAssertEqual(try store.apply(operation: third), thirdReceipt)
        for receipt in [firstReceipt, secondReceipt, thirdReceipt] { try reopenedWatch.receive(receipt: receipt) }
        let accepted = try store.snapshot(workoutID: workout.uuid!)
        try reopenedWatch.adopt(snapshot: accepted)
        XCTAssertEqual(accepted.title, "Third")
        XCTAssertEqual(accepted.comment, "After partial coverage")
        XCTAssertEqual(reopenedWatch.snapshot, accepted)
        XCTAssertTrue(reopenedWatch.pendingOperations.isEmpty)
        XCTAssertTrue(reopenedWatch.state.conflicts.isEmpty)
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

    func testFinishRequestWaitsAndAgreementDurablyFinalizesGraph() throws { try assertTerminal(.requestFinish) }
    func testCancelRequestWaitsAndAgreementDurablyDiscardsGraph() throws { try assertTerminal(.requestCancel) }
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
        XCTAssertFalse(terminal.isCurrentWorkout)
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
        XCTAssertEqual(try store.snapshot(workoutID: workout.uuid!).domainSnapshot, accepted.domainSnapshot)
        XCTAssertEqual(try store.snapshot(workoutID: workout.uuid!).unresolvedConflictIDs, [candidate.id])
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
