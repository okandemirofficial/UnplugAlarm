//
//  ContentView.swift
//  Unplug Alarm
//
//  Created by okdemir on 4.12.2025.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var alarmManager = AlarmManager()

    var canActivate: Bool {
        alarmManager.alarmOnPowerOff || alarmManager.alarmOnLidClose
    }

    var body: some View {
        VStack(spacing: 20) {
            if alarmManager.isActive {
                // Active state
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.green)

                Text("Protection Active")
                    .font(.title)
                    .fontWeight(.semibold)

                VStack(alignment: .leading, spacing: 4) {
                    if alarmManager.alarmOnPowerOff {
                        Label("Power disconnect detection", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if alarmManager.alarmOnLidClose {
                        Label("Lid close detection", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .font(.subheadline)

                Button(action: {
                    alarmManager.deactivate()
                }) {
                    Text("Deactivate")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .frame(width: 200, height: 60)
                        .background(Color.red)
                        .cornerRadius(15)
                }
                .buttonStyle(.plain)
                .padding(.top, 10)

            } else {
                // Inactive state
                Image(systemName: "lock.shield")
                    .font(.system(size: 80))
                    .foregroundStyle(.gray)

                Text("Unplug Alarm")
                    .font(.title)
                    .fontWeight(.semibold)

                Text("Protect your MacBook from theft")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Options section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Alarm triggers:")
                        .font(.headline)
                        .padding(.bottom, 4)

                    // Power off checkbox
                    Toggle(isOn: $alarmManager.alarmOnPowerOff) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable alarm on power off")
                                .fontWeight(.medium)
                        }
                    }
                    .toggleStyle(.checkbox)

                    // Lid close checkbox
                    Toggle(isOn: $alarmManager.alarmOnLidClose) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable alarm on lid close")
                                .fontWeight(.medium)
                            Text("Requires admin permission")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .onChange(of: alarmManager.alarmOnLidClose) { _, newValue in
                        if newValue && !alarmManager.isLidSleepDisabled {
                            alarmManager.toggleLidSleep()
                        } else if !newValue && alarmManager.isLidSleepDisabled {
                            alarmManager.toggleLidSleep()
                        }
                    }

                    if alarmManager.alarmOnLidClose {
                        HStack(spacing: 4) {
                            Image(systemName: alarmManager.isLidSleepDisabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(alarmManager.isLidSleepDisabled ? .green : .red)
                            Text(alarmManager.isLidSleepDisabled ? "Lid sleep disabled" : "Lid sleep not disabled")
                                .font(.caption)
                                .foregroundStyle(alarmManager.isLidSleepDisabled ? .green : .red)
                        }
                        .padding(.leading, 20)
                    }

                    // Warning when lid close is not enabled
                    if alarmManager.alarmOnPowerOff && !alarmManager.alarmOnLidClose {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Thief can close the alarm by closing lid")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)

                Button(action: {
                    alarmManager.activate()
                }) {
                    Text("Activate")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .frame(width: 200, height: 60)
                        .background(canActivate ? Color.blue : Color.gray)
                        .cornerRadius(15)
                }
                .buttonStyle(.plain)
                .disabled(!canActivate)

                if !canActivate {
                    Text("Select at least one option to activate")
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
            }

            if alarmManager.isAlarmPlaying {
                Text("ALARM TRIGGERED")
                    .font(.headline)
                    .foregroundStyle(.red)
                    .padding()
            }

            VStack(spacing: 3) {
                Link(destination: URL(string: "https://buymeacoffee.com/okandemir")!) {
                    Image("bmc-button")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 40)
                        .accessibilityLabel("Buy me a coffee")
                }
                .buttonStyle(.plain)

                Text("Donate the developer if you liked this app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(
            minWidth: 420,
            idealWidth: 480,
            maxWidth: 520,
            minHeight: 540,
            idealHeight: 600
        )
    }
}

#Preview {
    ContentView()
}
