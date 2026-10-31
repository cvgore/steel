//
//  CreateCustomExerciseView.swift
//  Iron
//
//  Created by Karim Abou Zeid on 17.09.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import WorkoutDataKit

struct EditCustomExerciseView: View {
    struct ExerciseValues {
        var title: String
        var description: String
        var muscles: Set<ExerciseMuscle>
        var type: Exercise.ExerciseType
        
        struct ExerciseMuscle: Hashable {
            enum MuscleType {
                case primary
                case secondary
            }
            
            let type: MuscleType
            let muscle: String
        }
    }
    
    @Binding var exerciseValues: ExerciseValues
    
    @State private var showingMuscleSelectionSheet = false
    
    private var primaryMuscles: [ExerciseValues.ExerciseMuscle] {
        exerciseValues.muscles
            .map { $0 }
            .sorted { $0.shortDisplayTitle < $1.shortDisplayTitle }
            .filter { $0.type == .primary }
    }
    
    private var secondaryMuscles: [ExerciseValues.ExerciseMuscle] {
        exerciseValues.muscles
            .map { $0 }
            .sorted { $0.shortDisplayTitle < $1.shortDisplayTitle }
            .filter { $0.type == .secondary }
    }
    
    var body: some View {
        Form {
            Section {
                TextField("Title", text: $exerciseValues.title)
                TextField("Description (Optional)", text: $exerciseValues.description)
            }
            
            Section(header: Text(L10n.string("Muscles").uppercased(with: L10n.locale))) {
                ForEach(primaryMuscles, id: \.self) { exerciseMuscle in
                    HStack {
                        Text(exerciseMuscle.shortDisplayTitle)
                        Spacer()
                        Text("Primary")
                            .foregroundColor(.secondary)
                    }
                }
                ForEach(secondaryMuscles, id: \.self) { exerciseMuscle in
                    HStack {
                        Text(exerciseMuscle.shortDisplayTitle)
                        Spacer()
                        Text("Secondary")
                            .foregroundColor(.secondary)
                    }
                }
                Button("Select Muscles")  {
                    self.showingMuscleSelectionSheet = true
                }
            }
            
            Picker("Type", selection: $exerciseValues.type) {
                ForEach(Exercise.ExerciseType.allCases, id: \.self) {
                    Text(L10n.string($0.title).capitalized(with: L10n.locale)).tag($0)
                }
            }
        }
        .sheet(isPresented: $showingMuscleSelectionSheet) {
            NavigationView {
                MuscleSelectionView(muscles: Exercise.muscleNames, selection: self.$exerciseValues.muscles)
                    .navigationBarTitle("Select Muscles", displayMode: .inline)
                    .navigationBarItems(trailing:
                        Button("Done") {
                            self.showingMuscleSelectionSheet = false
                        }
                    )
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
    }
}

extension EditCustomExerciseView.ExerciseValues.ExerciseMuscle {
    var shortDisplayTitle: String {
        let title = Exercise.commonMuscleName(for: muscle) ?? "other"
        return L10n.string(title).capitalized(with: L10n.locale)
    }
    
    var displayTitle: String {
        var title = shortDisplayTitle
        if (Exercise.commonMuscleName(for: muscle) ?? "other").caseInsensitiveCompare(muscle) != .orderedSame {
            title.append(" (\(L10n.string(muscle)))")
        }
        return L10n.string(title).capitalized(with: L10n.locale)
    }
}

struct MuscleSelectionView: View {
    var muscles: [String]
    @Binding var selection: Set<EditCustomExerciseView.ExerciseValues.ExerciseMuscle>
    
    private var primaryMuscles: [EditCustomExerciseView.ExerciseValues.ExerciseMuscle] {
        muscles
            .map { EditCustomExerciseView.ExerciseValues.ExerciseMuscle(type: .primary, muscle: $0) }
            .sorted { $0.displayTitle < $1.displayTitle }
    }
    
    private var secondaryMuscles: [EditCustomExerciseView.ExerciseValues.ExerciseMuscle] {
        muscles
            .map { EditCustomExerciseView.ExerciseValues.ExerciseMuscle(type: .secondary, muscle: $0) }
            .sorted { $0.displayTitle < $1.displayTitle }
    }
    
    var body: some View {
        List(selection: $selection) {
            Section(header: Text(L10n.string("Primary").uppercased(with: L10n.locale))) {
                ForEach(primaryMuscles, id: \.self) { exerciseMuscle in
                    Text(exerciseMuscle.displayTitle)
                }
            }
            Section(header: Text(L10n.string("Secondary").uppercased(with: L10n.locale))) {
                ForEach(secondaryMuscles, id: \.self) { exerciseMuscle in
                    Text(exerciseMuscle.displayTitle)
                }
            }
        }
        .listStyleCompat_InsetGroupedListStyle()
        .environment(\.editMode, .constant(.active))
    }
}

#if DEBUG
struct CreateCustomExerciseView_Previews: PreviewProvider {
    static var previews: some View {
        EditCustomExerciseView(exerciseValues: .constant(.init(title: "", description: "", muscles: Set(), type: .other)))
            .mockEnvironment(weightUnit: .metric)
    }
}
#endif
