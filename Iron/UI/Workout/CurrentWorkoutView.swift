//
//  CurrentWorkoutView.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 19.07.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import StoreKit
import AVKit
import HealthKit
import WorkoutDataKit
import os.log

struct CurrentWorkoutView: View {
    @Environment(\.managedObjectContext) var managedObjectContext
    @EnvironmentObject var restTimerStore: RestTimerStore
    @EnvironmentObject var exerciseStore: ExerciseStore
    @EnvironmentObject var settingsStore: SettingsStore
    
    @ObservedObject var workout: Workout
    
    @State private var showingCancelActionSheet = false
    @State private var operationError = false

    @discardableResult
    private func commit(_ mutation: WorkoutMutation, expectedVersion: Int64? = nil) -> Bool {
        do {
            try WorkoutCommandWriter(context: managedObjectContext).write(workout: workout, mutation: mutation, expectedVersion: expectedVersion)
            return true
        } catch { operationError = true; return false }
    }

    private func captureMetadataBase() -> WorkoutSessionSnapshot? {
        do { return try WorkoutCommandWriter(context: managedObjectContext).snapshot(workout: workout) }
        catch { operationError = true; return nil }
    }
    @State private var activeSheet: SheetType?
    
    private enum SheetType: Identifiable {
        case exerciseSelector
        case synchronization
        case finish
        
        var id: Self { self }
    }
    
    private func sheetView(type: SheetType) -> AnyView {
        switch type {
        case .exerciseSelector:
            return AddExercisesSheet(
                exercises: exerciseStore.shownExercises,
                recentExercises: AddExercisesSheet.loadRecentExercises(context: managedObjectContext, exercises: exerciseStore.shownExercises),
                onAdd: { selection in
                    for exercise in selection {
                        commit(.addExercise(id: UUID(), exerciseID: exercise.uuid,
                            sets: createDefaultWorkoutSets(exerciseID: exercise.uuid)))
                    }
                }
            ).typeErased
        case .synchronization:
            return WorkoutSynchronizationView().typeErased
        case .finish:
            return self.finishWorkoutSheet.typeErased
        }
    }
    
    private func createDefaultWorkoutSets(exerciseID: UUID) -> [WorkoutPlannedSet] {
        var numberOfSets = 3
        // try to guess the number of sets
        if let history = try? managedObjectContext.fetch(WorkoutExercise.historyFetchRequest(of: exerciseID, until: workout.start)), history.count >= 3 {
            // one month since last workout and at least three workouts
            if let firstHistoryStart = history[0].workout?.start, let thirdHistoryStart = history[2].workout?.start {
                let cutoff = min(thirdHistoryStart, Calendar.current.date(byAdding: .month, value: -1, to: firstHistoryStart)!)
                let filteredAndSortedHistory = history
                    .filter {
                        guard let start = $0.workout?.start else { return false }
                        return start >= cutoff
                }
                .sorted {
                    ($0.workoutSets?.count ?? 0) < ($1.workoutSets?.count ?? 0)
                }
                
                assert(filteredAndSortedHistory.count >= 3)
                let median = filteredAndSortedHistory[filteredAndSortedHistory.count / 2]
                numberOfSets = median.workoutSets?.count ?? numberOfSets
            }
        }
        return (0..<numberOfSets).map { _ in WorkoutPlannedSet() }
    }

    private var workoutExercises: [WorkoutExercise] {
        workout.workoutExercises?.array as? [WorkoutExercise] ?? []
    }
    
    @State private var workoutCommentInput: String? = nil
    @State private var commentBase: WorkoutSessionSnapshot?
    private var workoutComment: Binding<String> {
        Binding(
            get: {
                self.workoutCommentInput ?? self.workout.comment ?? ""
        },
            set: { newValue in
                if self.commentBase == nil { self.commentBase = self.captureMetadataBase() }
                self.workoutCommentInput = newValue
        }
        )
    }
    private func adjustAndSaveWorkoutCommentInput() {
        guard let newValue = workoutCommentInput?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        workoutCommentInput = newValue
        guard let base = commentBase else { operationError = true; return }
        if commit(.workoutMetadata(title: base.title, comment: newValue.isEmpty ? nil : newValue), expectedVersion: base.version) {
            commentBase = nil
            workoutCommentInput = nil
        }

    }
    
