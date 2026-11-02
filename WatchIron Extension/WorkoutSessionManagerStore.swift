//
//  WorkoutSessionManagerStore.swift
//  WatchIron Extension
//
//  Created by Karim Abou Zeid on 09.11.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation
import HealthKit
import Combine
import WatchKit
import os.log

class WorkoutSessionManagerStore: ObservableObject {
    static let shared = WorkoutSessionManagerStore()
    // Persistence is separate from HealthKit tracking; STEEL-9 consumes this same owner.
    let workoutReplica = WorkoutReplicaStore.shared
    private var measurementGate = WorkoutMeasurementGate()
    private var pendingPreparations: [(HKWorkoutConfiguration, (Result<Void, Error>) -> Void)] = []
    private var inFlightHealthEffects = Set<UUID>()
    var healthEffectError: String? {
        didSet { DispatchQueue.main.async { self.objectWillChange.send() } }
    }
    
    let objectWillChange = PassthroughSubject<Void, Never>()
    
    private var _workoutSessionManager: WorkoutSessionManager? {
        didSet { // don't use willSet, somehow this is sometimes to early in this case
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
    }
    
    var workoutSessionManager: WorkoutSessionManager? {
        get {
            return _workoutSessionManager
        }
        set {
            dispatchPrecondition(condition: DispatchPredicate.onQueue(WorkoutSessionManager.accessQueue))
            _workoutSessionManager = newValue
        }
    }
}

extension WorkoutSessionManagerStore {
    func recoverActiveSession() {
        WorkoutSessionManager.perform {
            guard self.measurementGate.beginRecovery() else { return }
            WorkoutSessionManager.healthStore.recoverActiveWorkoutSession { session, error in
                WorkoutSessionManager.perform {
                    if let session = session {
                        // No creation/preparation can pass the gate until recovery attaches its owner.
                        let manager = WorkoutSessionManager(session: session)
                        self.workoutSessionManager = manager
                        let collecting = manager.hasCollectedWorkout && [.running, .paused].contains(manager.state)
                        self.measurementGate.finishRecovery(succeeded: true, collectingID: collecting ? manager.uuid : nil)
                    } else if let error = error {
                        self.measurementGate.finishRecovery(succeeded: false)
                        self.healthEffectError = L10n.string("Could not recover workout measurements. Please retry.")
                        os_log("Workout recovery failed: %@", type: .error, error.localizedDescription)
                        return
                    } else { self.measurementGate.finishRecovery(succeeded: true) }
                    self.healthEffectError = nil
                    self.presentReplicaRest()
                    self.reconcileSharedHealthEffect()
                    self.drainPreparations()
                    self.resumePendingTrackingStart()
                }
            }
        }
    }
    private func drainPreparations() {
        guard measurementGate.canPrepare else { return }
        let pending = pendingPreparations; pendingPreparations = []
        for (configuration, completion) in pending {
            ensurePreparedWorkoutSession(configuration: configuration, completion: completion)
        }
    }

    /// - Parameters:
    ///   - completion: When the result is successful, the `workoutSessionManager` is set and the workout session is in a state other than `.ended` or `.notStarted`.
    ///                 If a workout session that is not `.ended` or `.notStarted` existed, nothing is done. Otherwise a new workout session is prepared.
    func ensurePreparedWorkoutSession(configuration: HKWorkoutConfiguration, completion: @escaping (Result<Void, Error>) -> Void) {
        WorkoutSessionManager.perform {
            os_log("Ensuring prepared workout session")
            guard self.measurementGate.canPrepare else {
                self.pendingPreparations.append((configuration, completion))
                self.recoverActiveSession()
                return
            }
            // check if there already is a current workout session
            if let workoutSessionManager = self.workoutSessionManager {
                let state = workoutSessionManager.state
                os_log("Workout session manager with state=%@ exists", type: .debug, state.name)
                // only create a new session if the current session is not running
                guard state == .ended || state == .notStarted else {
                    // there already is a running workout session, startWorkout will take care of it
                    os_log("Keeping workout session with state=%@", state.name)
                    completion(.success(()))
                    return
                }
            }
            
            let workoutSession: HKWorkoutSession
            do {
                os_log("Creating new workout session")
                workoutSession = try HKWorkoutSession(healthStore: WorkoutSessionManager.healthStore, configuration: configuration)
            } catch {
                completion(.failure(error))
                return
            }
            
            self.workoutSessionManager = WorkoutSessionManager(session: workoutSession)
            self.workoutSessionManager?.prepare()
            
            completion(.success(()))
        }
    }
    
