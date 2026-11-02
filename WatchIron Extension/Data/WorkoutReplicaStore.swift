import Foundation
#if !os(watchOS)
import WorkoutDataKit
#endif

/// A single owner keeps the accepted phone snapshot and the Watch outbox in one atomic file.
public final class WorkoutReplicaStore {
    /// The app retains one owner. A load failure is exposed, never replaced with an empty outbox.
    public static let shared: Result<WorkoutReplicaStore, Error> = Result { try WorkoutReplicaStore() }
    public enum Failure: Error { case unavailable, wrongSession, terminalRegression, invalidMutation, duplicateID, changedSet }
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
    public enum HealthEffect: String, Codable { case pending, saving, saved, blocked, uncertain, discarded }
    public struct State: Codable, Equatable {
        public var deferredTrackingStarts: [UUID: Date]?
        public var deferredSnapshot: WorkoutSessionSnapshot?
        public var healthEffects: [UUID: HealthEffect]?
        public var originID: String
        public var acceptedSnapshot: WorkoutSessionSnapshot?
        public var snapshot: WorkoutSessionSnapshot?
        public var operations: [WorkoutOperation] = []
        public var receipts: [WorkoutOperationReceipt] = []
        public var conflicts: [SnapshotConflict] = []
        public var pendingCompletion: WatchWorkoutNavigation.PendingCompletion?
        public var localNavigation: WatchWorkoutNavigation?
        public var localRevision: Int64 = 0
        public var nextSequence: Int64 = 1
        public var agreed = false
        public var terminalSessions: [UUID] = []
        public var archivedSessions: [ArchivedSession] = []
        public var pendingOperations: [WorkoutOperation] {
            operations.filter { op in !receipts.contains { $0.operationID == op.id && $0.disposition != .waitingForPredecessor } }
        }
        fileprivate mutating func retainConflict(accepted: WorkoutSessionSnapshot, candidate: WorkoutSessionSnapshot) {
            let conflict = SnapshotConflict(accepted: accepted, candidate: candidate)
            if !conflicts.contains(conflict) { conflicts.append(conflict) }
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
    public func adopt(snapshot received: WorkoutSessionSnapshot) throws {
        try transaction { state in
            var incoming = received
            guard let session = incoming.sessionID, incoming.phase != .local else { throw Failure.wrongSession }
            if state.terminalSessions.contains(session) && !incoming.phase.isTerminal { throw Failure.terminalRegression }
            if let current = state.acceptedSnapshot {
                if current.sessionID != incoming.sessionID || current.workoutID != incoming.workoutID {
                    guard !state.terminalSessions.contains(session), current.phase.isTerminal,
                          let projected = state.snapshot, projected.phase.isTerminal,
                          state.operations.allSatisfy({ op in
                              (current.coveredOperationIDs.contains(op.id) || (current.resolvedOperationIDs ?? []).contains(op.id)) && state.receipts.contains {
                                  $0.operationID == op.id && $0.disposition != .waitingForPredecessor
                              }
                          }),
                          state.conflicts.allSatisfy({ $0.accepted.version < current.version }) else { throw Failure.wrongSession }
                    state.archivedSessions.append(.init(acceptedSnapshot: current, snapshot: projected,
                        operations: state.operations, receipts: state.receipts, conflicts: state.conflicts))
                    state.acceptedSnapshot = nil; state.snapshot = nil
                    state.operations = []; state.receipts = []; state.conflicts = []; state.pendingCompletion = nil; state.localNavigation = nil
                    state.nextSequence = 1; state.localRevision = 0; state.agreed = false
                } else {
                    if current.phase.isTerminal && !incoming.phase.isTerminal { throw Failure.terminalRegression }
                    if incoming.version < current.version { return }
                    if incoming.version == current.version && current.domainSnapshot != incoming.domainSnapshot {
                        state.retainConflict(accepted: incoming, candidate: state.snapshot ?? current); return
                    }
                }
            }
            // Conflict metadata can arrive after another snapshot at the same domain version.
            // Only an explicit durable resolution removes a previously advertised candidate.
            let unresolved = Swift.Set(state.acceptedSnapshot?.unresolvedConflictIDs ?? [])
                .union(incoming.unresolvedConflictIDs ?? []).subtracting(incoming.resolvedOperationIDs ?? [])
            incoming.unresolvedConflictIDs = unresolved.isEmpty ? nil : unresolved.sorted { $0.uuidString < $1.uuidString }
            let previous = state.snapshot
            if let accepted = state.acceptedSnapshot, let previous = previous,
               incoming.version > accepted.version,
               state.operations.contains(where: { !incoming.coveredOperationIDs.contains($0.id) && !(incoming.resolvedOperationIDs ?? []).contains($0.id) }),
               !Self.isIntermediateCoverage(incoming, after: accepted, operations: state.operations) {
                state.retainConflict(accepted: incoming, candidate: previous)
            }
            var projected = incoming
            let uncovered = state.operations.filter { !incoming.coveredOperationIDs.contains($0.id) && !(incoming.resolvedOperationIDs ?? []).contains($0.id) }
            do {
                for op in uncovered { try Self.project(op.mutation, date: op.date, into: &projected) }
            } catch {
                if let previous = previous {
                    state.retainConflict(accepted: incoming, candidate: previous)
                    projected = previous
                }
            }
            if incoming.phase.isTerminal && !uncovered.isEmpty {
                if let previous = previous { state.retainConflict(accepted: incoming, candidate: previous); projected = previous }
            } else if incoming.phase.isTerminal {
                if !state.terminalSessions.contains(session) { state.terminalSessions.append(session) }
                state.deferredTrackingStarts?.removeValue(forKey: incoming.workoutID)
                if state.healthEffects == nil { state.healthEffects = [:] }
                if state.healthEffects?[incoming.workoutID] == nil { state.healthEffects?[incoming.workoutID] = .pending }
            } else if !state.agreed { projected.phase = .joining }
            else if projected.phase == .joining { projected.phase = .agreed }
            state.acceptedSnapshot = incoming; state.snapshot = projected
            if state.deferredSnapshot?.sessionID == incoming.sessionID { state.deferredSnapshot = nil }
        }
    }
    @discardableResult public func submit(_ mutation: WorkoutMutation, id: UUID = UUID(), date: Date = Date(), expectedSetResult: WorkoutSetDraft? = nil, trackCompletion: Bool = false, navigation: WatchWorkoutNavigation? = nil) throws -> WorkoutOperation {
        try transaction { state in
            if let existing = state.operations.first(where: { $0.id == id }) {
                guard existing.mutation == mutation else { throw Failure.duplicateID }; return existing
            }
            guard state.agreed, var snapshot = state.snapshot, snapshot.phase == .agreed,
                  let session = snapshot.sessionID, let accepted = state.acceptedSnapshot else { throw Failure.unavailable }
            if trackCompletion {
                guard case let .saveSet(exerciseID, setID, _, true, _) = mutation,
                      let set = snapshot.exercises.first(where: { $0.id == exerciseID })?.sets.first(where: { $0.id == setID }),
                      !set.isCompleted else { throw Failure.changedSet }
            }
            if let expected = expectedSetResult {
                guard case let .saveSet(exerciseID, setID, _, _, _) = mutation,
                      let set = snapshot.exercises.first(where: { $0.id == exerciseID })?.sets.first(where: { $0.id == setID }),
                      set.isCompleted, set.result == expected else { throw Failure.changedSet }
            }
            guard date.timeIntervalSinceReferenceDate.isFinite,
                  state.nextSequence > 0, state.nextSequence < Int64.max,
                  state.localRevision < Int64.max else { throw Failure.invalidMutation }
            // Partial coverage advances the snapshot without rebasing its uncovered suffix.
            let predecessor = state.operations.last.flatMap { (accepted.coveredOperationIDs.contains($0.id) || (accepted.resolvedOperationIDs ?? []).contains($0.id)) ? nil : $0 }
            let op = WorkoutOperation(id: id, workoutID: snapshot.workoutID, sessionID: session, originID: state.originID,
                sequence: state.nextSequence, predecessorID: predecessor?.id,
                expectedVersion: predecessor?.expectedVersion ?? accepted.version, mutation: mutation, date: date)
            try Self.project(mutation, date: date, into: &snapshot)
            state.snapshot = snapshot; state.operations.append(op)
            if trackCompletion {
                guard case let .saveSet(exerciseID, setID, _, true, _) = mutation else { throw Failure.invalidMutation }
                state.pendingCompletion = .init(operationID: id, exerciseID: exerciseID, setID: setID)
                if let navigation = navigation { state.localNavigation = navigation }
            }
            state.nextSequence += 1; state.localRevision += 1
            return op
        }
    }
    public func saveNavigation(_ navigation: WatchWorkoutNavigation, clearingCompletion: Bool = false) throws {
        try transaction { state in
            state.localNavigation = navigation
            if clearingCompletion { state.pendingCompletion = nil }
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
        var normalized = WorkoutSessionSnapshot(workoutID: expected.workoutID, sessionID: expected.sessionID,
            version: incoming.version, phase: expected.phase, coveredOperationIDs: incoming.coveredOperationIDs,
            title: expected.title, comment: expected.comment, start: expected.start, end: expected.end,
            isCurrentWorkout: expected.isCurrentWorkout, restStart: expected.restStart,
            restDuration: expected.restDuration, exercises: expected.exercises)
        normalized.resolvedOperationIDs = expected.resolvedOperationIDs
        return normalized.domainSnapshot == incoming.domainSnapshot
    }
    private static func project(_ mutation: WorkoutMutation, date: Date, into s: inout WorkoutSessionSnapshot) throws {
        switch mutation {
        case let .saveSet(exerciseID, setID, draft, complete, restDuration):
            guard WorkoutEditingRules.isValid(draft), restDuration.isFinite, restDuration >= 0,
                  let e = s.exercises.firstIndex(where: { $0.id == exerciseID }),
                  let i = s.exercises[e].sets.firstIndex(where: { $0.id == setID }) else { throw Failure.invalidMutation }
            let completing = complete && !s.exercises[e].sets[i].isCompleted
            for index in s.exercises[e].sets.indices { s.exercises[e].sets[index].isPersonalRecord = nil }
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
        case .requestFinish:
            s.phase = .pendingFinish
            s.end = s.end ?? max(s.start ?? date, date)
        case .requestCancel: s.phase = .pendingCancel
        case .addExercise, .removeExercises, .addSet, .removeSets, .resolveConflict: throw Failure.invalidMutation
        }
    }
}

extension WorkoutReplicaStore {
    /// A join response proves local persistence, not permission to edit yet.
    public func receiveSync(_ message: WorkoutSyncMessage) throws -> WorkoutSyncMessage? {
        let incoming: WorkoutSessionSnapshot
        switch message {
        case let .snapshot(snapshot): incoming = snapshot
        case let .update(snapshot, receipts):
            incoming = snapshot
            for receipt in receipts where state.operations.contains(where: { $0.id == receipt.operationID }) {
                try receive(receipt: receipt)
            }
        default: throw Failure.invalidMutation
        }
        do { try adopt(snapshot: incoming) }
        catch Failure.wrongSession {
            // A new join can overtake the old terminal reply. Retain the offer while recovering
            // the old session; never replace its pending results to make room for the new one.
            let current = state
            guard incoming.phase == .joining, let session = incoming.sessionID,
                  !current.terminalSessions.contains(session), let active = current.acceptedSnapshot,
                  active.sessionID != session else { throw Failure.wrongSession }
            try transaction { $0.deferredSnapshot = incoming }
            return .request(workoutID: active.workoutID, sessionID: active.sessionID)
        }
        if incoming.phase.isTerminal, let deferred = state.deferredSnapshot {
            do {
                try adopt(snapshot: deferred)
                return .joined(workoutID: deferred.workoutID, sessionID: deferred.sessionID!)
            } catch Failure.wrongSession {
                // Coverage may precede its receipts. Retry the old session until both arrive.
                return .request(workoutID: incoming.workoutID, sessionID: incoming.sessionID)
            }
        }
        guard let sessionID = incoming.sessionID else { throw Failure.wrongSession }
        if incoming.phase == .joining {
            return .joined(workoutID: incoming.workoutID, sessionID: sessionID)
        }
        if [.agreed, .pendingFinish, .pendingCancel].contains(incoming.phase) && !state.agreed {
            try agree(sessionID: sessionID)
            if incoming.phase != .agreed { try adopt(snapshot: incoming) }
        }
        return terminalReadiness
    }
}


extension WorkoutReplicaStore {
    public func allowsTrackingStart(workoutID: UUID) -> Bool {
        let state = state
        if let current = state.snapshot {
            if current.workoutID == workoutID { return !current.phase.isTerminal }
            if current.phase.occupiesSharedSlot { return false }
        }
        return !state.archivedSessions.contains { $0.acceptedSnapshot.workoutID == workoutID }
    }
}

extension WorkoutReplicaStore {
    public var terminalReadiness: WorkoutSyncMessage? {
        let state = state
        guard let accepted = state.acceptedSnapshot, let sessionID = accepted.sessionID,
              [.pendingFinish, .pendingCancel].contains(accepted.phase), state.snapshot?.phase == accepted.phase,
              (accepted.unresolvedConflictIDs ?? []).isEmpty,
              state.operations.allSatisfy({ op in
                  (accepted.coveredOperationIDs.contains(op.id) || (accepted.resolvedOperationIDs ?? []).contains(op.id)) &&
                  state.receipts.contains { $0.operationID == op.id && $0.disposition != .waitingForPredecessor }
              }) else { return nil }
        return .terminalReady(workoutID: accepted.workoutID, sessionID: sessionID, version: accepted.version)
    }

    /// Persist intent before invoking HealthKit. An uncertain attempt is never automatically retried.
    public func claimHealthEffect(workoutID: UUID) throws -> Bool {
        try transaction { state in
            let terminal = state.acceptedSnapshot?.workoutID == workoutID && state.acceptedSnapshot?.phase.isTerminal == true ||
                state.archivedSessions.contains { $0.acceptedSnapshot.workoutID == workoutID && $0.acceptedSnapshot.phase.isTerminal }
            guard terminal, state.healthEffects?[workoutID] == nil || state.healthEffects?[workoutID] == .pending else { return false }
            if state.healthEffects == nil { state.healthEffects = [:] }
            state.healthEffects?[workoutID] = .saving
            return true
        }
    }
    public func recordHealthEffect(_ effect: HealthEffect, workoutID: UUID) throws {
        try transaction { state in
            if state.healthEffects == nil { state.healthEffects = [:] }
            state.healthEffects?[workoutID] = effect
        }
    }
    public func retryBlockedHealthEffect(workoutID: UUID) throws {
        try transaction { state in
            guard state.healthEffects?[workoutID] == .blocked else { return }
            state.healthEffects?[workoutID] = .pending
        }
    }
}


extension WorkoutReplicaStore {
    /// Probe every uncertain effect independently; one unreadable older sample cannot starve another.
    /// A negative query is deliberately not a retry authorization.
    public func recoverHealthEffects(excluding activeIDs: Set<UUID> = [],
        findSaved: (UUID, @escaping (Bool) -> Void) -> Void,
        completion: @escaping (UUID, Result<Void, Error>) -> Void) {
        let effects = state.healthEffects ?? [:]
        for (id, effect) in effects where !activeIDs.contains(id) && [.saving, .uncertain].contains(effect) {
            findSaved(id) { found in
                let result = Result { try self.recordHealthEffect(found ? .saved : .uncertain, workoutID: id) }
                completion(id, result)
            }
        }
    }
}


extension WorkoutReplicaStore {
    /// Legacy measurement-start delivery can overtake journal reconciliation; persist it in the same replica.
    public func retainTrackingStart(workoutID: UUID, start: Date) throws {
        try transaction { state in
            guard start.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalidMutation }
            if state.snapshot?.workoutID == workoutID && state.snapshot?.phase.isTerminal == true ||
                state.archivedSessions.contains(where: { $0.acceptedSnapshot.workoutID == workoutID }) { return }
            if state.deferredTrackingStarts == nil { state.deferredTrackingStarts = [:] }
            state.deferredTrackingStarts?[workoutID] = start
        }
    }
    public var trackingStartToResume: (workoutID: UUID, start: Date)? {
        let state = state
        guard let snapshot = state.snapshot else {
            guard state.deferredTrackingStarts?.count == 1, let request = state.deferredTrackingStarts?.first else { return nil }
            return (request.key, request.value)
        }
        guard !snapshot.phase.isTerminal, let start = state.deferredTrackingStarts?[snapshot.workoutID] else { return nil }
        return (snapshot.workoutID, snapshot.start ?? start)
    }
    public func acknowledgeTrackingStart(workoutID: UUID) throws {
        try transaction { $0.deferredTrackingStarts?.removeValue(forKey: workoutID) }
    }
}