    @State private var workoutTitleInput: String? = nil
    @State private var titleBase: WorkoutSessionSnapshot?
    private var workoutTitle: Binding<String> {
        Binding(
            get: {
                self.workoutTitleInput ?? self.workout.title ?? ""
            },
            set: { newValue in
                if self.titleBase == nil { self.titleBase = self.captureMetadataBase() }
                self.workoutTitleInput = newValue
            }
        )
    }
    private func adjustAndSaveWorkoutTitleInput() {
        guard let newValue = workoutTitleInput?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        workoutTitleInput = newValue
        guard let base = titleBase else { operationError = true; return }
        if commit(.workoutMetadata(title: newValue.isEmpty ? nil : newValue, comment: base.comment), expectedVersion: base.version) {
            titleBase = nil
            workoutTitleInput = nil
        }
    }
    
    private func currentWorkoutExerciseDetailView(workoutExercise: WorkoutExercise) -> some View {
        VStack(spacing: 0) {
            // on the iPad we have two columns at once so we already have a TimerBannerView
            if UIDevice.current.userInterfaceIdiom != .pad {
                if #available(iOS 15.0, *) {
                    Divider()
                }
                TimerBannerView(workout: workout)
                Divider()
            }
            WorkoutExerciseDetailView(workoutExercise: workoutExercise)
                .layoutPriority(1)
                .environmentObject(settingsStore)
        }
    }

    private func workoutExerciseCell(workoutExercise: WorkoutExercise) -> some View {
        let text: String?
        if let totalSets = workoutExercise.workoutSets?.count, totalSets > 0, let completedSets = workoutExercise.numberOfCompletedSets{
            text = "\(completedSets) / \(totalSets)"
        } else {
            text = nil
        }
        let isCompleted = workoutExercise.isCompleted ?? false
        
        return HStack {
            NavigationLink(destination:
                    currentWorkoutExerciseDetailView(workoutExercise: workoutExercise)
                ) {
                VStack(alignment: .leading) {
                    Text(workoutExercise.exercise(in: exerciseStore.exercises)?.title ?? L10n.string("Unknown Exercise"))
                        .foregroundColor(isCompleted ? .secondary : .primary)
                    text.map {
                        Text($0)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .layoutPriority(1) // without this the text is suddenly displayed multiline (because of the spacer below)
                if isCompleted {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                    .accessibility(label: Text("Completed"))
                        .foregroundColor(.green)
                }
            }
        }
    }
    
    private var closeSheetButton: some View {
        Button("Close") {
            self.activeSheet = nil
        }
    }
    
    private func finishWorkout() {
        do { try workout.finish() }
        catch { operationError = true; return }
        activeSheet = nil
        if workout.isCurrentWorkout { activeSheet = .synchronization; return }
        
        // haptic feedback
        let feedbackGenerator = UINotificationFeedbackGenerator()
        feedbackGenerator.prepare()
        feedbackGenerator.notificationOccurred(.success)
        AudioServicesPlaySystemSound(1103) // Tink sound
        
        UserDefaults.standard.finishedWorkoutsCount += 1
        if UserDefaults.standard.finishedWorkoutsCount == 6 {
            // ask for review after the user finishes his third workout
            SKStoreReviewController.requestReview()
        }
    }
    
    @State private var finishWorkoutSheetActivityItems: [Any]?
    private var finishWorkoutSheet: some View {
        NavigationView {
            WorkoutLog(workout: self.workout)
                .navigationBarTitle("Summary", displayMode: .inline)
                .navigationBarItems(
                    leading: closeSheetButton,
                    trailing:
                    HStack(spacing: NAVIGATION_BAR_SPACING) {
                        Button(action: {
                            guard let logText = self.workout.logText(in: self.exerciseStore.exercises, weightUnit: self.settingsStore.weightUnit) else { return }
                            self.finishWorkoutSheetActivityItems = [logText]
                        }) {
                            Image(systemName: "square.and.arrow.up")
                    .accessibility(label: Text("Share"))
                        }
                        
                        Button("Finish") {
                            self.finishWorkout()
                        }
                    }
                )
                .overlay(ActivitySheet(activityItems: $finishWorkoutSheetActivityItems))
                .environmentObject(settingsStore)
                .environmentObject(exerciseStore)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    private func cancelWorkout() {
        do { try workout.cancel() }
        catch { operationError = true; return }
        if !workout.isDeleted && workout.isCurrentWorkout { activeSheet = .synchronization; return }
        
        let feedbackGenerator = UINotificationFeedbackGenerator()
        feedbackGenerator.prepare()
        feedbackGenerator.notificationOccurred(.success)
    }
    
    private var cancelButton: some View {
        Button("Cancel") {
            if (self.workout.workoutExercises?.count ?? 0) == 0 {
                // the workout is empty, do not need confirm to cancel
                self.cancelWorkout()
            } else {
                guard UIDevice.current.userInterfaceIdiom != .pad else { // TODO: actionSheet not supported on iPad yet (13.2)
                    self.cancelWorkout()
                    return
                }
                self.showingCancelActionSheet = true
            }
        }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if #available(iOS 15.0, *) {
                    Divider()
                }
                TimerBannerView(workout: workout)
                Divider()
                List {
                    Section {
                        // TODO: add clear button
                        TextField("Title", text: workoutTitle, onEditingChanged: { isEditingTextField in
                            if !isEditingTextField {
                                self.adjustAndSaveWorkoutTitleInput()
                            }
                        })
                        TextField("Comment", text: workoutComment, onEditingChanged: { isEditingTextField in
                            if !isEditingTextField {
                                self.adjustAndSaveWorkoutCommentInput()
                            }
                        })
                    }
                    Section {
                        Button(action: { activeSheet = .synchronization }) {
                            Label("Watch synchronization", systemImage: "applewatch")
                        }
                    }
                    Section(header: Text(L10n.string("Exercises").uppercased(with: L10n.locale))) {
                        ForEach(workoutExercises) { workoutExercise in
                            self.workoutExerciseCell(workoutExercise: workoutExercise)
                        }
                        .onDelete { offsets in
                            let workoutExercises = self.workoutExercises
                            commit(.removeExercises(offsets.compactMap { workoutExercises[$0].uuid }))
                        }
                        .onMove { source, destination in
                            do {
                                let base = try WorkoutCommandWriter(context: managedObjectContext).snapshot(workout: workout)
                                var ids = base.exercises.map(\.id)
                                guard ids == workoutExercises.compactMap(\.uuid) else { operationError = true; return }
                                ids.move(fromOffsets: source, toOffset: destination)
                                commit(.reorderExercises(ids), expectedVersion: base.version)
                            } catch { operationError = true }
                        }
                        
                        Button(action: {
                            self.activeSheet = .exerciseSelector
                        }) {
                            HStack {
                                Image(systemName: "plus")
                                Text("Add Exercises")
                            }
                        }
                    }
                    Section {
                        Button(action: {
                            self.activeSheet = .finish
                        }) {
                            HStack {
                                Image(systemName: "checkmark")
                                Text("Finish Workout")
                            }
                        }
                    }
                }
                .listStyleCompat_InsetGroupedListStyle()
            }
            .navigationBarTitle(Text(workout.displayTitle(in: exerciseStore.exercises)), displayMode: .inline)
            .navigationBarItems(leading: cancelButton, trailing: EditButton())
            
            Text("No exercise selected")
                .foregroundColor(.secondary)
        }
        .padding(.leading, UIDevice.current.userInterfaceIdiom == .pad ? 1 : 0) // hack that makes the master view show on iPad on portrait mode
        .sheet(item: $activeSheet) { type in
            self.sheetView(type: type)
        }
        .alert(isPresented: $operationError) {
            Alert(title: Text("Could not save changes"), message: Text("Please try again."), dismissButton: .default(Text("Ok")))
        }
        .actionSheet(isPresented: $showingCancelActionSheet, content: {
            ActionSheet(title: Text("This cannot be undone."), message: nil, buttons: [
                .destructive(Text("Discard Workout"), action: {
                    self.cancelWorkout()
                }),
                .cancel()
            ])
        })
    }
}