    /**
     Starts a `WorkoutSessionManager`, creating/reusing/overwriting any existing `workoutSessionManager` as necessary.
     - Postcondition
     If an error occured, `workoutSessionManager` is set to `nil`, otherwise `workoutSessionManager.uuid` is set to `uuid` and the `workoutSessionManager` is being started.
     */
    func startWorkoutSession(start: Date, uuid: UUID) {
        WorkoutSessionManager.perform {
            os_log("Starting workout session start=%@ uuid=%@", start as NSDate, uuid as NSUUID)
            guard self.measurementGate.canPrepare else { return }
            
            // A new journal may join while the prior builder finishes asynchronously.
            // Its completion retains the old manager; never discard that in-flight builder.
            if let manager = self.workoutSessionManager, let currentID = manager.uuid,
               self.inFlightHealthEffects.contains(currentID) {
                guard currentID != uuid else { return }
                self.workoutSessionManager = nil
            }

            // 1. make sure we have a workout session manager, create it if necessary
            
            var workoutSessionManager: WorkoutSessionManager
            if let manager = self.workoutSessionManager {
                workoutSessionManager = manager
            } else {
                os_log("No workout session manager is set", type: .info)
                
                let workoutConfiguration = HKWorkoutConfiguration()
                workoutConfiguration.activityType = .traditionalStrengthTraining
                
                // create a new workout session manager
                do {
                    os_log("Creating workout session")
                    let session = try HKWorkoutSession(healthStore: WorkoutSessionManager.healthStore, configuration: workoutConfiguration)
                    workoutSessionManager = WorkoutSessionManager(session: session)
                    self.workoutSessionManager = workoutSessionManager
                } catch {
                    os_log("Could not create new workout session: %@", type: .error, error.localizedDescription)
                    return
                }
            }
            
            // 2. What if the session is not .prepared or .notStarted ?
            
            if let currentUuid = workoutSessionManager.uuid {
                // consider workout session manager as started
                os_log("Workout session manager already has uuid, treating as already started", type: .fault, workoutSessionManager.state.name)
                
                if currentUuid == uuid {
                    
                    // 2.1 If the workout session manager has the same uuid, reuse the manager or create a new if the state is .ended
                    
                    os_log("Workout session manager uuid=%@ matches new uuid", type: .fault, currentUuid as NSUUID, workoutSessionManager.state.name)
                    switch workoutSessionManager.state {
                    case .prepared, .notStarted:
                        break
                    case .ended:
                        // we can have a ended workout session manager that was not set to nil when it was ended by the OS
                        os_log("Discarding workout session manager")
                        workoutSessionManager.discard()
                        self.workoutSessionManager = nil
                        
                        // create a new workout session manager
                        do {
                            os_log("Creating workout session")
                            let session = try HKWorkoutSession(healthStore: WorkoutSessionManager.healthStore, configuration: workoutSessionManager.workoutConfiguration)
                            workoutSessionManager = WorkoutSessionManager(session: session)
                            self.workoutSessionManager = workoutSessionManager
                        } catch {
                            os_log("Could not create new workout session: %@", type: .error, error.localizedDescription)
                            return
                        }
                    default:
                        // the session is not ended and was already started, reuse it
                        os_log("Falling back to just updating the start date for workout session manager")
                        workoutSessionManager.updateStartDate(start)
                        if self.measurementGate.canAcknowledge(workoutID: uuid) { self.acknowledgeTrackingStart(uuid) }
                        else { self.healthEffectError = L10n.string("Could not recover workout measurements. Please retry.") }
                        return
                    }
                    
                } else {
                    
                    // 2.2 If the workout session manager has a different uuid, create a new manager
                    
                    os_log("Workout session manager uuid=%@ differs from new uuid=%@", type: .fault, (currentUuid as NSUUID?) ?? "nil", uuid as NSUUID)
                    
                    os_log("Discarding workout session manager")
                    workoutSessionManager.discard()
                    self.workoutSessionManager = nil
                    
                    do {
                        os_log("Creating workout session")
                        let session = try HKWorkoutSession(healthStore: WorkoutSessionManager.healthStore, configuration: workoutSessionManager.workoutConfiguration)
                        workoutSessionManager = WorkoutSessionManager(session: session)
                        self.workoutSessionManager = workoutSessionManager
                    } catch {
                        os_log("Could not create new workout session: %@", type: .error, error.localizedDescription)
                        return
                    }
                }
            } else {
                // consider workout as not started
                switch workoutSessionManager.state {
                case .prepared, .notStarted:
                    break
                default:
                    os_log("Discarding workout session manager without uuid state=%@", type: .fault, workoutSessionManager.state.name)
                    assertionFailure("This should not happen, because a workout gets assigned a UUID when it is started")
                    workoutSessionManager.discard()
                    self.workoutSessionManager = nil
                    
                    // create a new workout session manager
                    do {
                        os_log("Creating workout session")
                        let session = try HKWorkoutSession(healthStore: WorkoutSessionManager.healthStore, configuration: workoutSessionManager.workoutConfiguration)
                        workoutSessionManager = WorkoutSessionManager(session: session)
                        self.workoutSessionManager = workoutSessionManager
                    } catch {
                        os_log("Could not create new workout session: %@", type: .error, error.localizedDescription)
                        return
                    }
                }
            }
            
            // 3. Set the UUID
            
            assert(workoutSessionManager.state == .prepared || workoutSessionManager.state == .notStarted)
            
            do {
                os_log("Setting uuid=%@ for workout session manager", uuid as NSUUID)
                try workoutSessionManager.setUuid(uuid)
                self.presentReplicaRest()
            } catch {
                os_log("Could not set uuid: %@", type: .error, error.localizedDescription)
                os_log("Discarding workout session manager", type: .info)
                workoutSessionManager.discard()
                self.workoutSessionManager = nil
                return
            }
            
            // 4. Start!
            
            guard self.measurementGate.beginCollection(workoutID: uuid) else { return }
            os_log("Starting workout session manager")
            workoutSessionManager.start(start: start) { result in
                WorkoutSessionManager.perform {
                    switch result {
                    case .success:
                        if self.measurementGate.finishCollection(workoutID: uuid, succeeded: true) {
                            self.acknowledgeTrackingStart(uuid)
                            WKInterfaceDevice.current().play(.start)
                        }
                    case .failure(let error):
                        self.measurementGate.finishCollection(workoutID: uuid, succeeded: false)
                        self.healthEffectError = L10n.string("Could not start workout measurements. Please retry.")
                        os_log("Could not start workout session manager: %@", type: .error, error.localizedDescription)
                        workoutSessionManager.discard()
                        if self.workoutSessionManager === workoutSessionManager { self.workoutSessionManager = nil }
                    }
                    self.drainPreparations()
                    self.reconcileSharedHealthEffect()
                    // A different pending workout may now start; failed same-workout intent waits for retry.
                    if (try? self.workoutReplica.get().snapshot?.workoutID) != uuid { self.resumePendingTrackingStart() }
                }
            }
        }
    }

