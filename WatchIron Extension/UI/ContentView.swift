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
    @EnvironmentObject var workoutSessionManagerStore: WorkoutSessionManagerStore
    
    @State private var selectedTab = "workout"
    
    @ViewBuilder
    var body: some View {
        if workoutSessionManagerStore.workoutSessionManager != nil {
            TabView(selection: $selectedTab) {
                OptionsView()
                    .tag("options")
                
                WorkoutSessionView(workoutSessionManager: workoutSessionManagerStore.workoutSessionManager!)
                    .tag("workout")
                
                NowPlayingView()
                    .tag("now playing")
            }
        } else {
            Group {
                if let s = errorMessage {
                    Text(s).foregroundColor(.red)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "iphone")
                            .imageScale(.large)
                        Text("Start a workout on your iPhone.")
                            .multilineTextAlignment(.center)
                    }
                }
            }.onAppear {
                self.selectedTab = "workout"
            }
        }
    }
    
    private var errorMessage: String? {
        guard HKHealthStore.isHealthDataAvailable() else {
            return L10n.string("HealthKit is not available on this device.")
        }
        
        switch WorkoutSessionManager.healthStore.authorizationStatus(for: .workoutType()) {
        case .notDetermined:
            return nil
        case .sharingAuthorized:
            return nil
        case .sharingDenied:
            return L10n.string("Not authorized for Apple Health. You can authorize Iron in the settings app.")
        @unknown default:
            return nil
        }
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
