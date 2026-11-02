//
//  MainContentView.swift
//  WatchIron Extension
//
//  Created by Karim Abou Zeid on 02.11.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import WatchKit
import HealthKit

struct ContentView: View {
    var body: some View {
        _ContentView()
            .environmentObject(WorkoutSessionManagerStore.shared)
            .safeAreaInset(edge: .top) { WorkoutSynchronizationStatusView() }
            .onAppear { PhoneConnectionManager.shared.synchronizeWorkout() }
    }
}

private struct _ContentView: View {
    @EnvironmentObject var owner: WorkoutSessionManagerStore
    @AppStorage("watchWorkoutNavigation.v1") private var savedNavigation = Data()
    @State private var navigation = WatchWorkoutNavigation()
    @State private var restored = false

    private var replicaState: WorkoutReplicaStore.State? { try? owner.workoutReplica.get().state }
    private var snapshot: WorkoutSessionSnapshot? { replicaState?.snapshot }
    private var hasJoinedWorkout: Bool {
        WatchWorkoutNavigation.canPresentWorkout(snapshot: snapshot, agreed: replicaState?.agreed ?? false)
    }
    private var path: Binding<[WatchWorkoutNavigation.Route]> {
        Binding(get: { navigation.path }, set: { navigation.setPath($0) })
    }

