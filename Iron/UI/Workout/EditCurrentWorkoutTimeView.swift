//
//  EditCurrentWorkoutTimeView.swift
//  Iron
//
//  Created by Karim Abou Zeid on 14.09.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import WorkoutDataKit

struct EditCurrentWorkoutTimeView: View {
    @Environment(\.managedObjectContext) var managedObjectContext
    @ObservedObject var workout: Workout
    @State private var operationError = false

    private func commit(_ change: (WorkoutSessionSnapshot) -> (Date, Date?)) {
        do {
            let writer = WorkoutCommandWriter(context: managedObjectContext)
            let base = try writer.snapshot(workout: workout)
            guard base.start == workout.start, base.end == workout.end else { throw WorkoutCommandWriter.Failure.notApplied }
            let (start, end) = change(base)
            try writer.write(workout: workout, mutation: .workoutTime(start: start, end: end), expectedVersion: base.version)
        } catch { operationError = true }
    }
    private var start: Binding<Date> {
        Binding(get: { workout.safeStart }, set: { value in commit { (value, $0.end) } })
    }
    private var end: Binding<Date> {
        Binding(get: { workout.safeEnd }, set: { value in commit { ($0.start ?? workout.safeStart, value) } })
    }
    private var automaticTimeTracking: Binding<Bool> {
        Binding(get: { workout.end == nil }, set: { enabled in
            commit { base in (base.start ?? workout.safeStart, enabled ? nil : max(base.start ?? Date(), Date())) }
        })
    }

    var body: some View {
        List {
            Section {
                DatePicker(selection: start, in: ...min(workout.safeEnd, Date())) {
                    Text("Start")
                }
                
                Toggle("Automatic Time Tracking", isOn: automaticTimeTracking)

                if !automaticTimeTracking.wrappedValue {
                    DatePicker(selection: end, in: workout.safeStart...Date()) {
                        Text("End")
                    }
                }
            }
            
            Section {
                Button("Reset Start Time") {
                    let now = Date()
                    commit { base in (now, base.end.map { max($0, now) }) }
                }
            }
        }
        .listStyleCompat_InsetGroupedListStyle()
        .alert(isPresented: $operationError) {
            Alert(title: Text("Could not save changes"), message: Text("Please try again."), dismissButton: .default(Text("Ok")))
        }
    }
}

#if DEBUG
struct EditCurrentWorkoutTimeView_Previews: PreviewProvider {
    static var previews: some View {
        EditCurrentWorkoutTimeView(workout: MockWorkoutData.metricRandom.currentWorkout)
    }
}
#endif
