import XCTest
@testable import WorkoutDataKit

final class WorkoutReplicaStoreTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("replica.json") }
    private let session = UUID(), workout = UUID(), exercise = UUID(), set = UUID()
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private func snapshot(_ version: Int64 = 0, covered: [UUID] = [], phase: WorkoutSessionPhase = .agreed) -> WorkoutSessionSnapshot {
        .init(workoutID: workout, sessionID: session, version: version, phase: phase, coveredOperationIDs: covered,
              title: "Phone", comment: nil, start: nil, end: nil, isCurrentWorkout: !phase.isTerminal,
              restStart: nil, restDuration: nil,
              exercises: [.init(id: exercise, exerciseID: nil, comment: nil,
                  sets: [.init(id: set, result: .empty, isCompleted: false, minTargetRepetitions: 4, maxTargetRepetitions: 8)])])
    }
    private func joined() throws -> WorkoutReplicaStore {
        let store = try WorkoutReplicaStore(url: url)
        try store.adopt(snapshot: snapshot()); try store.agree(sessionID: session); return store
    }
    private var save: WorkoutMutation {
        .saveSet(exerciseID: exercise, setID: set,
                 draft: .init(weight: 42, repetitions: 5, tag: nil, rpe: 8, comment: "Watch"), complete: true, restDuration: 90)
    }
    private func receipt(_ op: WorkoutOperation, disposition: WorkoutOperationDisposition = .applied) -> WorkoutOperationReceipt {
        .init(operationID: op.id, sessionID: session, version: 1, disposition: disposition,
              reason: disposition == .conflict ? .staleVersion : nil, didComplete: true, restStart: nil, restDuration: nil)
    }
    func testMustDurablyAdoptAndAgreeBeforeEditing() throws {
        let store = try WorkoutReplicaStore(url: url)
        XCTAssertThrowsError(try store.submit(save))
        try store.adopt(snapshot: snapshot())
        XCTAssertEqual(store.snapshot?.phase, .joining)
        XCTAssertThrowsError(try store.submit(save))
        try store.agree(sessionID: session)
        XCTAssertEqual(try WorkoutReplicaStore(url: url).snapshot?.phase, .agreed)
        XCTAssertThrowsError(try store.submit(.addSet(exerciseID: exercise, set: .init())) )
    }
    func testTransportJoinPersistsBeforeReplyAndWaitsForPhoneAgreement() throws {
        let store = try WorkoutReplicaStore(url: url)
        let reply = try store.receiveSync(.snapshot(snapshot(phase: .joining)))
        XCTAssertEqual(reply, .joined(workoutID: workout, sessionID: session))
        XCTAssertFalse(try WorkoutReplicaStore(url: url).state.agreed)
        XCTAssertThrowsError(try store.submit(save))
        let reopened = try WorkoutReplicaStore(url: url)
        XCTAssertEqual(try reopened.receiveSync(.snapshot(snapshot(phase: .joining))), reply)
        _ = try reopened.receiveSync(.snapshot(snapshot(1, phase: .agreed)))
        XCTAssertTrue(try WorkoutReplicaStore(url: url).state.agreed)
        XCTAssertNoThrow(try reopened.submit(save))
    }

    func testOfflineResultInvalidatesConfirmedRecordsForAffectedExercise() throws {
        var initial = snapshot()
        initial.exercises[0].sets[0].isPersonalRecord = true
        let store = try WorkoutReplicaStore(url: url)
        try store.adopt(snapshot: initial)
        try store.agree(sessionID: session)
        _ = try store.submit(save)
        XCTAssertNil(store.snapshot?.exercises[0].sets[0].isPersonalRecord)
        XCTAssertNil(try WorkoutReplicaStore(url: url).snapshot?.exercises[0].sets[0].isPersonalRecord)
    }

    func testSharedDefaultsMatchHistoryPrefixAndOfflinePreviousSet() {
        let first = WorkoutSetDraft(weight: 40, repetitions: 5, tag: nil, rpe: 8, comment: nil)
        let second = WorkoutSetDraft.empty
        let history: [[WorkoutNumericResult]] = [
            [.init(weight: 30, repetitions: 5), .init(weight: 33, repetitions: 6)],
            [.init(weight: 40, repetitions: 5), .init(weight: 44, repetitions: 7)]
        ]
        let matched = WorkoutEditingRules.initialDraft(result: second, completed: false, index: 1,
            current: [first, second], history: history, barbellWeight: nil)
        XCTAssertEqual(matched.weight, 44)
        XCTAssertEqual(matched.repetitions, 7)
        var offline = first; offline.weight = 50
        let fallback = WorkoutEditingRules.initialDraft(result: second, completed: false, index: 1,
            current: [offline, second], history: history, barbellWeight: nil)
        XCTAssertEqual(fallback.weight, 50)
        XCTAssertEqual(fallback.repetitions, 5)
        let barbell = WorkoutEditingRules.initialDraft(result: .empty, completed: false, index: 0,
            current: [.empty], history: [], barbellWeight: 20)
        XCTAssertEqual(barbell.weight, 20)
        XCTAssertEqual(barbell.repetitions, 5)
    }

    func testEditorContextSurvivesRestartAndDoesNotCreateSameVersionConflict() throws {
        let store = try joined()
        var incoming = snapshot()
        incoming.editorContext = .init(weightUnit: "imperial", keepRestTimerRunning: true,
            exercises: [.init(id: exercise, title: "Exercise", restDuration: 120, barbellWeight: 20.41165665,
                numericHistory: [[.init(weight: 55, repetitions: 8)]])])
        try store.adopt(snapshot: incoming)
        let reopened = try WorkoutReplicaStore(url: url)
        XCTAssertTrue(reopened.state.conflicts.isEmpty)
        XCTAssertEqual(reopened.snapshot?.editorContext?.weightUnit, "imperial")
        XCTAssertEqual(reopened.snapshot?.editorContext?.exercises.first?.restDuration, 120)
        XCTAssertEqual(reopened.snapshot?.editorDraft(exerciseID: exercise, setID: set)?.weight, 55)
        XCTAssertEqual(reopened.snapshot?.editorDraft(exerciseID: exercise, setID: set)?.repetitions, 8)
    }

    func testTrackingStartCannotReplaceUnresolvedOrResurrectTerminalWorkout() throws {
        let store = try joined()
        XCTAssertTrue(store.allowsTrackingStart(workoutID: workout))
        XCTAssertFalse(store.allowsTrackingStart(workoutID: UUID()))
        try store.adopt(snapshot: snapshot(1, phase: .finished))
        let reopened = try WorkoutReplicaStore(url: url)
        XCTAssertFalse(reopened.allowsTrackingStart(workoutID: workout))
        XCTAssertTrue(reopened.allowsTrackingStart(workoutID: UUID()))
    }

    func testPhoneOnlyConflictSummarySurvivesRestartWithoutChangingDomain() throws {
        let store = try joined()
        var incoming = snapshot()
        let conflictID = UUID()
        incoming.unresolvedConflictIDs = [conflictID]
        try store.adopt(snapshot: incoming)
        XCTAssertEqual(try WorkoutReplicaStore(url: url).snapshot?.unresolvedConflictIDs, [conflictID])
        XCTAssertTrue(store.state.conflicts.isEmpty)
        XCTAssertTrue(store.state.operations.isEmpty)
        // An older snapshot from the same operation version must not hide the server conflict.
        try store.adopt(snapshot: snapshot())
        XCTAssertEqual(store.snapshot?.unresolvedConflictIDs, [conflictID])
        var resolved = snapshot(1)
        resolved.resolvedOperationIDs = [conflictID]
        try store.adopt(snapshot: resolved)
        XCTAssertNil(try WorkoutReplicaStore(url: url).snapshot?.unresolvedConflictIDs)
    }

    func testRepeatedDivergentSnapshotDoesNotDuplicateConflict() throws {
        let store = try joined()
        let operation = try store.submit(save)
        var divergent = snapshot()
        divergent.title = "Divergent phone input"
        try store.adopt(snapshot: divergent)
        try store.adopt(snapshot: divergent)
        XCTAssertEqual(store.state.conflicts.count, 1)
        XCTAssertEqual(store.pendingOperations, [operation])
        XCTAssertEqual(store.snapshot?.exercises[0].sets[0].result.weight, 42)
        XCTAssertEqual(try WorkoutReplicaStore(url: url).state.conflicts.count, 1)
    }
    func testOfflineChainRestartAndDuplicateRetry() throws {
        let store = try joined()
        let one = try store.submit(save)
        let two = try store.submit(.workoutMetadata(title: "Watch", comment: "offline"))
        XCTAssertEqual(two.sequence, one.sequence + 1)
        XCTAssertEqual(two.predecessorID, one.id)
        XCTAssertEqual(two.expectedVersion, 0)
        XCTAssertEqual(store.state.localRevision, 2)
        let reopened = try WorkoutReplicaStore(url: url)
        XCTAssertEqual(reopened.pendingOperations, [one, two])
        XCTAssertEqual(reopened.snapshot?.exercises[0].sets[0].result.weight, 42)
        XCTAssertEqual(try reopened.submit(save, id: one.id), one)
        XCTAssertEqual(reopened.state.localRevision, 2)
        XCTAssertThrowsError(try reopened.submit(.requestFinish, id: one.id))
    }
    func testFailedAtomicWriteLeavesMemoryAndDiskUnchanged() throws {
        let original = try joined().state
        enum DiskError: Error { case full }
        let store = try WorkoutReplicaStore(url: url, write: { _, _ in throw DiskError.full })
        XCTAssertThrowsError(try store.submit(save))
        XCTAssertEqual(store.state, original)
        XCTAssertEqual(try WorkoutReplicaStore(url: url).state, original)
    }
    func testReceiptBeforeSnapshotKeepsLocalResult() throws {
        let store = try joined(); let op = try store.submit(save)
        try store.receive(receipt: receipt(op))
        XCTAssertTrue(store.pendingOperations.isEmpty)
        XCTAssertEqual(store.snapshot?.exercises[0].sets[0].result.weight, 42)
        try store.adopt(snapshot: snapshot(1))
        XCTAssertEqual(store.snapshot?.exercises[0].sets[0].result.weight, 42)
        XCTAssertFalse(store.state.conflicts.isEmpty)
        XCTAssertEqual(store.state.acceptedSnapshot, snapshot(1))
        XCTAssertEqual(try WorkoutReplicaStore(url: url).state, store.state)
    }
    func testSnapshotBeforeReceiptAndStaleSnapshot() throws {
        let store = try joined(); let op = try store.submit(save)
        var accepted = snapshot(1, covered: [op.id])
        accepted.exercises[0].sets[0].result = op.draft!
        accepted.exercises[0].sets[0].isCompleted = true
        try store.adopt(snapshot: accepted)
        XCTAssertEqual(store.pendingOperations, [op])
        try store.receive(receipt: receipt(op))
        try store.adopt(snapshot: snapshot())
        XCTAssertEqual(store.snapshot, accepted)
        XCTAssertTrue(store.pendingOperations.isEmpty)
    }
    func testConflictReceiptPreservesCandidateAndAcceptedSnapshot() throws {
        let store = try joined(); let op = try store.submit(save)
        try store.receive(receipt: receipt(op, disposition: .conflict))
        try store.adopt(snapshot: snapshot(1))
        XCTAssertEqual(store.state.receipts.first?.disposition, .conflict)
        XCTAssertEqual(store.state.operations, [op])
        XCTAssertEqual(store.state.conflicts.first?.candidate.exercises[0].sets[0].result.weight, 42)
        XCTAssertEqual(store.state.conflicts.first?.accepted, snapshot(1))
    }
    func testTerminalRequestHoldsSlotUntilCoveredTerminalAndCannotResurrect() throws {
        for mutation in [WorkoutMutation.requestFinish, .requestCancel] {
            let path = directory.appendingPathComponent(UUID().uuidString)
            let store = try WorkoutReplicaStore(url: path)
            try store.adopt(snapshot: snapshot()); try store.agree(sessionID: session)
            let op = try store.submit(mutation)
            XCTAssertTrue(store.state.occupiesSharedSlot)
            XCTAssertTrue(try WorkoutReplicaStore(url: path).state.occupiesSharedSlot)
            XCTAssertThrowsError(try store.submit(save))
            try store.receive(receipt: receipt(op))
            XCTAssertTrue(store.state.occupiesSharedSlot)
            let phase: WorkoutSessionPhase = mutation == .requestFinish ? .finished : .cancelled
            try store.adopt(snapshot: snapshot(1, covered: [op.id], phase: phase))
            XCTAssertFalse(store.state.occupiesSharedSlot)
            let reopened = try WorkoutReplicaStore(url: path)
            XCTAssertThrowsError(try reopened.adopt(snapshot: snapshot(2)))
            XCTAssertEqual(reopened.snapshot?.phase, phase)
        }
    }
    func testSnapshotRemovingPendingTargetKeepsBothCandidates() throws {
        let store = try joined(); _ = try store.submit(save)
        let candidate = store.snapshot
        var phone = snapshot(1); phone.exercises = []
        try store.adopt(snapshot: phone)
        XCTAssertEqual(store.snapshot, candidate)
        XCTAssertEqual(store.state.acceptedSnapshot, phone)
        XCTAssertEqual(store.state.conflicts.last?.candidate, candidate)
        XCTAssertEqual(try WorkoutReplicaStore(url: url).snapshot, candidate)
    }
    private func nextSession() -> WorkoutSessionSnapshot {
        .init(workoutID: UUID(), sessionID: UUID(), version: 0, phase: .agreed,
              title: "Next phone workout", comment: nil, start: nil, end: nil,
              isCurrentWorkout: true, restStart: nil, restDuration: nil, exercises: [])
    }
    func testResolvedTerminalArchivesAndAdoptsNextSessionWithoutResurrection() throws {
        let store = try joined()
        let origin = store.state.originID
        let op = try store.submit(.requestFinish)
        let terminal = snapshot(1, covered: [op.id], phase: .finished)
        try store.adopt(snapshot: terminal)
        let next = nextSession()
        // A covered snapshot does not erase a still-outstanding transport receipt.
        XCTAssertThrowsError(try store.adopt(snapshot: next))
        try store.receive(receipt: receipt(op))
        try store.adopt(snapshot: next)
        XCTAssertEqual(store.snapshot?.phase, .joining)
        XCTAssertEqual(store.state.originID, origin)
        XCTAssertEqual(store.state.nextSequence, 1)
        XCTAssertEqual(store.state.archivedSessions.first?.snapshot, terminal)
        XCTAssertEqual(store.state.archivedSessions.first?.operations, [op])
        XCTAssertEqual(store.state.archivedSessions.first?.receipts, [receipt(op)])
        XCTAssertTrue(store.state.terminalSessions.contains(session))
        let reopened = try WorkoutReplicaStore(url: url)
        XCTAssertThrowsError(try reopened.adopt(snapshot: terminal))
        XCTAssertThrowsError(try reopened.adopt(snapshot: snapshot(2)))
        XCTAssertEqual(reopened.state, store.state)
        try reopened.agree(sessionID: next.sessionID!)
        try reopened.agree(sessionID: next.sessionID!)
        let nextOp = try reopened.submit(.workoutMetadata(title: "Next", comment: nil))
        XCTAssertEqual(nextOp.sequence, 1)
        XCTAssertNil(nextOp.predecessorID)
        XCTAssertEqual(nextOp.originID, origin)
    }
    func testUncoveredTerminalCannotReleaseSlotOrReplaceSession() throws {
        let store = try joined(); let op = try store.submit(save)
        try store.receive(receipt: receipt(op))
        try store.adopt(snapshot: snapshot(1, phase: .finished))
        XCTAssertTrue(store.state.occupiesSharedSlot)
        XCTAssertFalse(store.snapshot!.phase.isTerminal)
        XCTAssertEqual(store.snapshot?.exercises[0].sets[0].result.weight, 42)
        XCTAssertThrowsError(try store.adopt(snapshot: nextSession()))
        XCTAssertTrue(try WorkoutReplicaStore(url: url).state.occupiesSharedSlot)
    }
    func testAgreementRetrySurvivesRestartAndCannotReopenPending() throws {
        let store = try joined()
        let reopened = try WorkoutReplicaStore(url: url)
        try reopened.agree(sessionID: session)
        XCTAssertEqual(reopened.state, store.state)
        _ = try reopened.submit(.requestCancel)
        XCTAssertThrowsError(try reopened.agree(sessionID: session))
        XCTAssertEqual(reopened.snapshot?.phase, .pendingCancel)
    }
    func testCompletionMovesBehindLastBegunButCorrectionKeepsOrderAndRest() throws {
        let store = try WorkoutReplicaStore(url: url)
        var phone = snapshot()
        let middle = UUID(), begun = UUID()
        phone.exercises.append(.init(id: middle, exerciseID: nil, comment: nil, sets: []))
        phone.exercises.append(.init(id: begun, exerciseID: nil, comment: nil,
            sets: [.init(id: UUID(), result: .empty, isCompleted: true, minTargetRepetitions: nil, maxTargetRepetitions: nil)]))
        try store.adopt(snapshot: phone); try store.agree(sessionID: session)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try store.submit(save, date: date)
        XCTAssertEqual(store.snapshot?.exercises.map(\.id), [middle, begun, exercise])
        _ = try store.submit(.reorderExercises([exercise, middle, begun]))
        _ = try store.submit(save, date: date.addingTimeInterval(60))
        XCTAssertEqual(store.snapshot?.exercises.map(\.id), [exercise, middle, begun])
        XCTAssertEqual(store.snapshot?.restStart, date)
        XCTAssertEqual(store.snapshot?.start, date)
    }
    func testFreshOperationAfterPhoneAdvanceHasNoCoveredPredecessor() throws {
        let store = try joined(); let first = try store.submit(save)
        try store.receive(receipt: receipt(first))
        var phone = snapshot(2, covered: [first.id])
        phone.title = "Phone changed metadata"
        phone.exercises[0].sets[0].result = first.draft!
        phone.exercises[0].sets[0].isCompleted = true
        try store.adopt(snapshot: phone)
        let next = try store.submit(.workoutMetadata(title: "Watch", comment: nil))
        XCTAssertNil(next.predecessorID)
        XCTAssertEqual(next.sequence, 2)
        XCTAssertEqual(next.expectedVersion, 2)
        XCTAssertEqual(next.originID, first.originID)
        XCTAssertEqual(try WorkoutReplicaStore(url: url).pendingOperations, [next])
    }
    func testInvalidDatesRestPairsAndCounterOverflowLeaveStateUnchanged() throws {
        let store = try joined(); let before = store.state
        XCTAssertThrowsError(try store.submit(save, date: Date(timeIntervalSinceReferenceDate: .infinity)))
        XCTAssertThrowsError(try store.submit(.rest(start: Date(), duration: nil)))
        XCTAssertThrowsError(try store.submit(.rest(start: nil, duration: 90)))
        XCTAssertThrowsError(try store.submit(.rest(start: Date(timeIntervalSinceReferenceDate: .nan), duration: 90)))
        XCTAssertThrowsError(try store.submit(.rest(start: Date(), duration: .infinity)))
        XCTAssertEqual(store.state, before)
        for key in ["sequence", "revision"] {
            var injected = before
            if key == "sequence" { injected.nextSequence = Int64.max }
            else { injected.localRevision = Int64.max }
            try JSONEncoder().encode(injected).write(to: url, options: .atomic)
            let reopened = try WorkoutReplicaStore(url: url)
            XCTAssertThrowsError(try reopened.submit(save))
            XCTAssertEqual(reopened.state, injected)
            XCTAssertEqual(try WorkoutReplicaStore(url: url).state, injected)
        }
    }
    func testIntermediateSnapshotCoverageKeepsSuccessorWithoutFalseConflict() throws {
        let store = try joined()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try store.submit(save, date: date)
        let firstProjection = store.snapshot!
        let second = try store.submit(.workoutMetadata(title: "Second offline edit", comment: nil))
        var phone = snapshot(1, covered: [first.id])
        phone.exercises = firstProjection.exercises
        phone.start = firstProjection.start
        phone.restStart = firstProjection.restStart
        phone.restDuration = firstProjection.restDuration
        try store.adopt(snapshot: phone)
        XCTAssertTrue(store.state.conflicts.isEmpty)
        XCTAssertEqual(store.snapshot?.title, "Second offline edit")
        XCTAssertEqual(store.snapshot?.exercises, firstProjection.exercises)
        XCTAssertEqual(store.pendingOperations, [first, second])
        var coveredBoth = snapshot(2, covered: [first.id, second.id])
        coveredBoth.exercises = firstProjection.exercises
        coveredBoth.start = firstProjection.start
        coveredBoth.restStart = firstProjection.restStart
        coveredBoth.restDuration = firstProjection.restDuration
        coveredBoth.title = "Second offline edit"
        try store.adopt(snapshot: coveredBoth)
        try store.receive(receipt: receipt(first))
        try store.receive(receipt: .init(operationID: second.id, sessionID: session, version: 2,
            didComplete: false, restStart: nil, restDuration: nil))
        XCTAssertEqual(store.snapshot, coveredBoth)
        XCTAssertTrue(store.state.conflicts.isEmpty)
        XCTAssertTrue(store.pendingOperations.isEmpty)
        XCTAssertEqual(try WorkoutReplicaStore(url: url).state, store.state)
    }
    func testOtherSessionRejectedWithoutReplacingPendingData() throws {
        let store = try joined(); _ = try store.submit(save)
        let before = store.state
        let other = WorkoutSessionSnapshot(workoutID: UUID(), sessionID: UUID(), version: 10, phase: .agreed,
            title: nil, comment: nil, start: nil, end: nil, isCurrentWorkout: true,
            restStart: nil, restDuration: nil, exercises: [])
        XCTAssertThrowsError(try store.adopt(snapshot: other))
        XCTAssertEqual(store.state, before)
    }
}

