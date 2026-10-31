//
//  ViewPersonalRecordsIntentHandler.swift
//  IronIntents
//
//  Created by Karim Abou Zeid on 07.12.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import Foundation
import CoreData
import WorkoutDataKit

class ViewPersonalRecordsIntentHandler: NSObject, ViewPersonalRecordsIntentHandling {
    func handle(intent: ViewPersonalRecordsIntent, completion: @escaping (ViewPersonalRecordsIntentResponse) -> Void) {
        guard let savedIntentExercise = intent.exercise,
            let exercise = ExerciseStore.shared.find(intentExercise: savedIntentExercise) else {
                completion(.init(code: .failure, userActivity: nil))
                return
        }
        
        // Saved shortcuts can retain an old-language display name; resolve it afresh.
        let intentExercise = exercise.intentExercise

        let request: NSFetchRequest<WorkoutSet> = WorkoutSet.fetchRequest()
        request.predicate = NSPredicate(format: "\(#keyPath(WorkoutSet.workoutExercise.exerciseUuid)) == %@", exercise.uuid as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \WorkoutSet.workoutExercise?.workout?.start, ascending: false)]
        guard let sets = try? WorkoutDataStorage.shared.persistentContainer.viewContext.fetch(request) else {
            completion(.init(code: .failure, userActivity: nil))
            return
        }
        
        guard let pr = sets.first(where: { $0.isPersonalRecord ?? false }) else {
            let response = ViewPersonalRecordsIntentResponse(code: .failureNoPersonalRecords, userActivity: nil)
            response.exercise = intentExercise
            completion(response)
            return
        }
        
        let intentSet = IntentWorkoutSet(workoutSet: pr, weightUnit: SettingsStore.shared.weightUnit)

        completion(ViewPersonalRecordsIntentResponse.success(exercise: intentExercise, set: intentSet))
    }
    
    func resolveExercise(for intent: ViewPersonalRecordsIntent, with completion: @escaping (IntentExerciseResolutionResult) -> Void) {
        ExerciseStore.shared.resolveIntentExercise(for: intent.exercise, with: completion)
    }
    
    func provideExerciseOptions(for intent: ViewPersonalRecordsIntent, with completion: @escaping ([IntentExercise]?, Error?) -> Void) {
        completion(ExerciseStore.shared.shownExercises.map { $0.intentExercise }, nil)
    }
}