    func endWorkoutSession(start: Date, end: Date, title: String?, uuid: UUID) {
        WorkoutSessionManager.perform {
            os_log("Ending workout session start=%@ end=%@ title=%@ uuid=%@", start as NSDate, end as NSDate, title ?? "nil", uuid as NSUUID)
            
            guard let workoutSessionManager = self.workoutSessionManager else {
                // invalid
                // should not happen normally, but maybe could happen?
                os_log("Attempt to end workout session manager while no workout session manager is set", type: .fault)
                return
            }
            
            // make sure the message means the current workout
            guard workoutSessionManager.uuid == uuid else {
                // invalid
                // should not happen normally, but maybe could happen?
                if workoutSessionManager.uuid == nil {
                    os_log("Attempt to end workout session manager that has no UUID", type: .fault)
                } else {
                    os_log("Attempt to end workout session manager with different UUID", type: .fault)
                }
                return
            }
            
            workoutSessionManager.updateStartDate(start)

            if let title = title {
                do {
                    os_log("Setting title for workout session manager")
                    try workoutSessionManager.setTitle(title)
                } catch {
                    os_log("Could not set title: %@", type: .error, error.localizedDescription)
                    // continue though
                }
            }
            
            os_log("Ending workout session manager")
            workoutSessionManager.end(end: end) { result in
                WorkoutSessionManager.perform {
                    switch result {
                    case .success:
                        WKInterfaceDevice.current().play(.stop)
                        self.workoutSessionManager = nil
                        os_log("Successfully ended workout session manager", type: .info)
                    case .failure(let error):
                        WKInterfaceDevice.current().play(.failure)
                        os_log("Could not end workout session manager: %@", type: .error, error.localizedDescription)
                        os_log("Discarding workout session manager", type: .info)
                        workoutSessionManager.discard()
                        self.workoutSessionManager = nil
                    }
                }
            }
        }
    }
    
