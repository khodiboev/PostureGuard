import SwiftUI
import ServiceManagement
import Combine

@main
struct PostureGuardApp: App {
    @StateObject private var monitor = PostureMonitor()

    var body: some Scene {
        // No Dock icon: the app lives in the menu bar
        MenuBarExtra {
            MenuContent(monitor: monitor)
        } label: {
            Image(systemName: monitor.state == .slouching ? "exclamationmark.triangle.fill" : "figure.stand")
        }
    }
}

struct MenuContent: View {
    @ObservedObject var monitor: PostureMonitor
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Text(monitor.statusText)

        Divider()

        Toggle("Enabled", isOn: $monitor.isEnabled)

        Button("Calibrate (sit up straight)…") { monitor.calibrate() }
            .disabled(monitor.state == .calibrating)

        Picker("Sensitivity", selection: $monitor.sensitivity) {
            ForEach(Sensitivity.allCases) { level in
                Text(level.title).tag(level)
            }
        }

        if monitor.isSnoozed {
            Button("Resume reminders") { monitor.resume() }
        } else {
            Button("Snooze for 30 minutes") { monitor.snooze(minutes: 30) }
        }

        Button("Preview the warning") { monitor.previewWarning() }

        Divider()

        Toggle("Launch at login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }

        Divider()

        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
