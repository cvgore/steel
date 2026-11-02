import CoreData

public enum WorkoutOperationError: Error {
    case missingObject, invalidPayload, staleVersion, operationIDCollision, invalidSession, occupiedSession, unresolvedOperations
}

extension WorkoutSetDraft {
    public init(set: WorkoutSet) {
        self.init(weight: set.weight?.doubleValue, repetitions: set.repetitions?.int16Value,
                  tag: set.tag, rpe: set.rpe, comment: set.comment)
    }
}

/// One persistent save owns graph changes, version, absolute rest and operation disposition.
public final class WorkoutOperationStore {
    private let coordinator: NSPersistentStoreCoordinator
    private let beforeSave: (NSManagedObjectContext) throws -> Void
    private static let lock = NSLock()

    public init(coordinator: NSPersistentStoreCoordinator) {
        self.coordinator = coordinator; beforeSave = { _ in }
    }
    internal init(coordinator: NSPersistentStoreCoordinator, beforeSave: @escaping (NSManagedObjectContext) throws -> Void) {
        self.coordinator = coordinator; self.beforeSave = beforeSave
    }
    private func transaction<T>(mergingInto viewContext: NSManagedObjectContext? = nil,
                                _ action: (NSManagedObjectContext) throws -> T) throws -> T {
        var notification: Notification?
        Self.lock.lock()
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.mergePolicy = NSErrorMergePolicy
        let result: T
        do {
            result = try context.performAndWait {
                let observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave, object: context, queue: nil) { notification = $0 }
                defer { NotificationCenter.default.removeObserver(observer) }
                do { return try action(context) }
                catch { context.rollback(); throw error }
            }
        } catch { Self.lock.unlock(); throw error }
        Self.lock.unlock()
        if let notification = notification, let viewContext = viewContext {
            viewContext.performAndWait { viewContext.mergeChanges(fromContextDidSave: notification) }
        }
        return result
    }
    private func save(_ context: NSManagedObjectContext) throws {
        try beforeSave(context)
        try context.save()
    }
    private func record(_ entity: String, key: String, id: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = NSPredicate(format: "%K == %@", key, id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }
    private func workout(_ id: UUID, in context: NSManagedObjectContext) throws -> Workout {
        guard let value = try record("Workout", key: "uuid", id: id, in: context) as? Workout else { throw WorkoutOperationError.missingObject }
        return value
    }
    private func exercise(_ id: UUID, workout: Workout, in context: NSManagedObjectContext) throws -> WorkoutExercise {
        guard let value = try record("WorkoutExercise", key: "uuid", id: id, in: context) as? WorkoutExercise,
              value.workout == workout else { throw WorkoutOperationError.missingObject }
        return value
    }
    private func set(_ id: UUID, exercise: WorkoutExercise, in context: NSManagedObjectContext) throws -> WorkoutSet {
        guard let value = try record("WorkoutSet", key: "uuid", id: id, in: context) as? WorkoutSet,
              value.workoutExercise == exercise else { throw WorkoutOperationError.missingObject }
        return value
    }
    private func session(_ id: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject {
        if let value = try record("WorkoutSessionState", key: "workoutID", id: id, in: context) { return value }
        let value = NSEntityDescription.insertNewObject(forEntityName: "WorkoutSessionState", into: context)
        value.setValue(id, forKey: "workoutID"); value.setValue(UUID(), forKey: "sessionID")
        value.setValue(WorkoutSessionPhase.local.rawValue, forKey: "phase")
        return value
    }
    private func version(_ session: NSManagedObject) -> Int64 { (session.value(forKey: "version") as? NSNumber)?.int64Value ?? 0 }
    private func phase(_ session: NSManagedObject) throws -> WorkoutSessionPhase {
        guard let value = WorkoutSessionPhase(rawValue: session.value(forKey: "phase") as? String ?? "local") else { throw WorkoutOperationError.invalidSession }
        return value
    }
    private func storedOperations(_ context: NSManagedObjectContext) throws -> [(NSManagedObject, WorkoutOperation, WorkoutOperationReceipt)] {
        try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorkoutAppliedOperation")).map { record in
            guard let payload = record.value(forKey: "payload") as? Data, let receipt = record.value(forKey: "receipt") as? Data else {
                throw WorkoutOperationError.invalidPayload
            }
            return try (record, JSONDecoder().decode(WorkoutOperation.self, from: payload), JSONDecoder().decode(WorkoutOperationReceipt.self, from: receipt))
        }
    }
    private func validateScalars(_ mutation: WorkoutMutation) throws {
        func planned(_ set: WorkoutPlannedSet) throws {
            guard WorkoutEditingRules.isValid(set.draft),
                  set.minTargetRepetitions.map({ $0 >= 0 && $0 <= WorkoutEditingRules.maximumRepetitions }) ?? true,
                  set.maxTargetRepetitions.map({ $0 >= 0 && $0 <= WorkoutEditingRules.maximumRepetitions }) ?? true,
                  (set.minTargetRepetitions ?? 0) <= (set.maxTargetRepetitions ?? WorkoutEditingRules.maximumRepetitions) else { throw WorkoutOperationError.invalidPayload }
        }
        func distinct(_ ids: [UUID], nonempty: Bool = false) throws {
            guard Set(ids).count == ids.count, !nonempty || !ids.isEmpty else { throw WorkoutOperationError.invalidPayload }
        }
        switch mutation {
        case let .saveSet(_, _, draft, _, duration):
            guard WorkoutEditingRules.isValid(draft), duration.isFinite, duration >= 0 else { throw WorkoutOperationError.invalidPayload }
        case let .addExercise(_, _, sets): try distinct(sets.map(\.id)); try sets.forEach(planned)
        case let .addSet(_, set): try planned(set)
        case let .reorderExercises(ids), let .reorderSets(_, ids): try distinct(ids)
        case let .removeExercises(ids), let .removeSets(_, ids): try distinct(ids, nonempty: true)
        case let .rest(start, duration):
            guard (start == nil) == (duration == nil), start.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
                  duration.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw WorkoutOperationError.invalidPayload }
        case let .workoutTime(start, end):
            guard start.timeIntervalSinceReferenceDate.isFinite,
                  end.map({ $0.timeIntervalSinceReferenceDate.isFinite && $0 >= start }) ?? true else { throw WorkoutOperationError.invalidPayload }
        case .exerciseComment, .workoutMetadata, .requestFinish, .requestCancel: break
        }
    }
    private func validate(_ mutation: WorkoutMutation, workout: Workout, context: NSManagedObjectContext) throws {
        func validSet(_ planned: WorkoutPlannedSet) throws {
            guard WorkoutEditingRules.isValid(planned.draft),
                  planned.minTargetRepetitions.map({ $0 >= 0 && $0 <= WorkoutEditingRules.maximumRepetitions }) ?? true,
                  planned.maxTargetRepetitions.map({ $0 >= 0 && $0 <= WorkoutEditingRules.maximumRepetitions }) ?? true,
                  (planned.minTargetRepetitions ?? 0) <= (planned.maxTargetRepetitions ?? WorkoutEditingRules.maximumRepetitions),
                  try record("WorkoutSet", key: "uuid", id: planned.id, in: context) == nil else { throw WorkoutOperationError.invalidPayload }
        }
        switch mutation {
        case let .saveSet(exerciseID, setID, draft, _, duration):
            guard WorkoutEditingRules.isValid(draft), duration.isFinite, duration >= 0 else { throw WorkoutOperationError.invalidPayload }
            let parent = try exercise(exerciseID, workout: workout, in: context)
            _ = try set(setID, exercise: parent, in: context)
        case let .reorderExercises(ids):
            guard WorkoutEditingRules.isPermutation(ids, of: workout.workoutExercises?.compactMap { ($0 as? WorkoutExercise)?.uuid } ?? []) else { throw WorkoutOperationError.invalidPayload }
        case let .reorderSets(exerciseID, ids):
            let parent = try exercise(exerciseID, workout: workout, in: context)
            guard WorkoutEditingRules.isPermutation(ids, of: parent.workoutSets?.compactMap { ($0 as? WorkoutSet)?.uuid } ?? []) else { throw WorkoutOperationError.invalidPayload }
        case let .addExercise(id, _, sets):
            guard try record("WorkoutExercise", key: "uuid", id: id, in: context) == nil,
                  Set(sets.map(\.id)).count == sets.count else { throw WorkoutOperationError.invalidPayload }
            try sets.forEach(validSet)
        case let .removeExercises(ids):
            guard !ids.isEmpty, Set(ids).count == ids.count else { throw WorkoutOperationError.invalidPayload }
            for id in ids { _ = try exercise(id, workout: workout, in: context) }
        case let .addSet(exerciseID, planned):
            _ = try exercise(exerciseID, workout: workout, in: context); try validSet(planned)
        case let .removeSets(exerciseID, ids):
            guard !ids.isEmpty, Set(ids).count == ids.count else { throw WorkoutOperationError.invalidPayload }
            let parent = try exercise(exerciseID, workout: workout, in: context)
            for id in ids { _ = try set(id, exercise: parent, in: context) }
        case let .exerciseComment(exerciseID, _): _ = try exercise(exerciseID, workout: workout, in: context)
        case let .rest(start, duration):
            guard (start == nil) == (duration == nil), start.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
                  duration.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw WorkoutOperationError.invalidPayload }
        case .workoutMetadata, .workoutTime, .requestFinish, .requestCancel: break
        }
    }
    private func insert(_ planned: WorkoutPlannedSet, exercise: WorkoutExercise, context: NSManagedObjectContext) {
        let value = WorkoutSet.create(context: context)
        value.uuid = planned.id; value.workoutExercise = exercise
        assign(planned.draft, to: value)
        value.minTargetRepetitionsValue = planned.minTargetRepetitions
        value.maxTargetRepetitionsValue = planned.maxTargetRepetitions
    }
    private func assign(_ draft: WorkoutSetDraft, to set: WorkoutSet) {
        set.weight = draft.weight as NSNumber?; set.repetitions = draft.repetitions as NSNumber?
        set.tag = draft.tag; set.rpe = draft.rpe; set.comment = draft.comment
    }
    private func mutate(_ operation: WorkoutOperation, workout: Workout, session: NSManagedObject, context: NSManagedObjectContext) throws -> Bool {
        switch operation.mutation {
        case let .saveSet(exerciseID, setID, draft, complete, duration):
            let parent = try exercise(exerciseID, workout: workout, in: context)
            let value = try set(setID, exercise: parent, in: context)
            let didComplete = complete && !value.isCompleted
            guard !didComplete || workout.isCurrentWorkout else { throw WorkoutOperationError.invalidPayload }
            assign(draft, to: value)
            if didComplete {
                value.isCompleted = true
                workout.start = workout.start ?? operation.date
                let exercises = workout.workoutExercises?.array as? [WorkoutExercise] ?? []
                let order = WorkoutEditingRules.orderAfterCompletion(exerciseID: exerciseID,
                    order: exercises.compactMap(\.uuid),
                    begun: Set(exercises.filter { ($0.numberOfCompletedSets ?? 0) > 0 }.compactMap(\.uuid)))
                workout.workoutExercises = NSOrderedSet(array: try order.map { try exercise($0, workout: workout, in: context) })
                session.setValue(operation.date, forKey: "restStart"); session.setValue(duration, forKey: "restDuration")
            }
            return didComplete
        case let .reorderExercises(ids):
            workout.workoutExercises = NSOrderedSet(array: try ids.map { try exercise($0, workout: workout, in: context) })
        case let .reorderSets(exerciseID, ids):
            let parent = try exercise(exerciseID, workout: workout, in: context)
            parent.workoutSets = NSOrderedSet(array: try ids.map { try set($0, exercise: parent, in: context) })
        case let .addExercise(id, catalogID, sets):
            let parent = WorkoutExercise.create(context: context)
            parent.uuid = id; parent.exerciseUuid = catalogID; parent.workout = workout
            for planned in sets { insert(planned, exercise: parent, context: context) }
        case let .removeExercises(ids):
            for id in ids { context.delete(try exercise(id, workout: workout, in: context)) }
        case let .addSet(exerciseID, planned):
            insert(planned, exercise: try exercise(exerciseID, workout: workout, in: context), context: context)
        case let .removeSets(exerciseID, ids):
            let parent = try exercise(exerciseID, workout: workout, in: context)
            for id in ids { context.delete(try set(id, exercise: parent, in: context)) }
        case let .exerciseComment(exerciseID, comment):
            try exercise(exerciseID, workout: workout, in: context).comment = comment
        case let .workoutMetadata(title, comment): workout.title = title; workout.comment = comment
        case let .workoutTime(start, end): workout.start = start; workout.end = end
        case let .rest(start, duration): session.setValue(start, forKey: "restStart"); session.setValue(duration, forKey: "restDuration")
        case .requestFinish: session.setValue(WorkoutSessionPhase.pendingFinish.rawValue, forKey: "phase")
        case .requestCancel: session.setValue(WorkoutSessionPhase.pendingCancel.rawValue, forKey: "phase")
        }
        return false
    }

    public func apply(operation: WorkoutOperation, mergingInto viewContext: NSManagedObjectContext? = nil) throws -> WorkoutOperationReceipt {
        try transaction(mergingInto: viewContext) { context in
            let decoder = JSONDecoder()
            let stored = try record("WorkoutAppliedOperation", key: "operationID", id: operation.id, in: context)
            if let stored = stored {
                guard let payload = stored.value(forKey: "payload") as? Data,
                      try decoder.decode(WorkoutOperation.self, from: payload) == operation,
                      let receiptData = stored.value(forKey: "receipt") as? Data else { throw WorkoutOperationError.operationIDCollision }
                let receipt = try decoder.decode(WorkoutOperationReceipt.self, from: receiptData)
                if receipt.disposition != .waitingForPredecessor { return receipt }
            }
            guard operation.expectedVersion >= 0, operation.sequence >= 0, !operation.originID.isEmpty,
                  operation.date.timeIntervalSinceReferenceDate.isFinite, operation.predecessorID != operation.id else { throw WorkoutOperationError.invalidPayload }
            let workout = try workout(operation.workoutID, in: context)
            try validateScalars(operation.mutation)
            let session = try session(operation.workoutID, in: context)
            let sessionID = session.value(forKey: "sessionID") as! UUID
            if let requested = operation.sessionID, requested != sessionID { throw WorkoutOperationError.invalidSession }
            let current = version(session), state = try phase(session)
            guard current < Int64.max else { throw WorkoutOperationError.invalidPayload }
            let remote = operation.originID != "phone"
            guard !remote || (operation.sessionID != nil && operation.sequence > 0) else { throw WorkoutOperationError.invalidPayload }
            var disposition: WorkoutOperationDisposition = .applied
            var reason: WorkoutConflictReason?
            let terminalRequest: Bool
            switch operation.mutation { case .requestFinish, .requestCancel: terminalRequest = true; default: terminalRequest = false }
            if state.isTerminal || !workout.isCurrentWorkout && remote ||
                (remote && state != .agreed) || (!remote && ![.local, .joining, .agreed].contains(state)) || (terminalRequest && state != .agreed) {
                disposition = .conflict; reason = .sessionUnavailable
            } else if let predecessorID = operation.predecessorID {
                if let predecessorRecord = try record("WorkoutAppliedOperation", key: "operationID", id: predecessorID, in: context),
                   let payload = predecessorRecord.value(forKey: "payload") as? Data,
                   let receiptData = predecessorRecord.value(forKey: "receipt") as? Data {
                    let predecessor = try decoder.decode(WorkoutOperation.self, from: payload)
                    let receipt = try decoder.decode(WorkoutOperationReceipt.self, from: receiptData)
                    guard predecessor.workoutID == operation.workoutID, predecessor.originID == operation.originID,
                          predecessor.sessionID == operation.sessionID, predecessor.sequence < Int64.max,
                          operation.sequence == predecessor.sequence + 1,
                          operation.expectedVersion == predecessor.expectedVersion || operation.expectedVersion == receipt.version else {
                        throw WorkoutOperationError.invalidPayload
                    }
                    if receipt.disposition == .waitingForPredecessor { disposition = .waitingForPredecessor }
                    else if receipt.disposition == .conflict { disposition = .conflict; reason = .predecessorConflict }
                    else if current != receipt.version { disposition = .conflict; reason = .staleVersion }
                } else { disposition = .waitingForPredecessor }
            } else if operation.expectedVersion != current { disposition = .conflict; reason = .staleVersion }
            var didComplete = false
            if disposition == .applied {
                // A predecessor may create these objects; a stale candidate may target
                // objects deleted since its base. Never lose either input before recording disposition.
                try validate(operation.mutation, workout: workout, context: context)
                didComplete = try mutate(operation, workout: workout, session: session, context: context)
                session.setValue(current + 1, forKey: "version")
            }
            let receipt = WorkoutOperationReceipt(operationID: operation.id, sessionID: sessionID, version: version(session),
                disposition: disposition, reason: reason, didComplete: didComplete,
                restStart: session.value(forKey: "restStart") as? Date, restDuration: session.value(forKey: "restDuration") as? Double)
            let row = stored ?? NSEntityDescription.insertNewObject(forEntityName: "WorkoutAppliedOperation", into: context)
            row.setValue(operation.id, forKey: "operationID")
            row.setValue(try JSONEncoder().encode(operation), forKey: "payload")
            row.setValue(try JSONEncoder().encode(receipt), forKey: "receipt")
            try save(context)
            return receipt
        }
    }

    /// Backup restore replaces history data, never an agreed channel to a prior device.
    /// The caller saves its existing restore context, keeping graph and metadata removal atomic.
    public static func discardSessionMetadata(workoutIDs: Set<UUID>, in context: NSManagedObjectContext) throws {
        guard !workoutIDs.isEmpty else { return }
        let sessions = NSFetchRequest<NSManagedObject>(entityName: "WorkoutSessionState")
        sessions.predicate = NSPredicate(format: "workoutID IN %@", Array(workoutIDs))
        for session in try context.fetch(sessions) { context.delete(session) }
        for row in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorkoutAppliedOperation")) {
            guard let data = row.value(forKey: "payload") as? Data else { throw WorkoutOperationError.invalidPayload }
            let operation = try JSONDecoder().decode(WorkoutOperation.self, from: data)
            if workoutIDs.contains(operation.workoutID) { context.delete(row) }
        }
    }

    public func operations(workoutID: UUID, disposition: WorkoutOperationDisposition? = nil) throws -> [WorkoutOperationConflict] {
        try transaction { context in
            try storedOperations(context).compactMap { _, operation, receipt in
                guard operation.workoutID == workoutID, disposition == nil || disposition == receipt.disposition else { return nil }
                return WorkoutOperationConflict(operation: operation, receipt: receipt)
            }.sorted { $0.operation.date == $1.operation.date ? $0.operation.id.uuidString < $1.operation.id.uuidString : $0.operation.date < $1.operation.date }
        }
    }

    public func beginJoining(workoutID: UUID, mergingInto viewContext: NSManagedObjectContext? = nil) throws -> WorkoutSessionSnapshot {
        try transaction(mergingInto: viewContext) { context in
            guard try workout(workoutID, in: context).isCurrentWorkout else { throw WorkoutOperationError.invalidSession }
            let value = try session(workoutID, in: context)
            let state = try phase(value)
            guard !state.isTerminal else { throw WorkoutOperationError.invalidSession }
            for other in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorkoutSessionState")) where other != value {
                if try phase(other).occupiesSharedSlot { throw WorkoutOperationError.occupiedSession }
            }
            if state == .local {
                guard version(value) < Int64.max else { throw WorkoutOperationError.invalidPayload }
                value.setValue(WorkoutSessionPhase.joining.rawValue, forKey: "phase")
                value.setValue(version(value) + 1, forKey: "version")
                try save(context)
            }
        }
        return try snapshot(workoutID: workoutID)
    }

    /// Records agreement only; graph pruning/cancellation/HealthKit are STEEL-13 consumers.
    public func recordSessionAgreement(workoutID: UUID, sessionID: UUID, phase target: WorkoutSessionPhase,
                                       mergingInto viewContext: NSManagedObjectContext? = nil) throws -> WorkoutSessionSnapshot {
        try transaction(mergingInto: viewContext) { context in
            let value = try session(workoutID, in: context)
            guard value.value(forKey: "sessionID") as? UUID == sessionID else { throw WorkoutOperationError.invalidSession }
            let state = try phase(value)
            if state == target { return }
            let allowed = (state == .joining && target == .agreed) || (state == .pendingFinish && target == .finished) || (state == .pendingCancel && target == .cancelled)
            guard allowed, version(value) < Int64.max else { throw WorkoutOperationError.invalidSession }
            if target.isTerminal {
                let unresolved = try storedOperations(context).contains { _, operation, receipt in
                    operation.workoutID == workoutID && receipt.sessionID == sessionID && receipt.disposition != .applied
                }
                guard !unresolved else { throw WorkoutOperationError.unresolvedOperations }
                value.setValue(nil, forKey: "restStart"); value.setValue(nil, forKey: "restDuration")
            }
            value.setValue(target.rawValue, forKey: "phase"); value.setValue(version(value) + 1, forKey: "version")
            try save(context)
        }
        return try snapshot(workoutID: workoutID)
    }

    public func snapshot(workoutID: UUID) throws -> WorkoutSessionSnapshot {
        try transaction { context in
            let workout = try workout(workoutID, in: context)
            let session = try record("WorkoutSessionState", key: "workoutID", id: workoutID, in: context)
            let sessionID = session?.value(forKey: "sessionID") as? UUID
            let coverage = try storedOperations(context).compactMap { _, operation, receipt -> UUID? in
                operation.workoutID == workoutID && receipt.sessionID == sessionID && receipt.disposition == .applied ? operation.id : nil
            }.sorted { $0.uuidString < $1.uuidString }
            return try WorkoutSessionSnapshot(workoutID: workoutID, sessionID: sessionID,
                version: session.map(version) ?? 0, phase: session.map { try phase($0) } ?? .local, coveredOperationIDs: coverage,
                title: workout.title, comment: workout.comment, start: workout.start, end: workout.end,
                isCurrentWorkout: workout.isCurrentWorkout, restStart: session?.value(forKey: "restStart") as? Date,
                restDuration: session?.value(forKey: "restDuration") as? Double,
                exercises: (workout.workoutExercises?.array as? [WorkoutExercise] ?? []).map { exercise in
                    guard let id = exercise.uuid else { throw WorkoutOperationError.missingObject }
                    return try WorkoutSessionSnapshot.Exercise(id: id, exerciseID: exercise.exerciseUuid, comment: exercise.comment,
                        sets: (exercise.workoutSets?.array as? [WorkoutSet] ?? []).map { set in
                            guard let id = set.uuid else { throw WorkoutOperationError.missingObject }
                            return WorkoutSessionSnapshot.Set(id: id, result: WorkoutSetDraft(set: set), isCompleted: set.isCompleted,
                                minTargetRepetitions: set.minTargetRepetitionsValue, maxTargetRepetitions: set.maxTargetRepetitionsValue)
                        })
                })
        }
    }
}
