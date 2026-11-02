import Foundation

/// Domain limits/defaults shared by phone persistence and Watch without managed objects.
public enum WorkoutEditingRules {
    public static let maximumWeight: Double = 99999
    public static let maximumRepetitions: Int16 = 9999
    public static let defaultRepetitions: Int16 = 5
    public static let allowedRPE = Array(stride(from: 7.0, through: 10.0, by: 0.5))
    public static func isValid(_ draft: WorkoutSetDraft) -> Bool {
        (draft.weight.map { $0.isFinite && $0 >= 0 && $0 <= maximumWeight } ?? true) &&
        (draft.repetitions.map { $0 >= 0 && $0 <= maximumRepetitions } ?? true) &&
        (draft.rpe == 0 || allowedRPE.contains(draft.rpe)) &&
        (draft.tag == nil || draft.tag == "failure" || draft.tag == "dropSet")
    }
    public static func isComplete(_ exercise: WorkoutSessionSnapshot.Exercise) -> Bool {
        !exercise.sets.isEmpty && exercise.sets.allSatisfy(\.isCompleted)
    }
    public static func isPermutation(_ proposed: [UUID], of existing: [UUID]) -> Bool {
        proposed.count == existing.count && Set(proposed).count == proposed.count && Set(proposed) == Set(existing)
    }
}
extension WorkoutSetDraft {
    public static var empty: WorkoutSetDraft { .init(weight: nil, repetitions: nil, tag: nil, rpe: 0, comment: nil) }
}
extension WorkoutEditingRules {
    public static func orderAfterCompletion(exerciseID: UUID, order: [UUID], begun: Set<UUID>) -> [UUID] {
        guard order.contains(exerciseID) else { return order }
        var remaining = order.filter { $0 != exerciseID }
        let index = remaining.lastIndex(where: { begun.contains($0) }).map { $0 + 1 } ?? 0
        remaining.insert(exerciseID, at: index)
        return remaining
    }
}

extension WorkoutEditingRules {
    public static func initialDraft(result: WorkoutSetDraft, completed: Bool, index: Int,
                                    current: [WorkoutSetDraft], history: [[WorkoutNumericResult]],
                                    barbellWeight: Double?) -> WorkoutSetDraft {
        guard !completed, result.weight == nil || result.repetitions == nil,
              current.indices.contains(index) else { return result }
        let previous: WorkoutNumericResult?
        if index > 0 {
            let matched = history.first { row in
                row.indices.contains(index) && (0..<index).allSatisfy {
                    row[$0].weight == (current[$0].weight ?? 0) && row[$0].repetitions == (current[$0].repetitions ?? 0)
                }
            }
            previous = matched?[index] ?? .init(weight: current[index - 1].weight ?? 0, repetitions: current[index - 1].repetitions ?? 0)
        } else { previous = history.first?.first }
        var draft = result
        if let previous = previous {
            draft.weight = previous.weight; draft.repetitions = previous.repetitions
        } else {
            draft.repetitions = defaultRepetitions
            if let barbellWeight = barbellWeight { draft.weight = barbellWeight }
        }
        return draft
    }
}

extension WorkoutSessionSnapshot {
    public func editorDraft(exerciseID: UUID, setID: UUID) -> WorkoutSetDraft? {
        guard let exercise = exercises.first(where: { $0.id == exerciseID }),
              let index = exercise.sets.firstIndex(where: { $0.id == setID }) else { return nil }
        let defaults = editorContext?.exercises.first { $0.id == exerciseID }
        return WorkoutEditingRules.initialDraft(result: exercise.sets[index].result,
            completed: exercise.sets[index].isCompleted, index: index,
            current: exercise.sets.map(\.result), history: defaults?.numericHistory ?? [],
            barbellWeight: defaults?.barbellWeight)
    }
}