#if DEBUG
struct WorkoutView_Previews: PreviewProvider {
    static var previews: some View {
        if RestTimerStore.shared.restTimerRemainingTime == nil {
            RestTimerStore.shared.presentCommittedRest(start: Date(), duration: 10)
        }
        return CurrentWorkoutView(workout: MockWorkoutData.metricRandom.currentWorkout)
            .mockEnvironment(weightUnit: .metric)
    }
}
#endif


private struct WorkoutSynchronizationView: View {
    @ObservedObject private var connection = WatchConnectionManager.shared
    @EnvironmentObject private var settings: SettingsStore
    @State private var snapshot: WorkoutSessionSnapshot?
    @State private var conflicts: [WorkoutOperationConflict] = []
    @State private var failed = false

    private func reload() {
        connection.publishSharedWorkout()
        snapshot = connection.workoutSyncSnapshot
        conflicts = connection.workoutSyncConflicts
    }
    private func resolve(_ conflict: WorkoutOperationConflict, useCandidate: Bool) {
        guard let snapshot = snapshot else { return }
        do {
            try connection.resolveWorkoutConflict(conflict.operation.id, expectedVersion: snapshot.version, useCandidate: useCandidate)
            reload()
        } catch { failed = true }
    }
    private func result(_ draft: WorkoutSetDraft) -> String {
        let weight = draft.weight.map { WeightUnit.format(weight: $0, from: .metric, to: settings.weightUnit) } ?? "–"
        var text = "\(weight) × \(draft.repetitions.map(String.init) ?? "–")"
        if draft.rpe > 0 { text += " · " + L10n.string("RPE") + " " + String(format: "%.1f", locale: L10n.locale, draft.rpe) }
        if let raw = draft.tag, let tag = WorkoutSetTag(rawValue: raw) { text += " · " + tag.title }
        return text
    }
    private func candidateLabel(_ mutation: WorkoutMutation) -> String {
        switch mutation {
        case let .saveSet(_, _, draft, _, _): return result(draft) + (draft.comment.map { " · " + $0 } ?? "")
        case .requestFinish: return L10n.string("Finish Workout")
        case .requestCancel: return L10n.string("Discard Workout")
        default: return L10n.string("Could not save changes")
        }
    }
    var body: some View {
        NavigationView {
            List {
                Section {
                    Text(L10n.string(snapshot == nil ? "Start a workout on your iPhone." : snapshot?.phase == .joining ? "Waiting for Watch agreement" : "Shared workout with Watch"))
                    if snapshot?.phase == .pendingFinish { Text("Finish requested; waiting for agreement") }
                    if snapshot?.phase == .pendingCancel { Text("Cancel requested; waiting for agreement") }
                    if let error = connection.workoutSyncError { Text(error).foregroundColor(.red) }
                    Button("Retry synchronization", action: reload)
                }
                ForEach(conflicts, id: \.operation.id) { conflict in
                    Section(header: Text("Conflicting changes")) {
                        if let setID = conflict.operation.setID,
                           let current = snapshot?.exercises.flatMap(\.sets).first(where: { $0.id == setID }) {
                            Text(L10n.string("Saved changes") + ": " + result(current.result) + (current.result.comment.map { " · " + $0 } ?? ""))
                        }
                        Text(L10n.string("Proposed changes") + " (" + L10n.string(conflict.operation.originID == "phone" ? "iPhone" : "Watch") + "): " + candidateLabel(conflict.operation.mutation))
                        Button("Keep saved changes") { resolve(conflict, useCandidate: false) }
                        switch conflict.operation.mutation {
                        case .saveSet, .requestFinish, .requestCancel:
                            Button("Use proposed changes") { resolve(conflict, useCandidate: true) }
                        default: EmptyView()
                        }
                    }
                }
            }
            .navigationTitle("Watch synchronization")
            .onAppear(perform: reload)
            .onReceive(connection.$workoutSyncSnapshot) { snapshot = $0 }
            .onReceive(connection.$workoutSyncConflicts) { conflicts = $0 }
            .alert(isPresented: $failed) {
                Alert(title: Text("Could not save changes"), message: Text("Reload changes before resolving the conflict."),
                      dismissButton: .default(Text("Ok")))
            }
        }
    }
}
