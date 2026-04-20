import AppKit
import Foundation

struct DashboardConfig {
    let workspace: String
    let globalRoot: String?
    let geminiSettings: String?
    let snapshotScript: String
}

struct RecentTask: Codable {
    let taskId: String
    let agent: String
    let time: String
    let boot: String
    let sync: String
    let summary: String

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case agent
        case time
        case boot
        case sync
        case summary
    }
}

struct DashboardSnapshot: Codable {
    let projectName: String
    let workspace: String
    let runtime: String
    let taskId: String
    let bootStatus: String
    let syncStatus: String
    let lifecyclePhase: String
    let sixStageCurrent: String
    let sixStageCompleted: [String]
    let sixStageNote: String
    let phaseSource: String
    let lastHandoff: String
    let activeMcpCount: Int
    let enabledRegistryCount: Int
    let disabledRegistryCount: Int
    let recentTasks: [RecentTask]
    let alerts: [String]

    enum CodingKeys: String, CodingKey {
        case projectName = "project_name"
        case workspace
        case runtime
        case taskId = "task_id"
        case bootStatus = "boot_status"
        case syncStatus = "sync_status"
        case lifecyclePhase = "lifecycle_phase"
        case sixStageCurrent = "six_stage_current"
        case sixStageCompleted = "six_stage_completed"
        case sixStageNote = "six_stage_note"
        case phaseSource = "phase_source"
        case lastHandoff = "last_handoff"
        case activeMcpCount = "active_mcp_count"
        case enabledRegistryCount = "enabled_registry_count"
        case disabledRegistryCount = "disabled_registry_count"
        case recentTasks = "recent_tasks"
        case alerts
    }
}

let phaseOrder = ["route", "plan", "review", "dispatch", "execute", "report"]
let phaseLabels = [
    "route": "路由",
    "plan": "规划",
    "review": "自审",
    "dispatch": "分发",
    "execute": "执行",
    "report": "回奏",
]

