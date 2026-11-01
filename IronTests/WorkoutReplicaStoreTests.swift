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