    var body: some View {
        Group {
            if hasJoinedWorkout, let snapshot = snapshot {
                TabView(selection: $navigation.page) {
                    OptionsView().tag(WatchWorkoutNavigation.Page.finish)
                    NavigationStack(path: path) {
                        exerciseList(snapshot)
                            .navigationDestination(for: WatchWorkoutNavigation.Route.self) { route in
                                destination(route, snapshot: snapshot)
                            }
                    }
                    .tag(WatchWorkoutNavigation.Page.workout)
                    measurements.tag(WatchWorkoutNavigation.Page.measurements)
                    NowPlayingView().tag(WatchWorkoutNavigation.Page.nowPlaying)
                }
                .tabViewStyle(.page)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "iphone").imageScale(.large)
                    Text(L10n.string(snapshot?.phase == .joining || owner.workoutSessionManager != nil
                         ? "Waiting for iPhone agreement" : "Start a workout on your iPhone."))
                        .multilineTextAlignment(.center)
                }
                .scenePadding()
            }
        }
        .onAppear {
            if !restored {
                navigation = (try? JSONDecoder().decode(WatchWorkoutNavigation.self, from: savedNavigation)) ?? .init()
                restored = true
            }
            if replicaState != nil { navigation.reconcile(snapshot: snapshot) }
        }
        .onChange(of: snapshot) { _, value in
            if replicaState != nil { navigation.reconcile(snapshot: value) }
        }
        .onChange(of: navigation) { _, value in
            if let data = try? JSONEncoder().encode(value) { savedNavigation = data }
        }
    }

    @ViewBuilder private var measurements: some View {
        if let manager = owner.workoutSessionManager {
            WorkoutSessionView(workoutSessionManager: manager)
        } else {
            Text(measurementError ?? L10n.string("Waiting for workout measurements"))
                .multilineTextAlignment(.center).scenePadding()
        }
    }

    private var measurementError: String? {
        guard HKHealthStore.isHealthDataAvailable() else {
            return L10n.string("HealthKit is not available on this device.")
        }
        if WorkoutSessionManager.healthStore.authorizationStatus(for: .workoutType()) == .sharingDenied {
            return L10n.string("Not authorized for Apple Health. You can authorize Steel in the settings app.")
        }
        return nil
    }

    private func title(_ exercise: WorkoutSessionSnapshot.Exercise, snapshot: WorkoutSessionSnapshot) -> String {
        snapshot.editorContext?.exercises.first { $0.id == exercise.id }?.title ?? L10n.string("Exercise")
    }

    private func exerciseList(_ snapshot: WorkoutSessionSnapshot) -> some View {
        List {
            if snapshot.exercises.isEmpty { Text("No exercises") }
            ForEach(snapshot.exercises, id: \.id) { exercise in
                Button {
                    navigation.selectExercise(exercise.id, snapshot: snapshot)
                } label: {
                    VStack(alignment: .leading) {
                        Text(title(exercise, snapshot: snapshot))
                        Text("\(exercise.sets.filter(\.isCompleted).count)/\(exercise.sets.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(Text("Workout"))
    }

    @ViewBuilder private func destination(_ route: WatchWorkoutNavigation.Route, snapshot: WorkoutSessionSnapshot) -> some View {
        switch route {
        case .currentSet(let id):
            if let exercise = snapshot.exercises.first(where: { $0.id == id }) {
                List {
                    if let setID = navigation.workingSets[id], let set = exercise.sets.first(where: { $0.id == setID }) {
                        setSummary(navigation.drafts[setID] ?? set.result, unit: snapshot.editorContext?.weightUnit)
                    } else { Text("No sets") }
                    NavigationLink("Exercise Sets", value: WatchWorkoutNavigation.Route.sets(id))
                }
                .navigationTitle(title(exercise, snapshot: snapshot))
            }
        case .sets(let id):
            if let exercise = snapshot.exercises.first(where: { $0.id == id }) {
                List {
                    ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                        Button {
                            navigation.showCorrection(exerciseID: id, setID: set.id, snapshot: snapshot)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(L10n.format("Set %lld", index + 1))
                                setSummary(set.result, unit: snapshot.editorContext?.weightUnit)
                            }
                        }.disabled(!set.isCompleted)
                    }
                }.navigationTitle(Text("Exercise Sets"))
            }
        case .correction:
            List {
                if let draft = navigation.correctionDraft { setSummary(draft, unit: snapshot.editorContext?.weightUnit) }
            }.navigationTitle(Text("Set Details"))
        }
    }

    private func setSummary(_ draft: WorkoutSetDraft, unit: String?) -> some View {
        VStack(alignment: .leading) {
            Text(draft.weight.map { WeightUnit.format(weight: $0, from: .metric, to: WeightUnit(rawValue: unit ?? "") ?? .metric) } ?? "–")
            Text(draft.repetitions.map(String.init) ?? "–") + Text(" ") + Text("reps")
        }
        .font(.body.monospacedDigit())
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
#endif


private struct WorkoutSynchronizationStatusView: View {
    @ObservedObject private var owner = WorkoutSessionManagerStore.shared
    @ObservedObject private var connection = PhoneConnectionManager.shared
    private var message: String? {
        do {
            let state = try owner.workoutReplica.get().state
            if let error = connection.workoutSyncError { return error }
            guard let snapshot = state.snapshot else { return nil }
            if !state.agreed { return L10n.string("Waiting for iPhone agreement") }
            let resolved = state.acceptedSnapshot?.resolvedOperationIDs ?? []
            if !(snapshot.unresolvedConflictIDs ?? []).isEmpty || state.receipts.contains(where: { $0.disposition == .conflict && !resolved.contains($0.operationID) }) {
                return L10n.string("Resolve conflicts on iPhone")
            }
            let covered = state.acceptedSnapshot?.coveredOperationIDs ?? []
            if !state.pendingOperations.isEmpty || state.operations.contains(where: { !covered.contains($0.id) && !resolved.contains($0.id) }) || snapshot.phase == .pendingFinish || snapshot.phase == .pendingCancel {
                return L10n.string("Changes pending synchronization")
            }
            return nil
        } catch { return L10n.string("Could not load workout synchronization") }
    }
    var body: some View {
        if let message = message {
            VStack {
                Text(message).font(.caption).multilineTextAlignment(.center)
                Button("Retry synchronization") { connection.synchronizeWorkout() }.font(.caption)
            }
        }
    }
}
