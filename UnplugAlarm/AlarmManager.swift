//
//  AlarmManager.swift
//  Unplug Alarm
//
//  Created by okdemir on 4.12.2025.
//

import Foundation
import AVFoundation
import IOKit.ps
import IOKit.pwr_mgt
import Combine
import AppKit

class AlarmManager: ObservableObject {
    @Published var isActive = false
    @Published var isAlarmPlaying = false
    @Published var isLidSleepDisabled = false
    @Published var alarmOnPowerOff = false
    @Published var alarmOnLidClose = false

    private var audioPlayer: AVAudioPlayer?
    private var powerSourceTimer: Timer?
    private var lidStateTimer: Timer?
    private var wasPluggedIn: Bool = false
    private var wasLidOpen: Bool = true
    private var screenStateObservers: [NSObjectProtocol] = []
    private var sleepAssertionID: IOPMAssertionID = 0
    private var beepTimer: Timer?
    private var volumeEnforcerTimer: Timer?

    private var terminationObserver: NSObjectProtocol?

    init() {
        wasPluggedIn = isOnACPower()
        wasLidOpen = !isLidClosed()
        checkLidSleepStatus()

        // Register for app termination to restore lid sleep
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cleanup()
        }
    }

    deinit {
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        cleanup()
    }

    /// Cleanup method to restore system state when quitting
    private func cleanup() {
        deactivate()
    }

    /// Restore lid sleep without requiring admin privileges dialog (best effort)
    private func restoreLidSleep() {
        // Try to restore lid sleep - this will prompt for admin if needed
        // but during app termination it may silently fail, which is acceptable
        let script = """
        do shell script "pmset -a disablesleep 0" with administrator privileges
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if error == nil {
                isLidSleepDisabled = false
            }
        }
    }

    // MARK: - Activation / Deactivation

    func activate() {
        isActive = true

        // Record initial states
        wasPluggedIn = isOnACPower()
        wasLidOpen = !isLidClosed()

        // Lock the screen
        lockScreen()

        // Start monitoring based on user selection
        if alarmOnPowerOff {
            startPowerMonitoring()
        }

        if alarmOnLidClose {
            startLidMonitoring()
            // Ensure lid sleep is disabled for lid close detection
            if !isLidSleepDisabled {
                disableLidSleep()
            }
        }

        // Start monitoring screen state (for unlock detection)
        startScreenStateMonitoring()
    }

    func deactivate() {
        isActive = false
        stopAlarm()
        stopPowerMonitoring()
        stopLidMonitoring()
        stopScreenStateMonitoring()

        // Restore lid sleep if it was disabled
        if isLidSleepDisabled {
            restoreLidSleep()
            alarmOnLidClose = false
        }
    }

    // MARK: - Screen Lock

    private func lockScreen() {
        // Use the private login framework to lock screen immediately
        let libHandle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW)
        if libHandle != nil {
            defer { dlclose(libHandle) }
            if let sym = dlsym(libHandle, "SACLockScreenImmediate") {
                typealias LockFunc = @convention(c) () -> Void
                let lockFunction = unsafeBitCast(sym, to: LockFunc.self)
                lockFunction()
                return
            }
        }

        // Fallback: try ScreenSaverEngine (requires "Require password" in System Settings)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "ScreenSaverEngine"]
        try? task.run()
    }

    // MARK: - Sleep Prevention

    private func preventSleep() {
        guard sleepAssertionID == 0 else { return }

        let reason = "Unplug Alarm is playing alarm sound" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &sleepAssertionID
        )

        if result != kIOReturnSuccess {
            print("Failed to create sleep assertion: \(result)")
            // Try a stronger assertion that prevents lid-close sleep
            IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &sleepAssertionID
            )
        }
    }

    private func allowSleep() {
        if sleepAssertionID != 0 {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = 0
        }
    }

    // MARK: - Lid Sleep Control

    func toggleLidSleep() {
        if isLidSleepDisabled {
            enableLidSleep()
        } else {
            disableLidSleep()
        }
    }

    private func disableLidSleep() {
        let script = """
        do shell script "pmset -a disablesleep 1" with administrator privileges
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if error == nil {
                DispatchQueue.main.async {
                    self.isLidSleepDisabled = true
                }
            } else {
                print("Failed to disable lid sleep: \(String(describing: error))")
                // Uncheck the checkbox so user can try again
                DispatchQueue.main.async {
                    self.alarmOnLidClose = false
                }
            }
        }
    }

    private func enableLidSleep() {
        let script = """
        do shell script "pmset -a disablesleep 0" with administrator privileges
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if error == nil {
                DispatchQueue.main.async {
                    self.isLidSleepDisabled = false
                }
            } else {
                print("Failed to enable lid sleep: \(String(describing: error))")
            }
        }
    }

    private func checkLidSleepStatus() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Check if disablesleep is set to 1
                isLidSleepDisabled = output.contains("disablesleep") && output.contains("1")
            }
        } catch {
            print("Failed to check lid sleep status: \(error)")
        }
    }

    // MARK: - Lid State Detection

    private func isLidClosed() -> Bool {
        // Check the clamshell state using IOKit
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        if let clamshellState = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) {
            return clamshellState.takeRetainedValue() as? Bool ?? false
        }

        return false
    }

    // MARK: - Lid Monitoring

    private func startLidMonitoring() {
        // Poll lid state every 0.5 seconds
        lidStateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkLidState()
        }
    }

    private func stopLidMonitoring() {
        lidStateTimer?.invalidate()
        lidStateTimer = nil
    }

    private func checkLidState() {
        guard isActive else { return }

        let isCurrentlyLidClosed = isLidClosed()

        // Trigger alarm if lid just closed (was open, now closed)
        if wasLidOpen && isCurrentlyLidClosed {
            triggerAlarm()
        }

        wasLidOpen = !isCurrentlyLidClosed
    }

    // MARK: - Power Monitoring

    private func isOnACPower() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array

        for source in sources {
            let description = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as! [String: Any]

            if let powerSource = description[kIOPSPowerSourceStateKey] as? String {
                return powerSource == kIOPSACPowerValue
            }
        }

        // If no battery (desktop Mac), assume always plugged in
        return true
    }

    private func startPowerMonitoring() {
        // Check power state every 0.5 seconds
        powerSourceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkPowerState()
        }
    }

    private func stopPowerMonitoring() {
        powerSourceTimer?.invalidate()
        powerSourceTimer = nil
    }

    private func checkPowerState() {
        guard isActive else { return }

        let isCurrentlyPluggedIn = isOnACPower()

        // Trigger alarm if unplugged (was plugged, now not)
        if wasPluggedIn && !isCurrentlyPluggedIn {
            triggerAlarm()
        }

        wasPluggedIn = isCurrentlyPluggedIn
    }

    // MARK: - Screen State Monitoring

    private func startScreenStateMonitoring() {
        let workspace = NSWorkspace.shared
        let notificationCenter = workspace.notificationCenter
        let distributedCenter = DistributedNotificationCenter.default()

        // Monitor for screen sleep (lid close)
        let sleepObserver = notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onScreenSleep()
        }
        screenStateObservers.append(sleepObserver)

        // Monitor for system sleep attempt - prevent it if alarm is active
        let willSleepObserver = notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onSystemWillSleep()
        }
        screenStateObservers.append(willSleepObserver)

        // Monitor for screen wake (includes unlock)
        let wakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onScreenWake()
        }
        screenStateObservers.append(wakeObserver)

        // Monitor for screen unlock specifically
        let unlockObserver = distributedCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onScreenUnlocked()
        }
        screenStateObservers.append(unlockObserver)

        // Also monitor for session becoming active (user logged back in)
        let sessionObserver = notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onScreenUnlocked()
        }
        screenStateObservers.append(sessionObserver)
    }

    private func stopScreenStateMonitoring() {
        for observer in screenStateObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        screenStateObservers.removeAll()
    }

    private func onScreenSleep() {
        // Lid monitoring is handled by polling timer
        // This is kept for potential future use
    }

    private func onSystemWillSleep() {
        guard isActive else { return }
        // Prevent system sleep if alarm is active
        preventSleep()
    }

    private func onScreenWake() {
        // Screen woke up, but we wait for actual unlock
    }

    private func onScreenUnlocked() {
        // User unlocked the screen - stop the alarm
        stopAlarm()
    }

    // MARK: - Alarm

    private func triggerAlarm() {
        guard !isAlarmPlaying else { return }

        // Prevent system from sleeping so alarm can play
        preventSleep()

        isAlarmPlaying = true

        // Force volume to max and keep it there
        startVolumeEnforcer()

        playAlarmSound()
    }

    func stopAlarm() {
        isAlarmPlaying = false
        audioPlayer?.stop()
        audioPlayer = nil
        beepTimer?.invalidate()
        beepTimer = nil
        volumeEnforcerTimer?.invalidate()
        volumeEnforcerTimer = nil
        allowSleep()
    }

    // MARK: - Volume Enforcement

    private func startVolumeEnforcer() {
        // Set volume to max immediately
        setMaxVolume()

        // Keep enforcing max volume every 0.2 seconds
        volumeEnforcerTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.setMaxVolume()
        }
    }

    private func setMaxVolume() {
        // Use AppleScript to set volume to maximum and unmute
        let script = """
        set volume output volume 100
        set volume without output muted
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    private func playAlarmSound() {
        // Try to load system alert sound or create a loud beep
        if let soundURL = findAlarmSound() {
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: soundURL)
                audioPlayer?.numberOfLoops = -1 // Loop indefinitely
                audioPlayer?.volume = 1.0
                audioPlayer?.play()
            } catch {
                print("Failed to play sound: \(error)")
                playSystemBeep()
            }
        } else {
            playSystemBeep()
        }
    }

    private func findAlarmSound() -> URL? {
        // First try bundled alarm sound (guaranteed to exist)
        if let bundledURL = Bundle.main.url(forResource: "Alarm", withExtension: "m4r") {
            return bundledURL
        }

        // Fallback to system ringtones if bundled file missing
        let systemPaths = [
            "/System/Library/PrivateFrameworks/ToneLibrary.framework/Resources/Ringtones/Alarm.m4r",
            "/System/Library/PrivateFrameworks/ToneLibrary.framework/Resources/Ringtones/Radar.m4r",
            "/System/Library/Sounds/Funk.aiff"
        ]

        for path in systemPaths {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }

    private func playSystemBeep() {
        // Fallback: play repeated system beeps
        beepTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            guard let self = self, self.isAlarmPlaying else {
                timer.invalidate()
                return
            }
            NSSound.beep()
        }
    }
}
