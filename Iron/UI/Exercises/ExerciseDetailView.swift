//
//  ExerciseDetailView.swift
//  Sunrise Fit
//
//  Created by Karim Abou Zeid on 04.07.19.
//  Copyright © 2019 Karim Abou Zeid Software. All rights reserved.
//

import SwiftUI
import WorkoutDataKit

struct ExerciseDetailView : View {
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var exerciseStore: ExerciseStore
    @Environment(\.managedObjectContext) var managedObjectContext
    var exercise: Exercise
    
    @State private var showOptionsMenu = false
    
    @State private var activeSheet: SheetType?
    
    private enum SheetType: Identifiable {
        case statistics
        case history
        case editExercise
        
        var id: Self { self }
    }
    
    private func sheetView(type: SheetType) -> AnyView {
        switch type {
        case .history:
            return exerciseHistorySheet.typeErased
        case .statistics:
            return exerciseStatisticsSheet.typeErased
        case .editExercise:
            return EditCustomExerciseSheet(exercise: exercise)
                .environmentObject(self.exerciseStore)
                .typeErased
        }
    }
    
    private func pdfToImage(url: URL, fit: CGSize) -> UIImage? {
        guard fit.width.isFinite, fit.height.isFinite,
              fit.width > 0, fit.height > 0 else { return nil }
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        guard let page = document.page(at: 1) else { return nil }
        
        let pageRect = page.getBoxRect(.mediaBox)
        guard pageRect.width.isFinite, pageRect.height.isFinite,
              pageRect.width > 0, pageRect.height > 0 else { return nil }
        let scale = min(fit.width / pageRect.width, fit.height / pageRect.height)
        let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            // flip
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: 1, y: -1)
            
            // aspect fit
            ctx.cgContext.scaleBy(x: scale, y: scale)
            
