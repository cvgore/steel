import Foundation

public struct WorkoutSetDraft: Codable, Equatable {
    public var weight: Double?
    public var repetitions: Int16?
    public var tag: String?
    public var rpe: Double
    public var comment: String?
    public init(weight: Double?, repetitions: Int16?, tag: String?, rpe: Double, comment: String?) {
        self.weight = weight; self.repetitions = repetitions
        self.tag = tag; self.rpe = rpe; self.comment = comment
    }
}

public struct WorkoutPlannedSet: Codable, Equatable {
    public let id: UUID
    public let draft: WorkoutSetDraft
    public let minTargetRepetitions: Int16?
    public let maxTargetRepetitions: Int16?
    public init(id: UUID = UUID(), draft: WorkoutSetDraft = .empty, minTargetRepetitions: Int16? = nil, maxTargetRepetitions: Int16? = nil) {
        self.id = id; self.draft = draft
        self.minTargetRepetitions = minTargetRepetitions; self.maxTargetRepetitions = maxTargetRepetitions
    }
}

public enum WorkoutSessionPhase: String, Codable {
    case local, joining, agreed, pendingFinish, pendingCancel, finished, cancelled
    public var isTerminal: Bool { self == .finished || self == .cancelled }
    public var occupiesSharedSlot: Bool { self != .local && !isTerminal }
    public var allowsEditing: Bool { self == .local || self == .agreed }
}

public enum WorkoutMutation: Codable, Equatable {
    case saveSet(exerciseID: UUID, setID: UUID, draft: WorkoutSetDraft, complete: Bool, restDuration: TimeInterval)
    case reorderExercises([UUID])
    case reorderSets(exerciseID: UUID, setIDs: [UUID])
    case addExercise(id: UUID, exerciseID: UUID, sets: [WorkoutPlannedSet])
    case removeExercises([UUID])
    case addSet(exerciseID: UUID, set: WorkoutPlannedSet)
    case removeSets(exerciseID: UUID, setIDs: [UUID])
    case exerciseComment(exerciseID: UUID, comment: String?)
    case workoutMetadata(title: String?, comment: String?)
    case workoutTime(start: Date, end: Date?)
    case rest(start: Date?, duration: TimeInterval?)
    case requestFinish
    case requestCancel
}

public struct WorkoutOperation: Codable, Equatable {
    public let id: UUID
    public let workoutID: UUID
    public let sessionID: UUID?
    /// A durable device identity, not a transport message ID. Phone-local commands use "phone".
    public let originID: String
    public let sequence: Int64
    public let predecessorID: UUID?
    public let expectedVersion: Int64
    public let mutation: WorkoutMutation
    public let date: Date

    public init(id: UUID = UUID(), workoutID: UUID, sessionID: UUID? = nil, originID: String = "phone", sequence: Int64 = 0,
                predecessorID: UUID? = nil, expectedVersion: Int64, mutation: WorkoutMutation, date: Date = Date()) {
        self.id = id; self.workoutID = workoutID; self.sessionID = sessionID
        self.originID = originID; self.sequence = sequence; self.predecessorID = predecessorID
        self.expectedVersion = expectedVersion; self.mutation = mutation; self.date = date
    }

    /// Convenience for the existing phone editor; correcting an already completed set never completes it again.
    public init(id: UUID = UUID(), workoutID: UUID, exerciseID: UUID, setID: UUID,
                expectedVersion: Int64, draft: WorkoutSetDraft, date: Date = Date(), restDuration: TimeInterval) {
        self.init(id: id, workoutID: workoutID, expectedVersion: expectedVersion,
                  mutation: .saveSet(exerciseID: exerciseID, setID: setID, draft: draft, complete: true, restDuration: restDuration), date: date)
    }
    public var draft: WorkoutSetDraft? {
        if case let .saveSet(_, _, draft, _, _) = mutation { return draft }; return nil
    }
    public var exerciseID: UUID? {
        if case let .saveSet(id, _, _, _, _) = mutation { return id }; return nil
    }
    public var setID: UUID? {
        if case let .saveSet(_, id, _, _, _) = mutation { return id }; return nil
    }
}

public enum WorkoutOperationDisposition: String, Codable { case applied, conflict, waitingForPredecessor }
public enum WorkoutConflictReason: String, Codable { case staleVersion, predecessorConflict, sessionUnavailable }

public struct WorkoutOperationReceipt: Codable, Equatable {
    public let operationID: UUID
    public let sessionID: UUID
    public let version: Int64
    public let disposition: WorkoutOperationDisposition
    public let reason: WorkoutConflictReason?
    public let didComplete: Bool
    public let restStart: Date?
    public let restDuration: TimeInterval?
    public init(operationID: UUID, sessionID: UUID, version: Int64, disposition: WorkoutOperationDisposition = .applied,
                reason: WorkoutConflictReason? = nil, didComplete: Bool, restStart: Date?, restDuration: TimeInterval?) {
        self.operationID = operationID; self.sessionID = sessionID; self.version = version
        self.disposition = disposition; self.reason = reason; self.didComplete = didComplete
        self.restStart = restStart; self.restDuration = restDuration
    }
}