final class WatchWorkoutNavigationTests: XCTestCase {
    private let session = UUID(), workout = UUID(), exercise = UUID(), set = UUID()
    private func snapshot(completed: Bool = false) -> WorkoutSessionSnapshot {
        .init(workoutID: workout, sessionID: session, version: 0, phase: .agreed,
              title: nil, comment: nil, start: nil, end: nil, isCurrentWorkout: true,
              restStart: nil, restDuration: nil,
              exercises: [.init(id: exercise, exerciseID: nil, comment: nil, sets: [
                .init(id: set, result: .init(weight: 42, repetitions: 7, tag: nil, rpe: 0, comment: nil),
                      isCompleted: completed, minTargetRepetitions: nil, maxTargetRepetitions: nil)])])
    }
    func testCompletionAdvancesWithinExerciseThenWrapsUsingCurrentOrder() {
        var value = snapshot()
        let second = UUID(), earlier = UUID(), earlierSet = UUID(), later = UUID(), laterSet = UUID()
        value.exercises[0].sets.append(.init(id: second, result: .empty, isCompleted: false, minTargetRepetitions: nil, maxTargetRepetitions: nil))
        value.exercises.append(.init(id: earlier, exerciseID: nil, comment: nil, sets: [.init(id: earlierSet, result: .empty, isCompleted: false, minTargetRepetitions: nil, maxTargetRepetitions: nil)]))
        value.exercises.append(.init(id: later, exerciseID: nil, comment: nil, sets: [.init(id: laterSet, result: .empty, isCompleted: true, minTargetRepetitions: nil, maxTargetRepetitions: nil)]))
        var navigation = WatchWorkoutNavigation()
        navigation.reconcile(snapshot: value)
        navigation.selectExercise(exercise, snapshot: value)
        value.exercises[0].sets[0].isCompleted = true
        navigation.advanceAfterCompletion(exerciseID: exercise, snapshot: value)
        XCTAssertEqual(navigation.workingSets[exercise], second)
        XCTAssertEqual(navigation.path, [.currentSet(exercise)])
        value.exercises[0].sets[1].isCompleted = true
        // Current shared order after reordering: A, B, C; completion of B wraps to A.
        value.exercises.swapAt(0, 1)
        navigation.advanceAfterCompletion(exerciseID: exercise, snapshot: value)
        XCTAssertEqual(navigation.path, [.currentSet(exercise)])
        XCTAssertEqual(navigation.currentExerciseID, earlier)
        XCTAssertEqual(navigation.workingSets[earlier], earlierSet)
        value.exercises[0].sets[0].isCompleted = true
        navigation.advanceAfterCompletion(exerciseID: earlier, snapshot: value)
        XCTAssertEqual(navigation.path, [.currentSet(exercise)])
        XCTAssertEqual(navigation.workingSets[earlier], earlierSet)
        navigation.setPath([])
        XCTAssertTrue(navigation.path.isEmpty)
    }
    func testPageChangesAndReopenPreserveStackAndDrafts() throws {
        let snapshot = snapshot(completed: true)
        var navigation = WatchWorkoutNavigation()
        navigation.reconcile(snapshot: snapshot)
        navigation.selectExercise(exercise, snapshot: snapshot)
        navigation.drafts[set]?.weight = 51
        navigation.showCorrection(exerciseID: exercise, setID: set, snapshot: snapshot)
        navigation.correctionDraft?.weight = 49
        navigation.page = .nowPlaying
        var reopened = try JSONDecoder().decode(WatchWorkoutNavigation.self, from: JSONEncoder().encode(navigation))
        reopened.reconcile(snapshot: snapshot)
        XCTAssertEqual(reopened, navigation)
        XCTAssertEqual(reopened.drafts[set]?.weight, 51)
        XCTAssertEqual(reopened.correctionDraft?.weight, 49)
        XCTAssertEqual(reopened.path.count, 3)
    }
    func testNativeBackDiscardsOnlyCorrectionAndReturnsOneLevel() {
        let snapshot = snapshot(completed: true)
        var navigation = WatchWorkoutNavigation()
        navigation.reconcile(snapshot: snapshot)
        navigation.selectExercise(exercise, snapshot: snapshot)
        navigation.drafts[set]?.weight = 55
        navigation.showCorrection(exerciseID: exercise, setID: set, snapshot: snapshot)
        navigation.setPath([.currentSet(exercise), .sets(exercise)])
        XCTAssertNil(navigation.correctionDraft)
        XCTAssertEqual(navigation.drafts[set]?.weight, 55)
        navigation.setPath([.currentSet(exercise)])
        XCTAssertEqual(navigation.path, [.currentSet(exercise)])
        navigation.setPath([])
        XCTAssertTrue(navigation.path.isEmpty)
    }
    func testRemoteResultsAndOrderingDoNotChangeSelectionOrDraft() {
        var snapshot = snapshot()
        var navigation = WatchWorkoutNavigation()
        navigation.reconcile(snapshot: snapshot)
        navigation.selectExercise(exercise, snapshot: snapshot)
        navigation.drafts[set]?.weight = 61
        let path = navigation.path
        snapshot.exercises[0].sets[0].isCompleted = true
        snapshot.exercises[0].sets[0].result.weight = 77
        navigation.reconcile(snapshot: snapshot)
        XCTAssertEqual(navigation.path, path)
        XCTAssertEqual(navigation.workingSets[exercise], set)
        XCTAssertEqual(navigation.drafts[set]?.weight, 61)
        navigation.selectExercise(exercise, snapshot: snapshot)
        XCTAssertEqual(navigation.drafts[set]?.weight, 61)
    }
    func testReopeningAfterRemoteCompletionSelectsUnfinishedSetWithoutDiscardingDraft() {
        var value = snapshot()
        let next = UUID()
        value.exercises[0].sets.append(.init(id: next, result: .empty, isCompleted: false, minTargetRepetitions: nil, maxTargetRepetitions: nil))
        var navigation = WatchWorkoutNavigation()
        navigation.reconcile(snapshot: value)
        navigation.selectExercise(exercise, snapshot: value)
        navigation.drafts[set]?.weight = 61
        value.exercises[0].sets[0].isCompleted = true
        navigation.reconcile(snapshot: value)
        XCTAssertEqual(navigation.workingSets[exercise], set)
        XCTAssertEqual(navigation.drafts[set]?.weight, 61)
        navigation.setPath([])
        navigation.selectExercise(exercise, snapshot: value)
        XCTAssertEqual(navigation.workingSets[exercise], next)
        XCTAssertEqual(navigation.drafts[set]?.weight, 61)
    }
    func testRemovedExerciseTrimsStackWithoutLeavingInvalidDrafts() {
        var snapshot = snapshot(completed: true)
        var navigation = WatchWorkoutNavigation()
        navigation.reconcile(snapshot: snapshot)
        navigation.selectExercise(exercise, snapshot: snapshot)
        navigation.showCorrection(exerciseID: exercise, setID: set, snapshot: snapshot)
        snapshot.exercises = []
        navigation.reconcile(snapshot: snapshot)
        XCTAssertTrue(navigation.path.isEmpty)
        XCTAssertTrue(navigation.drafts.isEmpty)
        XCTAssertTrue(navigation.workingSets.isEmpty)
        XCTAssertNil(navigation.correctionDraft)
    }
    func testEmptyAndCompletedExercisesRemainSelectable() {
        var snapshot = snapshot(completed: true)
        var navigation = WatchWorkoutNavigation()
        navigation.reconcile(snapshot: snapshot)
        navigation.selectExercise(exercise, snapshot: snapshot)
        XCTAssertEqual(navigation.workingSets[exercise], set)
        snapshot.exercises[0].sets = []
        navigation.reconcile(snapshot: snapshot)
        navigation.selectExercise(exercise, snapshot: snapshot)
        XCTAssertEqual(navigation.path, [.currentSet(exercise)])
        XCTAssertNil(navigation.workingSets[exercise])
    }
    func testTerminalAndNewSessionResetLocalContext() {
        var snapshot = snapshot()
        var navigation = WatchWorkoutNavigation()
        navigation.reconcile(snapshot: snapshot)
        navigation.selectExercise(exercise, snapshot: snapshot)
        navigation.page = .finish
        snapshot.phase = .finished
        navigation.reconcile(snapshot: snapshot)
        XCTAssertEqual(navigation, WatchWorkoutNavigation())
        var next = self.snapshot()
        next = .init(workoutID: workout, sessionID: UUID(), version: 0, phase: .joining,
                     title: nil, comment: nil, start: nil, end: nil, isCurrentWorkout: true,
                     restStart: nil, restDuration: nil, exercises: next.exercises)
        navigation.reconcile(snapshot: next)
        XCTAssertEqual(navigation.sessionID, next.sessionID)
        XCTAssertEqual(navigation.page, .workout)
        XCTAssertTrue(navigation.path.isEmpty)
    }
}

