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
