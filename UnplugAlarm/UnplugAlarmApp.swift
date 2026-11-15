//
//  UnplugAlarmApp.swift
//  Unplug Alarm
//
//  Created by okdemir on 4.12.2025.
//

import SwiftUI

@main
struct UnplugAlarmApp: App {
    @StateObject private var alarmManager = AlarmManager()

    var body: some Scene {
        WindowGroup {
            ContentView(alarmManager: alarmManager)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 480, height: 620)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Reset System State") {
                    alarmManager.resetSystemState()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
