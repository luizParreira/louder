import AppKit
import LouderEngine
import ServiceManagement
import SwiftUI

struct PanelView: View {
    let controller: LouderController
    @State private var activity = BoostActivity()

    private var engine: BoostEngine { controller.engine }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            notice
            Divider()
            boostSection
            Divider()
            settingsSection
            Divider()
            safetyNote
            footer
        }
        .padding(14)
        .frame(width: 300)
        .tint(.louderBlue)
        .onAppear { controller.refreshLoginItem() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            controller.refreshLoginItem()
        }
        .onChange(of: engine.meters) {
            activity.update(target: engine.effectiveBoostDB, meters: engine.meters)
        }
        .onChange(of: engine.effectiveBoostDB) { activity.targetChanged() }
        .onChange(of: engine.state) { activity.reset() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Louder").font(.headline)
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Louder", isOn: Binding(get: { controller.isOn }, set: { controller.setEnabled($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var summary: String {
        switch engine.state {
        case .off: "Off"
        case .starting: "Starting…"
        case .running: "On"
        case .needsPermission: "Needs permission"
        case .failed: "Turned itself off"
        }
    }

    @ViewBuilder private var notice: some View {
        switch engine.state {
        case .needsPermission:
            Notice(
                symbol: "lock.fill",
                title: "Louder needs permission",
                message: "To play your Mac's sound louder, Louder first has to hear it. Allow Louder in System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
            ) {
                Button("Open System Settings") { NSWorkspace.shared.open(AudioCapturePermission.settingsURL) }
                    .buttonStyle(.borderedProminent)
                Button("Try Again") { controller.setEnabled(true) }
            }
        case .failed(let message):
            Notice(symbol: "exclamationmark.triangle.fill", title: "Louder stopped", message: message) {
                Button("Turn On Again") { controller.setEnabled(true) }
                    .buttonStyle(.borderedProminent)
            }
        case .off, .starting, .running:
            EmptyView()
        }
    }

    // MARK: Boost

    private var boostSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            deviceRow
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Boost")
                    Spacer()
                    Text("+\(Int(engine.effectiveBoostDB)) dB")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(get: { engine.effectiveBoostDB }, set: { controller.setBoost($0) }),
                    in: 0...engine.maxBoostDB,
                    step: 1
                ) {
                    Text("Boost")
                }
                .labelsHidden()
                .accessibilityValue("+\(Int(engine.effectiveBoostDB)) dB")
            }
            liveStatus
        }
    }

    private var deviceRow: some View {
        HStack(spacing: 8) {
            Image(systemName: engine.device?.kind == .speakers ? "hifispeaker.fill" : "headphones")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(engine.device?.name ?? "No output device")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if let kind = engine.device?.kind {
                KindBadge(kind: kind)
            }
        }
    }

    @ViewBuilder private var liveStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            let line = activityLine
            Label(line.text, systemImage: line.symbol)
                .foregroundStyle(.secondary)
            if engine.isRunning {
                let catching = engine.meters.limiterReductionDB > 0.5
                Label(
                    catching ? "Limiter is catching peaks" : "Limiter is standing by",
                    systemImage: catching ? "shield.lefthalf.filled" : "shield"
                )
                .foregroundStyle(catching ? AnyShapeStyle(Color.louderCoral) : AnyShapeStyle(.secondary))
            }
        }
        .font(.callout)
    }

    private var activityLine: (symbol: String, text: String) {
        switch engine.state {
        case .off, .needsPermission, .failed:
            return ("speaker.wave.1", "Your Mac plays at its normal volume")
        case .starting:
            return ("hourglass", "Starting…")
        case .running:
            break
        }
        guard engine.effectiveBoostDB > 0 else {
            return ("speaker.wave.1", "Boost is at 0 dB, so nothing changes")
        }
        let applied = String(format: "+%.1f dB", max(0, engine.meters.appliedBoostDB))
        switch activity.phase {
        case .waiting:
            return ("ellipsis", "Ready. Waiting for something to play")
        case .easingIn:
            return ("arrow.up.right", "Easing in, \(applied)")
        case .boosting:
            return ("speaker.wave.3.fill", "Boosting \(applied)")
        case .holdingBack:
            return ("hand.raised.fill", "Holding back — this audio is already loud")
        }
    }

    // MARK: Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Output")
                Spacer()
                Picker("Output", selection: Binding(get: { engine.preferredDeviceUID }, set: { controller.selectDevice(uid: $0) })) {
                    Text("Follow system output").tag(String?.none)
                    Divider()
                    ForEach(controller.devices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                    if let missing = missingSavedDeviceUID {
                        Text("Saved device (not connected)").tag(String?.some(missing))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
            }
            HStack {
                Text("Launch at login")
                Spacer()
                Toggle("Launch at login", isOn: Binding(get: { controller.launchesAtLogin }, set: { controller.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            if controller.loginItemStatus == .requiresApproval {
                HStack {
                    Text("Allow Louder in Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                        .controlSize(.small)
                }
            }
            if let error = controller.loginItemError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var missingSavedDeviceUID: String? {
        guard let uid = engine.preferredDeviceUID, !controller.devices.contains(where: { $0.uid == uid }) else { return nil }
        return uid
    }

    // MARK: Footer

    private var safetyNote: some View {
        Label {
            Text("Louder eases in slowly, caps the boost (+6 dB on headphones, +12 dB on speakers) and limits peaks. If it ever feels too loud, it is. Turn it down.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "ear")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack {
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Text("Version \(version)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Quit Louder") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

private struct KindBadge: View {
    let kind: OutputKind

    var body: some View {
        Text(kind == .headphones ? "Headphones" : "Speakers")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.15), in: Capsule())
    }
}

private struct Notice<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack { actions }
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
