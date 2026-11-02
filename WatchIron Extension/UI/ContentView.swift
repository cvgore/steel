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
        VStack(spacing: 0) {
            _ContentView()
            WorkoutSynchronizationStatusView()
        }
            .environmentObject(WorkoutSessionManagerStore.shared)
            .onAppear { PhoneConnectionManager.shared.synchronizeWorkout() }
    }
}

private struct _ContentView: View {
    @EnvironmentObject var owner: WorkoutSessionManagerStore
    @AppStorage("watchWorkoutNavigation.v1") private var savedNavigation = Data()
    @State private var navigation = WatchWorkoutNavigation()
    @State private var restored = false
    @State private var pendingRecovery = true
    @State private var selectedField: EditorField = .weight
    @State private var saveLocked = false
    @State private var saveError = false
    @State private var correctionConflict = false
    @State private var weightPrecision = 0
    @FocusState private var crownFocused: Bool

    private enum EditorField { case weight, repetitions }

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
                navigation = replicaState?.localNavigation ?? (try? JSONDecoder().decode(WatchWorkoutNavigation.self, from: savedNavigation)) ?? .init()
                restored = true
            }
            if let state = replicaState {
                navigation.reconcile(snapshot: state.snapshot)
                if let snapshot = state.snapshot { navigation.resumePendingCompletion(state.pendingCompletion, snapshot: snapshot, operations: state.operations) }
                pendingRecovery = false
            }
        }
        .onChange(of: snapshot) { _, value in
            if let state = replicaState {
                navigation.reconcile(snapshot: value)
                if pendingRecovery, let value = value {
                    navigation.resumePendingCompletion(state.pendingCompletion, snapshot: value, operations: state.operations)
                    pendingRecovery = false
                }
            }
        }
        .onChange(of: navigation) { _, value in
            if let data = try? JSONEncoder().encode(value) { savedNavigation = data }
            if restored, let replica = try? owner.workoutReplica.get() {
                do { try replica.saveNavigation(value) } catch { saveError = true }
            }
        }
    }

    @ViewBuilder private var measurements: some View {
        if let manager = owner.workoutSessionManager {
            WorkoutSessionView(workoutSessionManager: manager)
        } else {
            VStack {
                replicaRest(snapshot)
                Text(measurementError ?? L10n.string("Waiting for workout measurements"))
                    .multilineTextAlignment(.center)
            }.scenePadding()
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
            if saveError { Text("Could not save set. Please retry.").font(.caption).foregroundStyle(.red) }
            ForEach(snapshot.exercises, id: \.id) { exercise in
                Button {
                    do {
                        var selected = navigation
                        selected.selectExercise(exercise.id, snapshot: snapshot)
                        try owner.workoutReplica.get().saveNavigation(selected, clearingCompletion: true)
                        navigation = selected
                    } catch { saveError = true }
                } label: {
                    VStack(alignment: .leading) {
                        Text(title(exercise, snapshot: snapshot))
                        HStack {
                            Text("\(exercise.sets.filter(\.isCompleted).count)/\(exercise.sets.count)")
                            if WorkoutEditingRules.isComplete(exercise) {
                                Label("Completed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }.font(.caption)
                    }
                }
            }
        }
        .navigationTitle(Text("Workout"))
    }

    @ViewBuilder private func destination(_ route: WatchWorkoutNavigation.Route, snapshot: WorkoutSessionSnapshot) -> some View {
        switch route {
        case .currentSet(let routeID):
            let id = navigation.currentExerciseID ?? routeID
            if let exercise = snapshot.exercises.first(where: { $0.id == id }) {
                List {
                    if let setID = navigation.workingSets[id], let set = exercise.sets.first(where: { $0.id == setID }) {
                        if set.isCompleted {
                            setResult(set, exerciseID: exercise.id, unit: snapshot.editorContext?.weightUnit)
                            if let draft = navigation.drafts[set.id], draft != set.result,
                               replicaState?.pendingCompletion?.setID != set.id {
                                Button("Review saved draft") {
                                    showCompletionConflict(exerciseID: exercise.id, setID: set.id, snapshot: snapshot)
                                }
                            }
                        } else {
                            editor(exercise: exercise, set: set, snapshot: snapshot, correction: false)
                        }
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
                            correctionConflict = false
                            navigation.showCorrection(exerciseID: id, setID: set.id, snapshot: snapshot)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(L10n.format("Set %lld", index + 1))
                                if set.isCompleted {
                                    setResult(set, exerciseID: exercise.id, unit: snapshot.editorContext?.weightUnit)
                                } else {
                                    Text("Not completed").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.disabled(!set.isCompleted)
                    }
                }.navigationTitle(Text("Exercise Sets"))
            }
        case let .correction(exerciseID, setID):
            if let exercise = snapshot.exercises.first(where: { $0.id == exerciseID }),
               let set = exercise.sets.first(where: { $0.id == setID }) {
                List {
                    editor(exercise: exercise, set: set, snapshot: snapshot, correction: true)
                }.navigationTitle(Text("Set Details"))
            }
        }
    }

    private func editor(exercise: WorkoutSessionSnapshot.Exercise, set: WorkoutSessionSnapshot.Set,
                        snapshot: WorkoutSessionSnapshot, correction: Bool) -> some View {
        let unit = WeightUnit(rawValue: snapshot.editorContext?.weightUnit ?? "") ?? .metric
        let draft = correction ? (navigation.correctionDraft ?? set.result) : (navigation.drafts[set.id] ?? set.result)
        let crown = Binding<Double>(get: {
            let value = correction ? (navigation.correctionDraft ?? set.result) : (navigation.drafts[set.id] ?? set.result)
            return selectedField == .weight
                ? WeightUnit.convert(weight: value.weight ?? 0, from: .metric, to: unit)
                : Double(value.repetitions ?? 0)
        }, set: { value in
            var edited = correction ? (navigation.correctionDraft ?? set.result) : (navigation.drafts[set.id] ?? set.result)
            if selectedField == .weight {
                edited.weight = min(WorkoutEditingRules.maximumWeight, max(0, WeightUnit.convert(weight: value, from: unit, to: .metric)))
            } else {
                edited.repetitions = Int16(max(0, min(value.rounded(), Double(WorkoutEditingRules.maximumRepetitions))))
            }
            if correction { navigation.correctionDraft = edited } else { navigation.drafts[set.id] = edited }
        })
        return VStack(spacing: 8) {
            replicaRest(snapshot)
            HStack {
                Button { selectedField = .weight; crownFocused = true } label: {
                    Text(draft.weight.map { WeightUnit.format(weight: $0, from: .metric, to: unit) } ?? "–")
                        .frame(maxWidth: .infinity).padding(4)
                        .background(selectedField == .weight ? Color.accentColor : Color.secondary.opacity(0.2))
                }.accessibilityLabel(Text("Weight"))
                Button { selectedField = .repetitions; crownFocused = true } label: {
                    Text(draft.repetitions.map(String.init) ?? "–")
                        .frame(maxWidth: .infinity).padding(4)
                        .background(selectedField == .repetitions ? Color.accentColor : Color.secondary.opacity(0.2))
                }.accessibilityLabel(Text("Repetitions"))
            }.font(.title3.monospacedDigit()).buttonStyle(.plain)
            .focusable(correction || !set.isCompleted)
            .focused($crownFocused)
            .digitalCrownRotation(crown, from: 0,
                through: selectedField == .weight ? WeightUnit.convert(weight: WorkoutEditingRules.maximumWeight, from: .metric, to: unit) : Double(WorkoutEditingRules.maximumRepetitions),
                by: selectedField == .repetitions ? 1 : (weightPrecision == 1 ? 0.1 : (weightPrecision == 2 ? 0.001 : (snapshot.editorContext?.exercises.first(where: { $0.id == exercise.id })?.barbellWeight != nil ? unit.barbellIncrement : 1))),
                sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
            .onAppear { crownFocused = correction || !set.isCompleted }
            if selectedField == .weight && (correction || !set.isCompleted) {
                Button {
                    weightPrecision = (weightPrecision + 1) % 3
                    crownFocused = true
                } label: {
                    Text(LocalizedStringKey(weightPrecision == 0 ? "Weight step: standard" : (weightPrecision == 1 ? "Weight step: 0.1" : "Weight step: 0.001")))
                        .font(.caption)
                }
            }
            Button(correction ? "Save Correction" : "Save Set") {
                if correction { saveCorrection(exerciseID: exercise.id, setID: set.id) }
                else { saveSet(exerciseID: exercise.id, setID: set.id) }
            }
                .disabled((!correction && set.isCompleted) || saveLocked || snapshot.phase != .agreed || snapshot.editorContext?.exercises.first(where: { $0.id == exercise.id }) == nil)
            if correction && (correctionConflict || navigation.correctionOriginal == nil) {
                Text("This set changed on iPhone. Your draft is kept here.").font(.caption).foregroundStyle(.red)
                if let current = snapshot.exercises.first(where: { $0.id == exercise.id })?.sets.first(where: { $0.id == set.id }) {
                    Text("Current result").font(.caption)
                    setSummary(current.result, unit: snapshot.editorContext?.weightUnit)
                    Button("Use my correction") {
                        navigation.correctionOriginal = current.result
                        saveCorrection(exerciseID: exercise.id, setID: set.id)
                    }
                }
            } else if saveError { Text("Could not save set. Please retry.").font(.caption).foregroundStyle(.red) }
        }
    }

    @ViewBuilder private func replicaRest(_ snapshot: WorkoutSessionSnapshot?) -> some View {
        if let start = snapshot?.restStart, let duration = snapshot?.restDuration {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                HStack {
                    Image(systemName: "timer")
                    RestTimerView(date: context.date, end: start.addingTimeInterval(duration),
                                  keepRunning: snapshot?.editorContext?.keepRestTimerRunning ?? false)
                }.font(.caption.monospacedDigit())
            }
        }
    }

    private func saveSet(exerciseID: UUID, setID: UUID) {
        guard !saveLocked else { return }
        do {
            let replica = try owner.workoutReplica.get()
            guard let current = replica.snapshot, current.phase == .agreed,
                  let exercise = current.exercises.first(where: { $0.id == exerciseID }),
                  let set = exercise.sets.first(where: { $0.id == setID }),
                  let context = current.editorContext?.exercises.first(where: { $0.id == exerciseID }) else { return }
            if set.isCompleted {
                showCompletionConflict(exerciseID: exerciseID, setID: setID, snapshot: current)
                return
            }
            let draft = navigation.drafts[setID] ?? set.result
            guard WorkoutEditingRules.isValid(draft) else { saveError = true; return }
            saveLocked = true
            _ = try owner.submitWorkoutMutation(.saveSet(exerciseID: exerciseID, setID: setID, draft: draft,
                                                         complete: true, restDuration: context.restDuration), trackCompletion: true, navigation: navigation)
            saveError = false
            // Keep the saved result visible briefly; any phone-confirmed record belongs to it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let updated = replica.snapshot {
                    navigation.resumePendingCompletion(replica.state.pendingCompletion, snapshot: updated, operations: replica.state.operations)
                }
                saveLocked = false
            }
        } catch WorkoutReplicaStore.Failure.changedSet {
            saveLocked = false
            if let current = try? owner.workoutReplica.get().snapshot {
                showCompletionConflict(exerciseID: exerciseID, setID: setID, snapshot: current)
            } else { saveError = true }
        } catch {
            saveLocked = false
            saveError = true
        }
    }

    private func showCompletionConflict(exerciseID: UUID, setID: UUID, snapshot: WorkoutSessionSnapshot) {
        guard let draft = navigation.drafts[setID] else { saveError = true; return }
        navigation.showCorrection(exerciseID: exerciseID, setID: setID, snapshot: snapshot)
        guard navigation.correctionDraft != nil else { saveError = true; return }
        navigation.correctionDraft = draft
        navigation.correctionOriginal = nil
        correctionConflict = true
    }

    private func saveCorrection(exerciseID: UUID, setID: UUID) {
        guard !saveLocked, let draft = navigation.correctionDraft, let original = navigation.correctionOriginal, WorkoutEditingRules.isValid(draft) else {
            saveError = true; return
        }
        do {
            let replica = try owner.workoutReplica.get()
            guard let current = replica.snapshot, current.phase == .agreed,
                  let exercise = current.exercises.first(where: { $0.id == exerciseID }),
                  exercise.sets.contains(where: { $0.id == setID && $0.isCompleted }) else {
                saveError = true; return
            }
            saveLocked = true
            _ = try owner.submitWorkoutMutation(.saveSet(exerciseID: exerciseID, setID: setID,
                                                         draft: draft, complete: true, restDuration: 0), expectedSetResult: original)
            correctionConflict = false
            saveError = false
            navigation.setPath([.currentSet(exerciseID), .sets(exerciseID)])
            saveLocked = false
        } catch WorkoutReplicaStore.Failure.changedSet {
            saveLocked = false
            correctionConflict = true
        } catch {
            saveLocked = false
            saveError = true
        }
    }

    private func setResult(_ set: WorkoutSessionSnapshot.Set, exerciseID: UUID, unit: String?) -> some View {
        VStack(alignment: .leading) {
            setSummary(set.result, unit: unit)
            if set.isPersonalRecord == true {
                Label("Personal Record", systemImage: "star.circle.fill").foregroundStyle(.yellow)
            } else if set.isPersonalRecord == nil && recordConfirmationPending(exerciseID: exerciseID) {
                Text("Record pending confirmation").font(.caption).foregroundStyle(.secondary)
            }
            Label("Completed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        }
    }

    private func recordConfirmationPending(exerciseID: UUID) -> Bool {
        guard let state = replicaState else { return false }
        let covered = state.acceptedSnapshot?.coveredOperationIDs ?? []
        let resolved = state.acceptedSnapshot?.resolvedOperationIDs ?? []
        return state.operations.contains { operation in
            guard !covered.contains(operation.id), !resolved.contains(operation.id) else { return false }
            if case let .saveSet(id, _, _, _, _) = operation.mutation { return id == exerciseID }
            return false
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
    @State private var showingDetails = false
    private var syncStatuses: [(summary: String, message: String)] {
        var statuses: [(summary: String, message: String)] = []
        if let error = connection.workoutSyncError {
            statuses.append((L10n.string("Sync error"), error))
        }
        do {
            let state = try owner.workoutReplica.get().state
            guard let snapshot = state.snapshot else { return statuses }
            if !state.agreed {
                statuses.append((L10n.string("Waiting for iPhone"), L10n.string("Waiting for iPhone agreement")))
            }
            let resolved = state.acceptedSnapshot?.resolvedOperationIDs ?? []
            let localConflict = state.conflicts.contains { conflict in
                conflict.accepted.version >= (state.acceptedSnapshot?.version ?? conflict.accepted.version)
            }
            if localConflict || !(snapshot.unresolvedConflictIDs ?? []).isEmpty || state.receipts.contains(where: { $0.disposition == .conflict && !resolved.contains($0.operationID) }) {
                statuses.insert((L10n.string("Conflict"), L10n.string("Resolve conflicts on iPhone")), at: 0)
            }
            let covered = state.acceptedSnapshot?.coveredOperationIDs ?? []
            if !state.pendingOperations.isEmpty || state.operations.contains(where: { !covered.contains($0.id) && !resolved.contains($0.id) }) || snapshot.phase == .pendingFinish || snapshot.phase == .pendingCancel {
                statuses.append((L10n.string("Sync pending"), L10n.string("Changes pending synchronization")))
            }
        } catch { statuses.append((L10n.string("Sync error"), L10n.string("Could not load workout synchronization"))) }
        return statuses
    }
    private var healthMessage: String? {
        if let error = owner.healthEffectError { return error }
        guard let recovery = owner.healthRecovery else { return nil }
        switch recovery.effect {
        case .blocked: return L10n.string("Workout saved. Measurements need Health permission or session recovery.")
        case .saving, .uncertain: return L10n.string("Workout saved. Health save is unconfirmed; it will not be repeated.")
        default: return nil
        }
    }
    var body: some View {
        if !syncStatuses.isEmpty || healthMessage != nil {
            Button { showingDetails = true } label: {
                HStack {
                    Image(systemName: "exclamationmark.circle")
                    Text([syncStatuses.first?.summary, healthMessage == nil ? nil : L10n.string("Health warning")].compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .font(.caption2)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(.gray.opacity(0.35), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel((syncStatuses.map(\.message) + [healthMessage].compactMap { $0 }).joined(separator: ". "))
            .sheet(isPresented: $showingDetails) {
                ScrollView {
                    VStack(spacing: 8) {
                        if !syncStatuses.isEmpty {
                            ForEach(Array(syncStatuses.enumerated()), id: \.offset) { _, status in
                                Text(status.message).font(.caption).multilineTextAlignment(.center)
                            }
                            Button("Retry synchronization") { connection.synchronizeWorkout() }.font(.caption)
                        }
                        if let healthMessage = healthMessage {
                            Text(healthMessage).font(.caption2).multilineTextAlignment(.center)
                            Button("Check measurements") {
                                owner.recoverSharedHealthEffect()
                                connection.synchronizeWorkout()
                            }.font(.caption)
                        }
                    }
                }
            }
        }
    }
}