    func updateWorkoutSessionStart(start: Date, uuid: UUID) {
        WorkoutSessionManager.perform {
            os_log("Updating workout session start=%@ uuid=%@", start as NSDate, uuid as NSUUID)
            guard let workoutSessionManager = self.workoutSessionManager else {
                // invalid
                os_log("Attempt to update start time on workout while no workout session manager is set", type: .fault)
                return
            }
            
            // make sure the message means the current workout
            guard workoutSessionManager.uuid == uuid else {
                // invalid
                if workoutSessionManager.uuid == nil {
                    print("warning: attempt to update start for workout with no UUID")
                } else {
                    print("warning: attempt to update start for workout with different UUID")
                }
                return
            }
            
            workoutSessionManager.updateStartDate(start)
        }
    }
    
    func updateWorkoutSessionEnd(end: Date?, uuid: UUID) {
        WorkoutSessionManager.perform {
            os_log("Updating workout session end=%@ uuid=%@", (end as NSDate?) ?? "nil", uuid as NSUUID)
            guard let workoutSessionManager = self.workoutSessionManager else {
                // invalid
                print("warning: attempt to update end time on workout while no workout session manager is set")
                return
            }
            
            // make sure the message means the current workout
            guard workoutSessionManager.uuid == uuid else {
                // invalid
                // should not happen normally, but maybe could happen?
                if workoutSessionManager.uuid == nil {
                    os_log("Attempt to update end for workout session manager that has no UUID", type: .fault)
                } else {
                    os_log("Attempt to update end for workout session manager with different UUID", type: .fault)
                }
                return
            }
            
            workoutSessionManager.updateEndDate(end)
        }
    }
    
    func discardWorkoutSession(uuid: UUID) {
        WorkoutSessionManager.perform {
            os_log("Discarding workout session uuid=%@", uuid as NSUUID)
            guard let workoutSessionManager = self.workoutSessionManager else {
                // invalid
                // should not happen normally, but can happen
                print("warning: attempt to discard workout while no workout session manager is set")
                return
            }
            
            // make sure the message means the current workout
            guard workoutSessionManager.uuid == uuid else {
                // invalid
                // should not happen normally, but maybe could happen?
                if workoutSessionManager.uuid == nil {
                    os_log("Attempt to discard workout session manager that has no UUID", type: .fault)
                } else {
                    os_log("Attempt to discard workout session manager with different UUID", type: .fault)
                }
                return
            }
            
            workoutSessionManager.discard()
            self.workoutSessionManager = nil
            print("success: discarded workout session")
        }
    }
    
    func discardUnstartedWorkoutSession() {
        WorkoutSessionManager.perform {
            os_log("Discarding unstarted workout session")
            guard let workoutSessionManager = self.workoutSessionManager else {
                // invalid
                // should not happen normally, but can happen
                os_log("Attempt to discard unstarted workout session while no workout session manager is set", type: .fault)
                return
            }
            
            // make sure no UUID is set
            if let uuid = workoutSessionManager.uuid {
                // can happen, but something probably went wrong before
                os_log("Attempt to discard unstarted workout session with uuid=%@", type: .fault, uuid as NSUUID)
                return // treat a workout session with a UUID as started, return here!
            }
            
            guard workoutSessionManager.state == .prepared || workoutSessionManager.state == .notStarted else {
                // can happen, but something probably went wrong before
                os_log("Attempt to discard unstarted workout session with state=%@", type: .fault, workoutSessionManager.state.name)
                return
            }
            
            workoutSessionManager.discard()
            self.workoutSessionManager = nil
            os_log("Discarded unstarted workout session", type: .info)
        }
    }
    
    func discardWorkoutSession() {
        WorkoutSessionManager.perform {
            os_log("Discarding workout session")
            guard let workoutSessionManager = self.workoutSessionManager else {
                // invalid
                // should not happen normally, but can happen
                print("warning: attempt to discard workout session while no workout session manager is set")
                return
            }
            
            workoutSessionManager.discard()
            self.workoutSessionManager = nil
            print("success: discarded workout session")
        }
    }
    
