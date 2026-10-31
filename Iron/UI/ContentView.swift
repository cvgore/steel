//
//  SessionContentView.swift
//  SwiftUI Playground
//
//  Created by Karim Abou Zeid on 19.06.19.
//  Copyright © 2019 Karim Abou Zeid. All rights reserved.
//

import SwiftUI
import WorkoutDataKit

let NAVIGATION_BAR_SPACING: CGFloat = 16

struct ContentView : View {
    @EnvironmentObject private var sceneState: SceneState
    
    @State private var languageCode = L10n.languageCode

    @State private var restoreResult: IdentifiableHolder<Result<Void, Error>>?
    @State private var restoreBackupData: IdentifiableHolder<Data>?
    
    var body: some View {
        tabView
            .environment(\.locale, Locale(identifier: languageCode))
            .onReceive(NotificationCenter.default.publisher(for: .appLanguageChanged)) { _ in
                languageCode = L10n.languageCode
            }
            .edgesIgnoringSafeArea([.top, .bottom])
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name.RestoreFromBackup)) { output in
                guard let backupData = output.userInfo?[restoreFromBackupDataUserInfoKey] as? Data else { return }
                self.restoreBackupData = IdentifiableHolder(value: backupData)
            }
            .overlay(
                Color.clear.frame(width: 0, height: 0)
                    // This is a hack, we need to have this in an overlay and in Color.clear so it also works on iPad, tested on iOS 13.4
                    .actionSheet(item: $restoreBackupData) { restoreBackupDataHolder in
                        RestoreActionSheet.create(context: WorkoutDataStorage.shared.persistentContainer.viewContext, exerciseStore: ExerciseStore.shared, data: { restoreBackupDataHolder.value }) { result in
                            self.restoreResult = IdentifiableHolder(value: result)
                        }
                    }
            )
            .alert(item: $restoreResult) { restoreResultHolder in
                RestoreActionSheet.restoreResultAlert(restoreResult: restoreResultHolder.value)
            }
    }
    
    @ViewBuilder
    private var tabView: some View {
        if #available(iOS 14, *) {
            TabView(selection: $sceneState.selectedTabNumber) {
                FeedView()
                    .tag(SceneState.Tab.feed.rawValue)
                    .tabItem {
                        Label("Feed", systemImage: "house")
                    }

                HistoryView()
                    .tag(SceneState.Tab.history.rawValue)
                    .tabItem {
                        Label("History", systemImage: "clock")
                    }

                WorkoutTab()
                    .tag(SceneState.Tab.workout.rawValue)
                    .tabItem {
                        Label("Workout", systemImage: "plus.diamond")
                    }

                ExerciseMuscleGroupsView()
                    .tag(SceneState.Tab.exercises.rawValue)
                    .tabItem {
                        Label("Exercises", systemImage: "tray.full")
                    }

                SettingsView()
                    .tag(SceneState.Tab.settings.rawValue)
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
            }
            .productionEnvironment()
        } else {
            /**
             *  We inject .productionEnvironment() for every tab, because when the "screen reading" accessibility setting is enabled,
             *  some Tabs get created by the system in the background without its parents environment! This is probably a bug and it happens since iOS 13.4
             */
            UITabView(viewControllers: [
                FeedView()
                    .productionEnvironment()
                    .hostingController()
                    .tabItem(title: L10n.string("Feed"), image: UIImage(systemName: "house"), tag: 0),

                HistoryView()
                    .productionEnvironment()
                    .hostingController()
                    .tabItem(title: L10n.string("History"), image: UIImage(systemName: "clock"), tag: 1),

                WorkoutTab()
                    .productionEnvironment()
                    .hostingController()
                    .tabItem(title: L10n.string("Workout"), image: UIImage(systemName: "plus.square"), tag: 2),

                ExerciseMuscleGroupsView()
                    .productionEnvironment()
                    .hostingController()
                    .tabItem(title: L10n.string("Exercises"), image: UIImage(systemName: "tray.full"), tag: 3),

                SettingsView()
                    .productionEnvironment()
                    .hostingController()
                    .tabItem(title: L10n.string("Settings"), image: UIImage(systemName: "gear"), tag: 4),
            ], selection: sceneState.selectedTabNumber)

        }
    }
}

private extension View {
    func productionEnvironment() -> some View {
        LocalizedHostingRoot(content: self
            .environmentObject(SettingsStore.shared)
            .environmentObject(RestTimerStore.shared)
            .environmentObject(ExerciseStore.shared)
            .environment(\.managedObjectContext, WorkoutDataStorage.shared.persistentContainer.viewContext))
    }
}

// iOS 13 uses one hosting controller per tab. Each root observes locale changes
// itself, preserving its navigation, sheets and editor state.
private struct LocalizedHostingRoot<Content: View>: View {
    let content: Content
    @State private var languageCode = L10n.languageCode

    var body: some View {
        content
            .environment(\.locale, Locale(identifier: languageCode))
            .onAppear { languageCode = L10n.languageCode }
            .onReceive(NotificationCenter.default.publisher(for: .appLanguageChanged)) { _ in
                languageCode = L10n.languageCode
            }
    }
}

#if DEBUG
struct ContentView_Previews : PreviewProvider {
    static var previews: some View {
        ContentView()
            .mockEnvironment(weightUnit: .metric)
    }
}
#endif
