//
//  RestTimerStore.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 12.08.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation
import Combine
import CoreData
import WorkoutDataKit
import UIKit

// to be used in other places
let restTimerDurationFormatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .positional
    formatter.allowedUnits = [.minute, .second]
    formatter.zeroFormattingBehavior = .pad
    return formatter
}()

let restTimerCustomTimes: [TimeInterval] = {
    stride(from: 30 as TimeInterval, through: 10*60, by: 5).map { $0 }
}()

final class RestTimerStore: ObservableObject {
    static let shared = RestTimerStore() // singleton

    let objectWillChange = ObservableObjectPublisher()

    private var userDefaults: UserDefaults
    private var foregroundObserver: NSObjectProtocol?
    private let contextProvider: () -> NSManagedObjectContext
    private let enableEffects: Bool
    @Published var operationError = false

    init(userDefaults: UserDefaults,
         contextProvider: @escaping () -> NSManagedObjectContext = { WorkoutDataStorage.shared.persistentContainer.viewContext },
         enableEffects: Bool = true, observeLifecycle: Bool = true) {
        self.userDefaults = userDefaults
        self.contextProvider = contextProvider
        self.enableEffects = enableEffects
        if observeLifecycle {
            // Defer stack access: stack initialization can itself access this singleton.
            DispatchQueue.main.async { [weak self] in self?.restoreCommittedRest() }
            foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                object: nil, queue: .main) { [weak self] _ in self?.restoreCommittedRest() }
        }
    }

    deinit {
        if let observer = foregroundObserver { NotificationCenter.default.removeObserver(observer) }
    }

    private convenience init() {
        self.init(userDefaults: UserDefaults.standard)
    }

    var restTimerStart: Date? {
        get {
            userDefaults.restTimerStart
        }
        set {
            setRest(start: newValue, duration: restTimerDuration)
        }
    }

    var restTimerDuration: TimeInterval? {
        get {
            userDefaults.restTimerDuration
        }
        set {
            setRest(start: restTimerStart, duration: newValue)
        }
    }

    /// Update the absolute pair once. Failed commits leave defaults and effects untouched.
    @discardableResult
    func setRest(start: Date?, duration: TimeInterval?) -> Bool {
        let context = contextProvider()
        do {
            if let workout = try context.fetch(Workout.currentWorkoutFetchRequest).first {
                let writer = WorkoutCommandWriter(context: context)
                let base = try writer.snapshot(workout: workout)
                // Duration buttons derive their result from the displayed pair. A remote
                // rest update must be presented before an action can replace it.
                if base.sessionID != nil,
                   base.restStart != restTimerStart || base.restDuration != restTimerDuration {
                    presentCommittedRest(start: base.restStart, duration: base.restDuration)
                    throw WorkoutCommandWriter.Failure.notApplied
                }
                try writer.write(workout: workout, mutation: .rest(start: start, duration: duration), expectedVersion: base.version)
            }
            presentCommittedRest(start: start, duration: duration)
            return true
        } catch {
            operationError = true
            return false
        }
    }

    /// Presentation of an already committed result must never issue another command.
    func presentCommittedRest(start: Date?, duration: TimeInterval?) {
        objectWillChange.send()
        userDefaults.restTimerStart = start
        userDefaults.restTimerDuration = duration
        if enableEffects {
            updateNotification()
            updateWatch()
        }
    }

    func restoreCommittedRest() {
        let context = contextProvider()
        do {
            guard let workout = try context.fetch(Workout.currentWorkoutFetchRequest).first else { return }
            let snapshot = try WorkoutCommandWriter(context: context).snapshot(workout: workout)
            guard snapshot.sessionID != nil else { return }
            presentCommittedRest(start: snapshot.restStart, duration: snapshot.restDuration)
        } catch { operationError = true }
    }

    var recentRestTimes: [TimeInterval] {
        get {
            userDefaults.recentRestTimes
        }
        set {
            self.objectWillChange.send()
            userDefaults.recentRestTimes = newValue
        }
    }

    func notifyKeepRestTimerRunningChanged() { // TODO in future somehow subscribe to SettingsStore.shared.keepRestTimerRunning changes
        self.objectWillChange.send()
        updateWatch()
    }

    private func updateNotification() {
        NotificationManager.shared.updateRestTimerUpNotificationRequest(remainingTime: self.restTimerRemainingTime, totalTime: self.restTimerDuration)
    }

    private func updateWatch() {
        if let uuid = WatchConnectionManager.shared.currentWatchWorkoutUuid {
            WatchConnectionManager.shared.updateWatchWorkoutRestTimer(end: restTimerEnd, keepRunning: SettingsStore.shared.keepRestTimerRunning, uuid: uuid)
        }
    }
}

extension RestTimerStore {
    var restTimerEnd: Date? {
        guard let duration = restTimerDuration else { return nil }
        return restTimerStart?.addingTimeInterval(duration)
    }

    var restTimerRemainingTime: TimeInterval? {
        guard let restTimerEnd = restTimerEnd else { return nil }
        let remainingTime = restTimerEnd.timeIntervalSince(Date())
        guard remainingTime >= 0 || SettingsStore.shared.keepRestTimerRunning else { return nil }
        return remainingTime
    }
}

extension RestTimerStore {
    func cancel() {
        setRest(start: nil, duration: nil)
    }
}