    func updateWorkoutSessionRestTimer(end: Date?, keepRunning: Bool?, uuid: UUID) {
        WorkoutSessionManager.perform {
            os_log("Updating workout session rest timer end=%@ keepRunning=%@ uuid=%@", (end as NSDate?) ?? "nil", keepRunning.map { String(describing: $0) } ?? "nil", uuid as NSUUID)
            guard let workoutSessionManager = self.workoutSessionManager else {
                // invalid
                // should not happen normally, but can happen
                print("warning: attempt to update rest timer while no workout session manager is set")
                return
            }
            
            // make sure the message means the current workout
            guard workoutSessionManager.uuid == uuid else {
                // invalid
                // should not happen normally, but maybe could happen?
                if workoutSessionManager.uuid == nil {
                    os_log("Attempt to update rest timer for workout session manager that has no UUID", type: .fault)
                } else {
                    os_log("Attempt to update rest timer for workout session manager with different UUID", type: .fault)
                }
                return
            }
            
            workoutSessionManager.restTimerEnd = end
            if let keepRunning = keepRunning {
                workoutSessionManager.keepRestTimerRunning = keepRunning
            }
        }
    }
    
    func updateWorkoutSessionSelectedSetText(text: String?, uuid: UUID) {
        WorkoutSessionManager.perform {
            os_log("Updating workout session selected text=%@ uuid=%@", text ?? "nil", uuid as NSUUID)
            guard let workoutSessionManager = self.workoutSessionManager else {
                // invalid
                // should not happen normally, but can happen
                print("warning: attempt to update selected set text while no workout session manager is set")
                return
            }
            
            // make sure the message means the current workout
            guard workoutSessionManager.uuid == uuid else {
                // invalid
                // should not happen normally, but maybe could happen?
                if workoutSessionManager.uuid == nil {
                    os_log("Attempt to update selected text for workout session manager that has no UUID", type: .fault)
                } else {
                    os_log("Attempt to update selected text for workout session manager with different UUID", type: .fault)
                }
                return
            }
            
            workoutSessionManager.selectedSetText = text
        }
    }
}

extension WorkoutSessionManagerStore {
    /// Watch editors commit locally first; transport always reuses the durable operation ID.
    @discardableResult
    func submitWorkoutMutation(_ mutation: WorkoutMutation, id: UUID = UUID(), date: Date = Date(), expectedSetResult: WorkoutSetDraft? = nil, trackCompletion: Bool = false, navigation: WatchWorkoutNavigation? = nil) throws -> WorkoutOperation {
        switch mutation {
        case .saveSet, .requestFinish, .requestCancel: break
        default: throw WorkoutReplicaStore.Failure.invalidMutation
        }
        let operation = try workoutReplica.get().submit(mutation, id: id, date: date, expectedSetResult: expectedSetResult, trackCompletion: trackCompletion, navigation: navigation)
        presentReplicaRest()
        DispatchQueue.main.async {
            self.objectWillChange.send()
            PhoneConnectionManager.shared.synchronizeWorkout()
        }
        return operation
    }
}


extension WorkoutSessionManagerStore {
    func presentReplicaRest() {
        guard let snapshot = try? workoutReplica.get().snapshot else { return }
        WorkoutSessionManager.perform {
            guard let manager = self.workoutSessionManager, manager.uuid == snapshot.workoutID else { return }
            if let start = snapshot.start { manager.updateStartDate(start) }
            manager.updateEndDate(snapshot.end)
            manager.restTimerEnd = snapshot.restStart.flatMap { start in snapshot.restDuration.map { start.addingTimeInterval($0) } }
            if let keepRunning = snapshot.editorContext?.keepRestTimerRunning { manager.keepRestTimerRunning = keepRunning }
        }
    }
}


extension WorkoutSessionManagerStore {
    func resumePendingTrackingStart() {
        do {
            let replica = try workoutReplica.get()
            guard let request = replica.trackingStartToResume else { return }
            startWorkoutSession(start: request.start, uuid: request.workoutID)
        } catch { reportHealthEffectError(error) }
    }
    private func acknowledgeTrackingStart(_ id: UUID) {
        do {
            try workoutReplica.get().acknowledgeTrackingStart(workoutID: id)
            healthEffectError = nil
        }
        catch { reportHealthEffectError(error) }
    }