extension WatchWorkoutNavigationTests {
    func testRemoteUncompletionPreservesCorrectionRouteAndDraft() throws {
        var snapshot = snapshot(completed: true)
        var navigation = WatchWorkoutNavigation()
        navigation.reconcile(snapshot: snapshot)
        navigation.selectExercise(exercise, snapshot: snapshot)
        navigation.showCorrection(exerciseID: exercise, setID: set, snapshot: snapshot)
        navigation.correctionDraft?.weight = 64
        let path = navigation.path
        snapshot.exercises[0].sets[0].isCompleted = false
        navigation.reconcile(snapshot: snapshot)
        XCTAssertEqual(navigation.path, path)
        XCTAssertEqual(navigation.correctionDraft?.weight, 64)
        var reopened = try JSONDecoder().decode(WatchWorkoutNavigation.self, from: JSONEncoder().encode(navigation))
        reopened.reconcile(snapshot: snapshot)
        XCTAssertEqual(reopened, navigation)
        reopened.setPath([.currentSet(exercise), .sets(exercise)])
        XCTAssertNil(reopened.correctionDraft)
    }

    func testDeletingWorkingSetSelectsRemainingSetWithoutNavigating() throws {
        for completed in [false, true] {
            var snapshot = snapshot()
            let remaining = UUID()
            snapshot.exercises[0].sets.append(.init(id: remaining, result: .empty, isCompleted: completed,
                minTargetRepetitions: nil, maxTargetRepetitions: nil))
            var navigation = WatchWorkoutNavigation()
            navigation.reconcile(snapshot: snapshot)
            navigation.selectExercise(exercise, snapshot: snapshot)
            navigation.selectWorkingSet(exerciseID: exercise, setID: remaining, snapshot: snapshot)
            navigation.drafts[remaining]?.weight = 63
            navigation.selectWorkingSet(exerciseID: exercise, setID: set, snapshot: snapshot)
            let path = navigation.path
            snapshot.exercises[0].sets.removeFirst()
            navigation.reconcile(snapshot: snapshot)
            XCTAssertEqual(navigation.path, path)
            XCTAssertEqual(navigation.workingSets[exercise], remaining)
            XCTAssertEqual(navigation.drafts[remaining]?.weight, 63)
            XCTAssertNil(navigation.drafts[set])
            var reopened = try JSONDecoder().decode(WatchWorkoutNavigation.self, from: JSONEncoder().encode(navigation))
            reopened.reconcile(snapshot: snapshot)
            XCTAssertEqual(reopened, navigation)
        }
    }

