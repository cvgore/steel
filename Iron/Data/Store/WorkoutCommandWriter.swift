import CoreData
import WorkoutDataKit

/// Phone commands are committed in the operation store before the view context is merged.
struct WorkoutCommandWriter {
    enum Failure: Error { case missingIdentity, unavailableStore, notApplied }
    static let didCommit = Notification.Name("WorkoutCommandWriter.didCommit")
    struct Commit {
        let operation: WorkoutOperation
        let receipt: WorkoutOperationReceipt
    }
    let context: NSManagedObjectContext

    func snapshot(workout: Workout) throws -> WorkoutSessionSnapshot {
        guard let id = workout.uuid else { throw Failure.missingIdentity }
        guard let coordinator = context.persistentStoreCoordinator else { throw Failure.unavailableStore }
        return try WorkoutOperationStore(coordinator: coordinator).snapshot(workoutID: id)
    }

    @discardableResult
    func write(workout: Workout, mutation: WorkoutMutation, expectedVersion: Int64? = nil) throws -> WorkoutOperationReceipt {
        let snapshot = try self.snapshot(workout: workout)
        let operation = WorkoutOperation(workoutID: snapshot.workoutID, sessionID: snapshot.sessionID,
            expectedVersion: expectedVersion ?? snapshot.version, mutation: mutation)
        return try apply(operation)
    }

    @discardableResult
    func apply(_ operation: WorkoutOperation) throws -> WorkoutOperationReceipt {
        guard let coordinator = context.persistentStoreCoordinator else { throw Failure.unavailableStore }
        let receipt = try WorkoutOperationStore(coordinator: coordinator).apply(operation: operation, mergingInto: context)
        guard receipt.disposition == .applied else { throw Failure.notApplied }
        if operation.originID == "phone" {
            NotificationCenter.default.post(name: Self.didCommit, object: context,
                userInfo: ["commit": Commit(operation: operation, receipt: receipt)])
        }
        return receipt
    }
}

/// A selected set draft may follow only the next known local edit that leaves its result intact.
struct WorkoutDraftRevision {
    let version: Int64
    let sessionID: UUID?

    func following(_ commit: WorkoutCommandWriter.Commit, workoutID: UUID, exerciseID: UUID, setID: UUID) -> WorkoutDraftRevision? {
        let operation = commit.operation
        let receipt = commit.receipt
        guard operation.originID == "phone", operation.workoutID == workoutID,
              operation.expectedVersion == version, version < Int64.max,
              receipt.disposition == .applied, receipt.version == version + 1,
              sessionID == nil || sessionID == receipt.sessionID,
              operation.sessionID == nil || operation.sessionID == receipt.sessionID else { return nil }
        switch operation.mutation {
        case let .saveSet(_, target, _, _, _) where target == setID: return nil
        case let .removeSets(parent, ids) where parent == exerciseID && ids.contains(setID): return nil
        case let .removeExercises(ids) where ids.contains(exerciseID): return nil
        case .requestFinish, .requestCancel: return nil
        default: return WorkoutDraftRevision(version: receipt.version, sessionID: receipt.sessionID)
        }
    }
}