            // draw
            ctx.cgContext.drawPDFPage(page)
        }
        
        return img
    }

    private func exerciseImages(width: CGFloat, height: CGFloat) -> [UIImage] {
        exercise.pdfPaths
            .map { ExerciseStore.defaultBuiltInExercisesResourceURL.appendingPathComponent($0) }
            .compactMap { pdfToImage(url: $0, fit: CGSize(width: width, height: height)) }
            .compactMap { $0.tinted(with: .label) }
    }
    
    private func imageHeight(geometry: GeometryProxy) -> CGFloat {
        max(0, min(geometry.size.width, (geometry.size.height - geometry.safeAreaInsets.top - geometry.safeAreaInsets.bottom) * 0.7))
    }
    
    private var closeSheetButton: some View {
        Button("Close") {
            self.activeSheet = nil
        }
    }
    
    private var exerciseHistorySheet: some View {
        NavigationView {
            ExerciseHistoryView(exercise: self.exercise)
                .navigationBarTitle("History", displayMode: .inline)
                .navigationBarItems(leading: closeSheetButton)
                .environmentObject(self.settingsStore)
                .environment(\.managedObjectContext, self.managedObjectContext)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    private var exerciseStatisticsSheet: some View {
        NavigationView {
            ExerciseStatisticsView(exercise: self.exercise)
                .navigationBarTitle("Statistics", displayMode: .inline)
                .navigationBarItems(leading: closeSheetButton)
                .environmentObject(self.settingsStore)
                .environment(\.managedObjectContext, self.managedObjectContext)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    private func imageSection(geometry: GeometryProxy) -> some View {
        Section {
            AnimatedImageView(uiImages: self.exerciseImages(width: geometry.size.width, height: self.imageHeight(geometry: geometry)), duration: 2)
                .frame(height: self.imageHeight(geometry: geometry))
        }
    }
    
    private var descriptionSection: some View {
        Section {
            Text(self.exercise.description!)
                .lineLimit(nil)
        }
    }
    
    private var muscleSection: some View {
        Section(header: Text(L10n.string("Muscles").uppercased(with: L10n.locale))) {
            ForEach(self.exercise.primaryMuscleCommonName, id: \.hashValue) { primaryMuscle in
                HStack {
                    Text(L10n.string(primaryMuscle).capitalized(with: L10n.locale))
                    Spacer()
                    Text("Primary")
                        .foregroundColor(.secondary)
                }
            }
            ForEach(self.exercise.secondaryMuscleCommonName, id: \.hashValue) { secondaryMuscle in
                HStack {
                    Text(L10n.string(secondaryMuscle).capitalized(with: L10n.locale))
                    Spacer()
                    Text("Secondary")
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    private var stepsSection: some View {
        Section(header: Text(L10n.string("Steps").uppercased(with: L10n.locale))) {
            ForEach(self.exercise.steps, id: \.hashValue) { step in
                Text(step as String)
                    .lineLimit(nil)
            }
        }
    }
    
    private var tipsSection: some View {
        Section(header: Text(L10n.string("Tips").uppercased(with: L10n.locale))) {
            ForEach(self.exercise.tips, id: \.hashValue) { tip in
                Text(tip as String)
                    .lineLimit(nil)
            }
        }
    }
    
    private var referencesSection: some View {
        Section(header: Text(L10n.string("References").uppercased(with: L10n.locale))) {
            ForEach(self.exercise.references, id: \.hashValue) { reference in
                Button(reference as String) {
                    if let url = URL(string: reference) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
    }
    
    private var aliasSection: some View {
        Section(header: Text(L10n.string("Also known as").uppercased(with: L10n.locale))) {
            ForEach(self.exercise.alias, id: \.hashValue) { alias in
                Text(alias)
            }
        }
    }
    
    private var options: [ActionSheet.Button] {
        var options: [ActionSheet.Button] = [
            .default(Text("History"), action: {
                self.activeSheet = .history
            }),
            .default(Text("Statistics"), action: {
                self.activeSheet = .statistics
            })
        ]
        if exerciseStore.isHidden(exercise: exercise) {
            options.append(.default(Text("Unhide"), action: {
                self.exerciseStore.show(exercise: self.exercise)
            }))
        } else if !exercise.isCustom {
            options.append(.default(Text("Hide"), action: {
                self.exerciseStore.hide(exercise: self.exercise)
            }))
        }
        options.append(.cancel())
        return options
    }
    
    var body: some View {
        GeometryReader { geometry in
            List {
                if !self.exercise.pdfPaths.isEmpty {
                    self.imageSection(geometry: geometry)
                }

                if self.exercise.description != nil {
                    self.descriptionSection
                }

                if !(self.exercise.primaryMuscleCommonName.isEmpty && self.exercise.secondaryMuscleCommonName.isEmpty) {
                    self.muscleSection
                }

                if !self.exercise.steps.isEmpty {
                    self.stepsSection
                }

                if !self.exercise.tips.isEmpty {
                    self.tipsSection
                }

                if !self.exercise.references.isEmpty {
                    self.referencesSection
                }
                
                if !self.exercise.alias.isEmpty {
                    self.aliasSection
                }
            }
            .listStyleCompat_InsetGroupedListStyle()
        }
        .sheet(item: $activeSheet) { type in
            self.sheetView(type: type)
        }
        .actionSheet(isPresented: $showOptionsMenu) {
            ActionSheet(title: Text("Exercise"), message: nil, buttons: options)
        }
        .navigationBarTitle(Text(exercise.title), displayMode: .inline)
        .navigationBarItems(trailing:
            HStack(spacing: NAVIGATION_BAR_SPACING) {
                Button(action: {
                    self.showOptionsMenu = true
                }) {
                    Image(systemName: "ellipsis")
                    .accessibility(label: Text("More"))
                        .padding([.leading, .top, .bottom])
                }
                if exercise.isCustom {
                    Button("Edit") {
                        self.activeSheet = .editExercise
                    }
                }
            }
        )
    }
}

#if DEBUG
struct ExerciseDetailView_Previews : PreviewProvider {
    static var previews: some View {
        NavigationView {
            ExerciseDetailView(exercise: ExerciseStore.shared.exercises.first(where: { $0.everkineticId == 99 })!)
                .mockEnvironment(weightUnit: .metric)
        }
    }
}
#endif