public struct WorkoutOperationConflict: Codable, Equatable {
    public let operation: WorkoutOperation
    public let receipt: WorkoutOperationReceipt
    public init(operation: WorkoutOperation, receipt: WorkoutOperationReceipt) { self.operation = operation; self.receipt = receipt }
}

public struct WorkoutSessionSnapshot: Codable, Equatable {
    public struct Set: Codable, Equatable {
        public let id: UUID
        public var result: WorkoutSetDraft
        public var isCompleted: Bool
        public let minTargetRepetitions: Int16?
        public let maxTargetRepetitions: Int16?
        public init(id: UUID, result: WorkoutSetDraft, isCompleted: Bool, minTargetRepetitions: Int16?, maxTargetRepetitions: Int16?) {
            self.id = id; self.result = result; self.isCompleted = isCompleted
            self.minTargetRepetitions = minTargetRepetitions; self.maxTargetRepetitions = maxTargetRepetitions
        }
    }
    public struct Exercise: Codable, Equatable {
        public let id: UUID
        public let exerciseID: UUID?
        public var comment: String?
        public var sets: [Set]
        public init(id: UUID, exerciseID: UUID?, comment: String?, sets: [Set]) {
            self.id = id; self.exerciseID = exerciseID; self.comment = comment; self.sets = sets
        }
    }
    public let workoutID: UUID
    public let sessionID: UUID?
    public let version: Int64
    public var phase: WorkoutSessionPhase
    /// Only applied IDs. A receipt alone does not mean a previously received snapshot covers its result.
    public let coveredOperationIDs: [UUID]
    public var title: String?
    public var comment: String?
    public var start: Date?
    public var end: Date?
    public var isCurrentWorkout: Bool
    public var restStart: Date?
    public var restDuration: TimeInterval?
    public var exercises: [Exercise]
    public init(workoutID: UUID, sessionID: UUID?, version: Int64, phase: WorkoutSessionPhase = .local, coveredOperationIDs: [UUID] = [],
                title: String?, comment: String?, start: Date?, end: Date?, isCurrentWorkout: Bool,
                restStart: Date?, restDuration: TimeInterval?, exercises: [Exercise]) {
        self.workoutID = workoutID; self.sessionID = sessionID; self.version = version; self.phase = phase
        self.coveredOperationIDs = coveredOperationIDs; self.title = title; self.comment = comment; self.start = start; self.end = end
        self.isCurrentWorkout = isCurrentWorkout; self.restStart = restStart; self.restDuration = restDuration; self.exercises = exercises
    }
}

extension WorkoutOperation {
    private enum CodingKeys: String, CodingKey {
        case id, workoutID, sessionID, originID, sequence, predecessorID, expectedVersion, mutation, date
        case exerciseID, setID, draft, restDuration
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UUID.self, forKey: .id), workoutID = try c.decode(UUID.self, forKey: .workoutID)
        let version = try c.decode(Int64.self, forKey: .expectedVersion), date = try c.decode(Date.self, forKey: .date)
        if let mutation = try c.decodeIfPresent(WorkoutMutation.self, forKey: .mutation) {
            self.init(id: id, workoutID: workoutID, sessionID: try c.decodeIfPresent(UUID.self, forKey: .sessionID),
                originID: try c.decodeIfPresent(String.self, forKey: .originID) ?? "phone",
                sequence: try c.decodeIfPresent(Int64.self, forKey: .sequence) ?? 0,
                predecessorID: try c.decodeIfPresent(UUID.self, forKey: .predecessorID), expectedVersion: version, mutation: mutation, date: date)
        } else {
            self.init(id: id, workoutID: workoutID, exerciseID: try c.decode(UUID.self, forKey: .exerciseID),
                setID: try c.decode(UUID.self, forKey: .setID), expectedVersion: version,
                draft: try c.decode(WorkoutSetDraft.self, forKey: .draft), date: date, restDuration: try c.decode(Double.self, forKey: .restDuration))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(workoutID, forKey: .workoutID)
        try c.encodeIfPresent(sessionID, forKey: .sessionID); try c.encode(originID, forKey: .originID)
        try c.encode(sequence, forKey: .sequence); try c.encodeIfPresent(predecessorID, forKey: .predecessorID)
        try c.encode(expectedVersion, forKey: .expectedVersion); try c.encode(mutation, forKey: .mutation); try c.encode(date, forKey: .date)
    }
}
extension WorkoutOperationReceipt {
    private enum CodingKeys: String, CodingKey { case operationID, sessionID, version, disposition, reason, didComplete, restStart, restDuration }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(operationID: try c.decode(UUID.self, forKey: .operationID), sessionID: try c.decode(UUID.self, forKey: .sessionID),
            version: try c.decode(Int64.self, forKey: .version), disposition: try c.decodeIfPresent(WorkoutOperationDisposition.self, forKey: .disposition) ?? .applied,
            reason: try c.decodeIfPresent(WorkoutConflictReason.self, forKey: .reason), didComplete: try c.decode(Bool.self, forKey: .didComplete),
            restStart: try c.decodeIfPresent(Date.self, forKey: .restStart), restDuration: try c.decodeIfPresent(Double.self, forKey: .restDuration))
    }
}