/// Watch-only presentation context. It never travels in workout synchronization messages.
public struct WatchWorkoutNavigation: Codable, Equatable {
    public enum Page: String, Codable, Hashable { case finish, workout, measurements, nowPlaying }
    public enum Route: Codable, Hashable {
        case currentSet(UUID)
        case sets(UUID)
        case correction(exerciseID: UUID, setID: UUID)
    }
    public private(set) var sessionID: UUID?
    public var page: Page = .workout
    public var path: [Route] = []
    public private(set) var workingSets: [UUID: UUID] = [:]
    public var drafts: [UUID: WorkoutSetDraft] = [:]
    public var correctionDraft: WorkoutSetDraft?

    public init() {}

    public static func canPresentWorkout(snapshot: WorkoutSessionSnapshot?, agreed: Bool) -> Bool {
        guard agreed, let snapshot = snapshot, snapshot.sessionID != nil, snapshot.isCurrentWorkout else { return false }
        return snapshot.phase == .agreed || snapshot.phase == .pendingFinish || snapshot.phase == .pendingCancel
    }

    public mutating func selectWorkingSet(exerciseID: UUID, setID: UUID, snapshot: WorkoutSessionSnapshot) {
        guard let draft = snapshot.editorDraft(exerciseID: exerciseID, setID: setID) else { return }
        workingSets[exerciseID] = setID
        if drafts[setID] == nil { drafts[setID] = draft }
    }

    public mutating func reconcile(snapshot: WorkoutSessionSnapshot?) {
        guard let snapshot = snapshot, let id = snapshot.sessionID, !snapshot.phase.isTerminal else {
            self = Self(); return
        }
        if sessionID != id { self = Self(); sessionID = id }
        let sets = Set(snapshot.exercises.flatMap { $0.sets.map(\.id) })
        drafts = drafts.filter { sets.contains($0.key) }
        workingSets = workingSets.filter { exerciseID, setID in
            snapshot.exercises.contains { $0.id == exerciseID && $0.sets.contains { $0.id == setID } }
        }
        // Keep an open exercise usable when its selected set disappears or its first set arrives.
        for exercise in snapshot.exercises where workingSets[exercise.id] == nil && path.contains(.currentSet(exercise.id)) {
            if let set = exercise.sets.first(where: { !$0.isCompleted }) ?? exercise.sets.last {
                selectWorkingSet(exerciseID: exercise.id, setID: set.id, snapshot: snapshot)
            }
        }
        // A remote reorder or result update does not navigate. Only removed identities trim the stack.
        let valid = path.prefix { route in
            switch route {
            case .currentSet(let id), .sets(let id): return snapshot.exercises.contains { $0.id == id }
            case let .correction(exerciseID, setID):
                return snapshot.exercises.contains { $0.id == exerciseID && $0.sets.contains { $0.id == setID } }
            }
        }
        setPath(Array(valid))
    }

    public mutating func selectExercise(_ id: UUID, snapshot: WorkoutSessionSnapshot) {
        guard let exercise = snapshot.exercises.first(where: { $0.id == id }) else { return }
        if workingSets[id] == nil, let set = exercise.sets.first(where: { !$0.isCompleted }) ?? exercise.sets.last {
            workingSets[id] = set.id
        }
        if let setID = workingSets[id], drafts[setID] == nil {
            drafts[setID] = snapshot.editorDraft(exerciseID: id, setID: setID)
        }
        setPath([.currentSet(id)])
    }

    public mutating func showCorrection(exerciseID: UUID, setID: UUID, snapshot: WorkoutSessionSnapshot) {
        guard let exercise = snapshot.exercises.first(where: { $0.id == exerciseID }),
              let set = exercise.sets.first(where: { $0.id == setID && $0.isCompleted }) else { return }
        correctionDraft = set.result
        path = [.currentSet(exerciseID), .sets(exerciseID), .correction(exerciseID: exerciseID, setID: setID)]
    }

    /// Native Back discards a correction; paging never changes the path or drafts.
    public mutating func setPath(_ newPath: [Route]) {
        if path.last != newPath.last { correctionDraft = nil }
        path = newPath
    }
}
