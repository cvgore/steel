import Foundation
#if !os(watchOS)
import WorkoutDataKit
#endif

/// A single owner keeps the accepted phone snapshot and the Watch outbox in one atomic file.
public final class WorkoutReplicaStore {
    /// The app retains one owner. A load failure is exposed, never replaced with an empty outbox.
    public static let shared: Result<WorkoutReplicaStore, Error> = Result { try WorkoutReplicaStore() }
    public enum Failure: Error { case unavailable, wrongSession, terminalRegression, invalidMutation, duplicateID }
    public struct SnapshotConflict: Codable, Equatable {
        public let accepted: WorkoutSessionSnapshot
        public let candidate: WorkoutSessionSnapshot
    }
    public struct ArchivedSession: Codable, Equatable {
        public let acceptedSnapshot: WorkoutSessionSnapshot
        public let snapshot: WorkoutSessionSnapshot
        public let operations: [WorkoutOperation]
        public let receipts: [WorkoutOperationReceipt]
        public let conflicts: [SnapshotConflict]
    }
    public struct State: Codable, Equatable {
        public var originID: String
        public var acceptedSnapshot: WorkoutSessionSnapshot?
        public var snapshot: WorkoutSessionSnapshot?
        public var operations: [WorkoutOperation] = []
        public var receipts: [WorkoutOperationReceipt] = []
        public var conflicts: [SnapshotConflict] = []
        public var localRevision: Int64 = 0
        public var nextSequence: Int64 = 1
        public var agreed = false
        public var terminalSessions: [UUID] = []
        public var archivedSessions: [ArchivedSession] = []
        public var pendingOperations: [WorkoutOperation] {
            operations.filter { op in !receipts.contains { $0.operationID == op.id && $0.disposition != .waitingForPredecessor } }
        }
        public var occupiesSharedSlot: Bool { snapshot?.phase.occupiesSharedSlot ?? false }
    }
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WorkoutReplica/state.json")
    }
    private let lock = NSLock()
    private let url: URL
    private let write: (Data, URL) throws -> Void
    private var value: State
    public var state: State { lock.lock(); defer { lock.unlock() }; return value }
    public var snapshot: WorkoutSessionSnapshot? { state.snapshot }
    public var pendingOperations: [WorkoutOperation] { state.pendingOperations }

    public init(url: URL = WorkoutReplicaStore.defaultURL,
                write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        self.url = url; self.write = write
        if FileManager.default.fileExists(atPath: url.path) {
            value = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
        } else { value = State(originID: UUID().uuidString) }
    }
    private func transaction<T>(_ body: (inout State) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        var candidate = value
        let result = try body(&candidate)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(JSONEncoder().encode(candidate), url)
        value = candidate
        return result
    }
    public func agree(sessionID: UUID) throws {
        try transaction { state in
            guard state.snapshot?.sessionID == sessionID else { throw Failure.unavailable }
            if state.agreed && state.snapshot?.phase == .agreed { return }
            guard state.snapshot?.phase == .joining else { throw Failure.unavailable }
            state.agreed = true; state.snapshot?.phase = .agreed
        }
    }
    public func adopt(snapshot incoming: WorkoutSessionSnapshot) throws {
        try transaction { state in
            guard let session = incoming.sessionID, incoming.phase != .local else { throw Failure.wrongSession }
            if state.terminalSessions.contains(session) && !incoming.phase.isTerminal { throw Failure.terminalRegression }
            if let current = state.acceptedSnapshot {
                if current.sessionID != incoming.sessionID || current.workoutID != incoming.workoutID {
                    guard !state.terminalSessions.contains(session), current.phase.isTerminal,
                          let projected = state.snapshot, projected.phase.isTerminal,
                          state.operations.allSatisfy({ op in
                              current.coveredOperationIDs.contains(op.id) && state.receipts.contains {
                                  $0.operationID == op.id && $0.disposition == .applied
                              }
                          }),
                          state.conflicts.allSatisfy({ $0.accepted.version < current.version }) else { throw Failure.wrongSession }
                    state.archivedSessions.append(.init(acceptedSnapshot: current, snapshot: projected,
                        operations: state.operations, receipts: state.receipts, conflicts: state.conflicts))
                    state.acceptedSnapshot = nil; state.snapshot = nil
                    state.operations = []; state.receipts = []; state.conflicts = []
                    state.nextSequence = 1; state.localRevision = 0; state.agreed = false
                } else {
                    if current.phase.isTerminal && !incoming.phase.isTerminal { throw Failure.terminalRegression }
                    if incoming.version < current.version { return }
                    if incoming.version == current.version && current != incoming {
                        state.conflicts.append(.init(accepted: incoming, candidate: state.snapshot ?? current)); return
                    }
                }
            }
            let previous = state.snapshot
            if let accepted = state.acceptedSnapshot, let previous = previous,
               incoming.version > accepted.version,
               state.operations.contains(where: { !incoming.coveredOperationIDs.contains($0.id) }),
               !Self.isIntermediateCoverage(incoming, after: accepted, operations: state.operations) {
                state.conflicts.append(.init(accepted: incoming, candidate: previous))
            }
            var projected = incoming
            let uncovered = state.operations.filter { !incoming.coveredOperationIDs.contains($0.id) }
            do {
                for op in uncovered { try Self.project(op.mutation, date: op.date, into: &projected) }
            } catch {
                if let previous = previous {
                    state.conflicts.append(.init(accepted: incoming, candidate: previous))
                    projected = previous
                }
            }
            if incoming.phase.isTerminal && !uncovered.isEmpty {
                if let previous = previous { state.conflicts.append(.init(accepted: incoming, candidate: previous)); projected = previous }
            } else if incoming.phase.isTerminal {
                if !state.terminalSessions.contains(session) { state.terminalSessions.append(session) }
            } else if !state.agreed { projected.phase = .joining }
            else if projected.phase == .joining { projected.phase = .agreed }
            state.acceptedSnapshot = incoming; state.snapshot = projected
        }
    }
    @discardableResult public func submit(_ mutation: WorkoutMutation, id: UUID = UUID(), date: Date = Date()) throws -> WorkoutOperation {
        try transaction { state in
            if let existing = state.operations.first(where: { $0.id == id }) {
                guard existing.mutation == mutation else { throw Failure.duplicateID }; return existing
            }
            guard state.agreed, var snapshot = state.snapshot, snapshot.phase == .agreed,
                  let session = snapshot.sessionID, let accepted = state.acceptedSnapshot else { throw Failure.unavailable }
            guard date.timeIntervalSinceReferenceDate.isFinite,
                  state.nextSequence > 0, state.nextSequence < Int64.max,
                  state.localRevision < Int64.max else { throw Failure.invalidMutation }
            let predecessor = state.operations.last.flatMap { accepted.coveredOperationIDs.contains($0.id) ? nil : $0.id }
            let op = WorkoutOperation(id: id, workoutID: snapshot.workoutID, sessionID: session, originID: state.originID,
                sequence: state.nextSequence, predecessorID: predecessor,
                expectedVersion: accepted.version, mutation: mutation, date: date)
            try Self.project(mutation, date: date, into: &snapshot)
            state.snapshot = snapshot; state.operations.append(op)
            state.nextSequence += 1; state.localRevision += 1
            return op
        }
    }
    public func receive(receipt: WorkoutOperationReceipt) throws {
        try transaction { state in
            guard receipt.sessionID == state.snapshot?.sessionID,
                  state.operations.contains(where: { $0.id == receipt.operationID }) else { throw Failure.wrongSession }
            if let old = state.receipts.first(where: { $0.operationID == receipt.operationID }), old.disposition != .waitingForPredecessor { return }
            state.receipts.removeAll { $0.operationID == receipt.operationID }; state.receipts.append(receipt)
        }
    }
    /// A phone snapshot may cover an earlier outbox prefix while its successors are still local.
    /// Verify the covered transition itself before treating the remaining overlay as a conflict.
    private static func isIntermediateCoverage(_ incoming: WorkoutSessionSnapshot,
                                               after accepted: WorkoutSessionSnapshot,
                                               operations: [WorkoutOperation]) -> Bool {
        let newlyCovered = operations.filter {
            incoming.coveredOperationIDs.contains($0.id) && !accepted.coveredOperationIDs.contains($0.id)
        }
        guard !newlyCovered.isEmpty else { return false }
        let (version, overflow) = accepted.version.addingReportingOverflow(Int64(newlyCovered.count))
        guard !overflow, incoming.version == version,
              Set(accepted.coveredOperationIDs).isSubset(of: Set(incoming.coveredOperationIDs)) else { return false }
        var expected = accepted
        do {
            for op in newlyCovered { try project(op.mutation, date: op.date, into: &expected) }
        } catch { return false }
        // Version and coverage are envelope fields; all domain fields must match the covered edits.
        let normalized = WorkoutSessionSnapshot(workoutID: expected.workoutID, sessionID: expected.sessionID,
            version: incoming.version, phase: expected.phase, coveredOperationIDs: incoming.coveredOperationIDs,
            title: expected.title, comment: expected.comment, start: expected.start, end: expected.end,
            isCurrentWorkout: expected.isCurrentWorkout, restStart: expected.restStart,
            restDuration: expected.restDuration, exercises: expected.exercises)
        return normalized == incoming
    }
    private static func project(_ mutation: WorkoutMutation, date: Date, into s: inout WorkoutSessionSnapshot) throws {
        switch mutation {
        case let .saveSet(exerciseID, setID, draft, complete, restDuration):
            guard WorkoutEditingRules.isValid(draft), restDuration.isFinite, restDuration >= 0,
                  let e = s.exercises.firstIndex(where: { $0.id == exerciseID }),
                  let i = s.exercises[e].sets.firstIndex(where: { $0.id == setID }) else { throw Failure.invalidMutation }
            let completing = complete && !s.exercises[e].sets[i].isCompleted
            s.exercises[e].sets[i].result = draft
            if completing {
                s.exercises[e].sets[i].isCompleted = true
                if s.start == nil { s.start = date }
                s.restStart = date; s.restDuration = restDuration
                let begun = Set(s.exercises.filter { $0.sets.contains(where: { $0.isCompleted }) }.map(\.id))
                let order = WorkoutEditingRules.orderAfterCompletion(exerciseID: exerciseID,
                    order: s.exercises.map(\.id), begun: begun)
                let exercises = s.exercises
                s.exercises = order.map { id in exercises.first { $0.id == id }! }
            }
        case let .reorderExercises(ids):
            guard WorkoutEditingRules.isPermutation(ids, of: s.exercises.map(\.id)) else { throw Failure.invalidMutation }
            s.exercises = ids.map { id in s.exercises.first { $0.id == id }! }
        case let .reorderSets(exerciseID, ids):
            guard let e = s.exercises.firstIndex(where: { $0.id == exerciseID }),
                  WorkoutEditingRules.isPermutation(ids, of: s.exercises[e].sets.map(\.id)) else { throw Failure.invalidMutation }
            let sets = s.exercises[e].sets; s.exercises[e].sets = ids.map { id in sets.first { $0.id == id }! }
        case let .exerciseComment(id, comment):
            guard let e = s.exercises.firstIndex(where: { $0.id == id }) else { throw Failure.invalidMutation }
            s.exercises[e].comment = comment
        case let .workoutMetadata(title, comment): s.title = title; s.comment = comment
        case let .workoutTime(start, end):
            guard start.timeIntervalSinceReferenceDate.isFinite,
                  end.map({ $0.timeIntervalSinceReferenceDate.isFinite && $0 >= start }) ?? true else { throw Failure.invalidMutation }
            s.start = start; s.end = end
        case let .rest(start, duration):
            guard (start == nil) == (duration == nil),
                  start.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
                  duration.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw Failure.invalidMutation }
            s.restStart = start; s.restDuration = duration
        case .requestFinish: s.phase = .pendingFinish
        case .requestCancel: s.phase = .pendingCancel
        case .addExercise, .removeExercises, .addSet, .removeSets: throw Failure.invalidMutation
        }
    }
}
