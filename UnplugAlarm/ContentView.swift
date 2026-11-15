//
//  ContentView.swift
//  Unplug Alarm
//
//  Created by okdemir on 4.12.2025.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var alarmManager: AlarmManager
    @ObservedObject private var settings = AlarmSettings.shared
    @State private var showHeadphoneAlert = false
    @State private var currentOutputName: String?

    var canActivate: Bool {
        alarmManager.alarmOnPowerOff || alarmManager.alarmOnLidClose
    }

    /// Asks before locking if the alarm would not play through the internal speakers.
    private func activateTapped() {
        if AudioOutputManager.isDefaultOutputInternalSpeaker() {
            alarmManager.activate()
        } else {
            currentOutputName = AudioOutputManager.defaultOutputName()
            showHeadphoneAlert = true
        }
    }

    var body: some View {
        VStack(spacing: 14) {
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
                    if settings.showLockScreenWarning {
                        Label("Lock screen warning", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if settings.effectiveContactNumber != nil {
                            Label("Contact number on lock screen", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    if settings.voiceWarning {
                        Label("Voice warning (\(settings.alarmLanguage.nativeName))", systemImage: "checkmark.circle.fill")
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
                // Inactive state — compact header so the settings fit on small screens
                HStack(spacing: 14) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 48))
                        .foregroundStyle(.gray)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Unplug Alarm")
                            .font(.title)
                            .fontWeight(.semibold)

                        Text("Protect your MacBook from theft")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)

                lockScreenSettings

                Button(action: activateTapped) {
                    Text("Activate")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .frame(width: 200, height: 50)
                        .background(canActivate ? Color.blue : Color.gray)
                        .cornerRadius(15)
                }
                .buttonStyle(.plain)
                .disabled(!canActivate)
                .alert("Headphones are connected", isPresented: $showHeadphoneAlert) {
                    Button("Cancel", role: .cancel) {}
                    Button("Proceed anyway") {
                        alarmManager.activate()
                    }
                } message: {
                    if let name = currentOutputName {
                        Text("The alarm may not be audible through the speakers.\nCurrent output: \(name)")
                    } else {
                        Text("The alarm may not be audible through the speakers.")
                    }
                }

                if !canActivate {
                    Text("Select at least one option to activate")
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }

                resetSection
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
            maxWidth: 520
        )
        // Window height always follows the content (never clipped)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Reset

    private var resetSection: some View {
        VStack(spacing: 4) {
            if alarmManager.hasLeftoverState {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Changes from a previous session are still applied")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Button {
                alarmManager.resetSystemState()
            } label: {
                Label("Reset system state", systemImage: "arrow.counterclockwise")
                    .font(.callout)
            }
            .buttonStyle(.link)
            .help("Restores the wallpaper, lid sleep and audio output if they were left changed (e.g. after a forced shutdown)")
        }
    }

    // MARK: - Lock screen & alarm settings

    private var lockScreenSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lock screen & alarm:")
                .font(.headline)
                .padding(.bottom, 2)

            Toggle(isOn: $settings.showLockScreenWarning) {
                Text("Show warning on lock screen")
                    .fontWeight(.medium)
            }
            .toggleStyle(.checkbox)

            HStack(spacing: 8) {
                Toggle(isOn: $settings.showContactNumber) {
                    Text("Show contact number")
                        .fontWeight(.medium)
                }
                .toggleStyle(.checkbox)

                TextField(text: $settings.contactNumber) {
                    Text(verbatim: "+90 5xx xxx xx xx")
                }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 170)
                .disabled(!settings.showContactNumber)
            }
            .padding(.leading, 20)
            .disabled(!settings.showLockScreenWarning)

            Toggle(isOn: $settings.voiceWarning) {
                Text("Voice warning when alarm triggers")
                    .fontWeight(.medium)
            }
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 2) {
                Picker(selection: $settings.alarmLanguage) {
                    ForEach(AlarmLanguage.allCases) { language in
                        Text(verbatim: language.nativeName).tag(language)
                    }
                } label: {
                    Text("Alarm language:")
                        .fontWeight(.medium)
                }
                .fixedSize()

                Text("Used for the lock screen text and the voice warning")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }
}

#Preview {
    ContentView(alarmManager: AlarmManager())
}