    func testAddingFirstSetToOpenExerciseInitializesWorkingDraft() {
        var snapshot = snapshot()
        let first = snapshot.exercises[0].sets.removeFirst()
        var navigation = WatchWorkoutNavigation()
        navigation.reconcile(snapshot: snapshot)
        navigation.selectExercise(exercise, snapshot: snapshot)
        let path = navigation.path
        snapshot.exercises[0].sets.append(first)
        navigation.reconcile(snapshot: snapshot)
        XCTAssertEqual(navigation.path, path)
        XCTAssertEqual(navigation.workingSets[exercise], set)
        XCTAssertEqual(navigation.drafts[set], first.result)
    }

    func testWorkoutRequiresDurableAgreementAndActiveSession() {
        var snapshot = snapshot()
        XCTAssertFalse(WatchWorkoutNavigation.canPresentWorkout(snapshot: nil, agreed: true))
        XCTAssertFalse(WatchWorkoutNavigation.canPresentWorkout(snapshot: snapshot, agreed: false))
        snapshot.phase = .joining
        XCTAssertFalse(WatchWorkoutNavigation.canPresentWorkout(snapshot: snapshot, agreed: true))
        snapshot.phase = .agreed
        XCTAssertTrue(WatchWorkoutNavigation.canPresentWorkout(snapshot: snapshot, agreed: true))
        snapshot.phase = .pendingFinish
        XCTAssertTrue(WatchWorkoutNavigation.canPresentWorkout(snapshot: snapshot, agreed: true))
        snapshot.phase = .pendingCancel
        XCTAssertTrue(WatchWorkoutNavigation.canPresentWorkout(snapshot: snapshot, agreed: true))
        snapshot.phase = .cancelled
        XCTAssertFalse(WatchWorkoutNavigation.canPresentWorkout(snapshot: snapshot, agreed: true))
    }
    func testChangingWorkingSetDoesNotPushAnotherScreen() {
        var snapshot = snapshot()
        let next = UUID()
        snapshot.exercises[0].sets.append(.init(id: next, result: .empty, isCompleted: false,
                                              minTargetRepetitions: nil, maxTargetRepetitions: nil))
        var navigation = WatchWorkoutNavigation()
        navigation.reconcile(snapshot: snapshot)
        navigation.selectExercise(exercise, snapshot: snapshot)
        navigation.selectWorkingSet(exerciseID: exercise, setID: next, snapshot: snapshot)
        XCTAssertEqual(navigation.path, [.currentSet(exercise)])
        XCTAssertEqual(navigation.workingSets[exercise], next)
        navigation.drafts[next]?.weight = 83
        navigation.selectWorkingSet(exerciseID: exercise, setID: next, snapshot: snapshot)
        XCTAssertEqual(navigation.drafts[next]?.weight, 83)
    }
}