    /// Domain completion is already durable. This effect can fail without altering the journal.
    func reconcileSharedHealthEffect() {
        WorkoutSessionManager.perform {
            do {
                guard self.measurementGate.canPrepare else { return }
                let replica = try self.workoutReplica.get()
                let state = replica.state
                let terminals = (state.acceptedSnapshot.map { [$0] } ?? []) + state.archivedSessions.map(\.acceptedSnapshot)
                for snapshot in terminals where snapshot.phase.isTerminal {
                    let id = snapshot.workoutID
                    if self.inFlightHealthEffects.contains(id) { continue }
                    if let manager = self.workoutSessionManager, manager.uuid == id {
                        manager.restTimerEnd = nil; manager.stopMeasurements()
                    }
                    if snapshot.phase == .cancelled {
                        // Recovery can deliver a previously discarded session after the tombstone was loaded.
                        if let manager = self.workoutSessionManager, manager.uuid == id {
                            manager.restTimerEnd = nil; manager.discard(); self.workoutSessionManager = nil
                        }
                        if replica.state.healthEffects?[id] != .discarded {
                            try replica.recordHealthEffect(.discarded, workoutID: id)
                            self.notifyHealthChange()
                        }
                        continue
                    }
                    if replica.state.healthEffects?[id] == .saving {
                        try replica.recordHealthEffect(.uncertain, workoutID: id)
                        self.notifyHealthChange()
                        continue
                    }
                    guard replica.state.healthEffects?[id] == nil || replica.state.healthEffects?[id] == .pending else { continue }
                    guard let manager = self.workoutSessionManager, manager.uuid == id,
                          WorkoutSessionManager.healthStore.authorizationStatus(for: .workoutType()) == .sharingAuthorized else {
                        if let manager = self.workoutSessionManager, manager.uuid == id {
                            manager.restTimerEnd = nil; manager.stopMeasurements()
                        }
                        try replica.recordHealthEffect(.blocked, workoutID: id)
                        self.notifyHealthChange()
                        continue
                    }
                    manager.restTimerEnd = nil
                    guard try replica.claimHealthEffect(workoutID: id) else { continue }
                    self.inFlightHealthEffects.insert(id)
                    manager.end(end: snapshot.end ?? Date(), allowStartDateReplacement: false) { result in
                        WorkoutSessionManager.perform {
                            self.inFlightHealthEffects.remove(id)
                            do {
                                switch result {
                                case .success:
                                    try replica.recordHealthEffect(.saved, workoutID: id)
                                    if self.workoutSessionManager === manager { self.workoutSessionManager = nil }
                                case .failure:
                                    // HealthKit may have committed before a failure/crash; retain recovery state.
                                    try replica.recordHealthEffect(.uncertain, workoutID: id)
                                }
                                self.notifyHealthChange()
                            } catch { self.reportHealthEffectError(error) }
                        }
                    }
                }
            } catch { self.reportHealthEffectError(error) }
        }
    }

    func recoverSharedHealthEffect() {
        WorkoutSessionManager.perform {
            do {
                let replica = try self.workoutReplica.get()
                // Retry only effects that never attempted a save and still have their builder.
                for (id, effect) in replica.state.healthEffects ?? [:] where effect == .blocked {
                    if self.workoutSessionManager?.uuid == id, !self.inFlightHealthEffects.contains(id) {
                        try replica.retryBlockedHealthEffect(workoutID: id)
                    }
                }
                replica.recoverHealthEffects(excluding: self.inFlightHealthEffects, findSaved: { id, found in
                    let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: [id.uuidString])
                    let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                        found(error == nil && samples?.isEmpty == false)
                    }
                    WorkoutSessionManager.healthStore.execute(query)
                }, completion: { id, result in
                    WorkoutSessionManager.perform {
                        switch result {
                        case .success:
                            if replica.state.healthEffects?[id] == .saved, self.workoutSessionManager?.uuid == id {
                                self.workoutSessionManager = nil
                            }
                            self.notifyHealthChange()
                        case .failure(let error): self.reportHealthEffectError(error)
                        }
                    }
                })
                self.reconcileSharedHealthEffect()
            } catch { self.reportHealthEffectError(error) }
        }
    }
    var healthRecovery: (id: UUID, effect: WorkoutReplicaStore.HealthEffect)? {
        guard let effects = try? workoutReplica.get().state.healthEffects else { return nil }
        return effects.sorted { $0.key.uuidString < $1.key.uuidString }.first {
            [.saving, .uncertain, .blocked].contains($0.value)
        }.map { ($0.key, $0.value) }
    }
    private func notifyHealthChange() {
        healthEffectError = nil
        DispatchQueue.main.async { self.objectWillChange.send() }
    }
    private func reportHealthEffectError(_ error: Error) {
        os_log("Health effect state could not be saved: %@", type: .error, error.localizedDescription)
        healthEffectError = L10n.string("Could not save measurement recovery status.")
    }
}
