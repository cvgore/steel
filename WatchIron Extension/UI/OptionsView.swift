import SwiftUI

struct OptionsView: View {
    @EnvironmentObject var workoutSessionManagerStore: WorkoutSessionManagerStore
    @State private var confirmCancel = false
    @State private var failed = false
    private var snapshot: WorkoutSessionSnapshot? { try? workoutSessionManagerStore.workoutReplica.get().snapshot }

    var body: some View {
        VStack(spacing: 12) {
            Button { request(.requestFinish) } label: {
                Label("Finish Workout", systemImage: "checkmark")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            Button(role: .destructive) { confirmCancel = true } label: {
                Label("Cancel Workout", systemImage: "xmark")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .disabled(snapshot?.phase != .agreed)
        .confirmationDialog("Cancel Workout?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel Workout", role: .destructive) { request(.requestCancel) }
            Button("Keep Workout", role: .cancel) {}
        }
        .alert("Could not save workout changes. Please retry.", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        }
    }
    private func request(_ mutation: WorkoutMutation) {
        do { try workoutSessionManagerStore.submitWorkoutMutation(mutation) }
        catch { failed = true }
    }
}