final class FloatingDashboardController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let config: DashboardConfig
    private var panel: NSPanel!
    private var refreshTimer: Timer?

    private let titleLabel = NSTextField(labelWithString: "Shared Fabric Monitor")
    private let statusLabel = NSTextField(labelWithString: "")
    private let stageBarLabel = NSTextField(labelWithString: "")
    private let stageDetailLabel = NSTextField(labelWithString: "")
    private let taskLabel = NSTextField(labelWithString: "")
    private let handoffLabel = NSTextField(wrappingLabelWithString: "")
    private let recentTasksLabel = NSTextField(wrappingLabelWithString: "")
    private let alertsLabel = NSTextField(wrappingLabelWithString: "")

    init(config: DashboardConfig) {
        self.config = config
        super.init()
    }

    func start() {
        createPanel()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    @objc private func refreshTapped() {
        refresh()
    }

    @objc private func openLogsTapped() {
        let target = URL(fileURLWithPath: (config.globalRoot ?? "/Users/david_chen/Antigravity_Skills/global-agent-fabric") + "/sync")
        NSWorkspace.shared.open(target)
    }

    private func createPanel() {
        panel = NSPanel(
            contentRect: NSRect(x: 200, y: 200, width: 360, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Shared Fabric Monitor"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let contentView = NSView()
        panel.contentView = contentView

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        stageBarLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        stageDetailLabel.font = .systemFont(ofSize: 11)
        taskLabel.font = .systemFont(ofSize: 11, weight: .medium)
        handoffLabel.font = .systemFont(ofSize: 11)
        recentTasksLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        alertsLabel.font = .systemFont(ofSize: 10)
        alertsLabel.textColor = .systemOrange

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshTapped))
        let openLogsButton = NSButton(title: "Open Logs", target: self, action: #selector(openLogsTapped))
        refreshButton.bezelStyle = .rounded
        openLogsButton.bezelStyle = .rounded
        buttonRow.addArrangedSubview(refreshButton)
        buttonRow.addArrangedSubview(openLogsButton)

        let stack = NSStackView(views: [titleLabel, statusLabel, stageBarLabel, stageDetailLabel, taskLabel, handoffLabel, recentTasksLabel, alertsLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),
        ])

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refresh() {
        do {
            let snapshot = try loadSnapshot()
            apply(snapshot: snapshot)
        } catch {
            alertsLabel.stringValue = "refresh error: \(error.localizedDescription)"
        }
    }

    private func loadSnapshot() throws -> DashboardSnapshot {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        var arguments = ["python3", config.snapshotScript, "--workspace", config.workspace]
        if let globalRoot = config.globalRoot {
            arguments += ["--global-root", globalRoot]
        }
        if let geminiSettings = config.geminiSettings {
            arguments += ["--gemini-settings", geminiSettings]
        }
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8) ?? "snapshot export failed"
            throw NSError(domain: "FloatingDashboard", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONDecoder().decode(DashboardSnapshot.self, from: data)
    }

    private func apply(snapshot: DashboardSnapshot) {
        titleLabel.stringValue = "\(snapshot.projectName)  ·  \(snapshot.runtime)"
        statusLabel.stringValue = "BOOT \(snapshot.bootStatus)   SYNC \(snapshot.syncStatus)   lifecycle \(snapshot.lifecyclePhase)"
        stageBarLabel.stringValue = renderStageBar(current: snapshot.sixStageCurrent, completed: snapshot.sixStageCompleted)
        let currentLabel = phaseLabels[snapshot.sixStageCurrent] ?? "-"
        stageDetailLabel.stringValue = "当前阶段 \(currentLabel)   source \(snapshot.phaseSource)   MCP \(snapshot.activeMcpCount)"
        taskLabel.stringValue = "task \(snapshot.taskId)   registry \(snapshot.enabledRegistryCount) on / \(snapshot.disabledRegistryCount) off"
        handoffLabel.stringValue = "handoff  \(snapshot.lastHandoff)"

        let recent = snapshot.recentTasks.prefix(3).map {
            "\($0.time)  \($0.agent)  B:\($0.boot) S:\($0.sync)  \($0.taskId)"
        }
        recentTasksLabel.stringValue = recent.isEmpty ? "recent tasks  (none)" : "recent tasks\n" + recent.joined(separator: "\n")

        var alertLines = snapshot.alerts
        if !snapshot.sixStageNote.isEmpty {
            alertLines.insert("phase note: \(snapshot.sixStageNote)", at: 0)
        }
        alertsLabel.stringValue = alertLines.joined(separator: "\n")
    }

    private func renderStageBar(current: String, completed: [String]) -> String {
        let completedSet = Set(completed)
        return phaseOrder.map { key in
            let label = phaseLabels[key] ?? key
            if key == current {
                return "▶\(label)"
            }
            if completedSet.contains(key) {
                return "●\(label)"
            }
            return "·\(label)"
        }.joined(separator: " ")
    }
}

func parseConfig() -> DashboardConfig {
    let environment = ProcessInfo.processInfo.environment
    let fileManager = FileManager.default

    func defaultWorkspace() -> String {
        if let override = environment["MCP_HUB_DASHBOARD_WORKSPACE"], !override.isEmpty {
            return override
        }

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [
            executableURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent(),
            URL(fileURLWithPath: fileManager.currentDirectoryPath).resolvingSymlinksInPath(),
        ]

        for candidate in candidates {
            let snapshot = candidate.appendingPathComponent("tools/compact_dashboard/export_snapshot.py")
            if fileManager.fileExists(atPath: snapshot.path) {
                return candidate.path
            }
        }
        return fileManager.currentDirectoryPath
    }

    func defaultSnapshotScript(workspace: String) -> String {
        if let override = environment["MCP_HUB_DASHBOARD_SNAPSHOT_SCRIPT"], !override.isEmpty {
            return override
        }
        return URL(fileURLWithPath: workspace)
            .appendingPathComponent("tools/compact_dashboard/export_snapshot.py")
            .path
    }

    var workspace = defaultWorkspace()
    var globalRoot: String?
    var geminiSettings: String?
    var snapshotScript = defaultSnapshotScript(workspace: workspace)

    var index = 1
    let args = CommandLine.arguments
    while index < args.count {
        let arg = args[index]
        if arg == "--workspace", index + 1 < args.count {
            workspace = args[index + 1]
            snapshotScript = defaultSnapshotScript(workspace: workspace)
            index += 2
            continue
        }
        if arg == "--global-root", index + 1 < args.count {
            globalRoot = args[index + 1]
            index += 2
            continue
        }
        if arg == "--gemini-settings", index + 1 < args.count {
            geminiSettings = args[index + 1]
            index += 2
            continue
        }
        if arg == "--snapshot-script", index + 1 < args.count {
            snapshotScript = args[index + 1]
            index += 2
            continue
        }
        index += 1
    }

    return DashboardConfig(
        workspace: workspace,
        globalRoot: globalRoot,
        geminiSettings: geminiSettings,
        snapshotScript: snapshotScript
    )
}

let app = NSApplication.shared
let delegate = FloatingDashboardController(config: parseConfig())
app.setActivationPolicy(.regular)
app.delegate = delegate
app.activate(ignoringOtherApps: true)
delegate.start()
app.run()
