import AppKit
import Combine
import Foundation
import SwiftUI

struct DashboardConfig {
    let initialWorkspace: String?
    let initialGlobalRoot: String?
    let geminiSettings: String?
    let snapshotScript: String

    var repositoryRoot: String? {
        let snapshotURL = URL(fileURLWithPath: snapshotScript)
        let compactDashboardDir = snapshotURL.deletingLastPathComponent()
        let toolsDir = compactDashboardDir.deletingLastPathComponent()
        let repoRoot = toolsDir.deletingLastPathComponent()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: repoRoot.appendingPathComponent("install/bootstrap_shared_fabric.py").path) else {
            return nil
        }
        return repoRoot.path
    }
}

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case auto
    case pinned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:
            return "Auto"
        case .pinned:
            return "Pinned"
        }
    }

    var subtitle: String {
        switch self {
        case .auto:
            return "Follow latest active workspace"
        case .pinned:
            return "Stay on a fixed workspace"
        }
    }
}

struct WorkspaceOption: Codable, Identifiable {
    let path: String
    let label: String
    let source: String
    let lastSeen: String

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path
        case label
        case source
        case lastSeen = "last_seen"
    }
}

struct RecentTask: Codable, Identifiable {
    let taskId: String
    let agent: String
    let time: String
    let boot: String
    let sync: String
    let summary: String

    var id: String { "\(taskId)-\(time)" }

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case agent
        case time
        case boot
        case sync
        case summary
    }
}

struct SyncDelta: Codable {
    let writesCountByTarget: [String: Int]
    let learnedItems: [String]
    let skippedItems: [String]
    let sourceSummary: String
    let records: [SyncRecordEntry]

    enum CodingKeys: String, CodingKey {
        case writesCountByTarget = "writes_count_by_target"
        case learnedItems = "learned_items"
        case skippedItems = "skipped_items"
        case sourceSummary = "source_summary"
        case records
    }
}

struct SyncRecordEntry: Codable, Identifiable {
    let target: String
    let title: String
    let timestamp: String
    let summary: String
    let details: String
    let artifacts: [String]
    let sourcePath: String
    let route: String
    let mechanism: String

    var id: String { "\(target)-\(title)-\(timestamp)-\(summary)" }

    enum CodingKeys: String, CodingKey {
        case target
        case title
        case timestamp
        case summary
        case details
        case artifacts
        case sourcePath = "source_path"
        case route
        case mechanism
    }
}

struct ProjectMemoryRecord: Codable, Identifiable {
    let lane: String
    let title: String
    let timestamp: String
    let summary: String
    let details: String
    let artifacts: [String]
    let workspace: String
    let taskId: String
    let agent: String
    let type: String
    let sourcePath: String
    let route: String
    let mechanism: String
    let bridgeSessionId: String
    let bridgeMode: String
    let originRuntime: String
    let targetRuntime: String
    let isBridged: Bool

    var id: String { "\(lane)-\(taskId)-\(timestamp)-\(summary)" }

    enum CodingKeys: String, CodingKey {
        case lane
        case title
        case timestamp
        case summary
        case details
        case artifacts
        case workspace
        case taskId = "task_id"
        case agent
        case type
        case sourcePath = "source_path"
        case route
        case mechanism
        case bridgeSessionId = "bridge_session_id"
        case bridgeMode = "bridge_mode"
        case originRuntime = "origin_runtime"
        case targetRuntime = "target_runtime"
        case isBridged = "is_bridged"
    }
}

struct TaskHealth: Codable {
    let isBooted: Bool
    let hasExactPhase: Bool
    let hasPostflightSync: Bool
    let hasLearningReceipt: Bool

    enum CodingKeys: String, CodingKey {
        case isBooted = "is_booted"
        case hasExactPhase = "has_exact_phase"
        case hasPostflightSync = "has_postflight_sync"
        case hasLearningReceipt = "has_learning_receipt"
    }
}

struct DashboardSnapshot: Codable {
    let workspace: String
    let workspaceMode: String
    let projectName: String
    let runtime: String
    let bridgeSessionId: String
    let bridgeMode: String
    let originRuntime: String
    let targetRuntime: String
    let isBridged: Bool
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
    let availableWorkspaces: [WorkspaceOption]
    let alerts: [String]
    let lastSyncDelta: SyncDelta
    let projectMemoryCounts: [String: Int]
    let projectMemoryRecords: [ProjectMemoryRecord]
    let projectMemoryLastUpdated: String
    let syncAuditSource: String
    let currentTaskHealth: TaskHealth
    let attentionState: String

    enum CodingKeys: String, CodingKey {
        case workspace
        case workspaceMode = "workspace_mode"
        case projectName = "project_name"
        case runtime
        case bridgeSessionId = "bridge_session_id"
        case bridgeMode = "bridge_mode"
        case originRuntime = "origin_runtime"
        case targetRuntime = "target_runtime"
        case isBridged = "is_bridged"
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
        case availableWorkspaces = "available_workspaces"
        case alerts
        case lastSyncDelta = "last_sync_delta"
        case projectMemoryCounts = "project_memory_counts"
        case projectMemoryRecords = "project_memory_records"
        case projectMemoryLastUpdated = "project_memory_last_updated"
        case syncAuditSource = "sync_audit_source"
        case currentTaskHealth = "current_task_health"
        case attentionState = "attention_state"
    }
}

let defaultGlobalRoot = "/Users/david_chen/Antigravity_Skills/global-agent-fabric"
let phaseOrder = ["route", "plan", "review", "dispatch", "execute", "report"]
let phaseLabels = [
    "route": "Route",
    "plan": "Plan",
    "review": "Review",
    "dispatch": "Dispatch",
    "execute": "Execute",
    "report": "Report",
]

enum SetupEnvironmentStatus {
    case ready
    case incomplete(missing: [String])
}
let writeTargetLabels = [
    "receipts": "Receipt",
    "handoffs": "Handoff",
    "decision_log": "Decision",
    "open_loops": "Loop",
    "mempalace_records": "Mem",
    "promoted_learnings": "Learn",
]

final class DashboardPreferences: ObservableObject {
    private enum Keys {
        static let workspaceMode = "shared_fabric_dashboard.workspace_mode"
        static let pinnedWorkspace = "shared_fabric_dashboard.pinned_workspace"
        static let refreshInterval = "shared_fabric_dashboard.refresh_interval"
        static let globalRootOverride = "shared_fabric_dashboard.global_root_override"
    }

    private let defaults: UserDefaults
    private var isLoading = true

    @Published var workspaceMode: WorkspaceMode {
        didSet { persistIfNeeded() }
    }

    @Published var pinnedWorkspace: String {
        didSet { persistIfNeeded() }
    }

    @Published var refreshInterval: Double {
        didSet {
            let clamped = max(1.0, min(refreshInterval, 60.0))
            if refreshInterval != clamped {
                refreshInterval = clamped
                return
            }
            persistIfNeeded()
        }
    }

    @Published var globalRootOverride: String {
        didSet { persistIfNeeded() }
    }

    init(config: DashboardConfig, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.workspaceMode = .auto
        self.pinnedWorkspace = ""
        self.refreshInterval = 2.0
        self.globalRootOverride = ""

        if let storedMode = defaults.string(forKey: Keys.workspaceMode), let mode = WorkspaceMode(rawValue: storedMode) {
            workspaceMode = mode
        }
        pinnedWorkspace = defaults.string(forKey: Keys.pinnedWorkspace) ?? ""
        let storedRefresh = defaults.double(forKey: Keys.refreshInterval)
        refreshInterval = storedRefresh > 0 ? storedRefresh : 2.0
        globalRootOverride = defaults.string(forKey: Keys.globalRootOverride) ?? ""

        if let initialWorkspace = config.initialWorkspace, !initialWorkspace.isEmpty {
            workspaceMode = .pinned
            pinnedWorkspace = initialWorkspace
        }
        if let initialGlobalRoot = config.initialGlobalRoot, !initialGlobalRoot.isEmpty, globalRootOverride.isEmpty {
            globalRootOverride = initialGlobalRoot
        }

        isLoading = false
        persistIfNeeded()
    }

    init(workspaceMode: WorkspaceMode, pinnedWorkspace: String, refreshInterval: Double, globalRootOverride: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.workspaceMode = workspaceMode
        self.pinnedWorkspace = pinnedWorkspace
        self.refreshInterval = max(1.0, min(refreshInterval, 60.0))
        self.globalRootOverride = globalRootOverride
        isLoading = false
    }

    func cloned() -> DashboardPreferences {
        DashboardPreferences(
            workspaceMode: workspaceMode,
            pinnedWorkspace: pinnedWorkspace,
            refreshInterval: refreshInterval,
            globalRootOverride: globalRootOverride,
            defaults: defaults
        )
    }

    func setAuto() {
        workspaceMode = .auto
    }

    func setPinned(_ path: String) {
        workspaceMode = .pinned
        pinnedWorkspace = path
    }

    func resetToDefaults(config: DashboardConfig) {
        workspaceMode = config.initialWorkspace == nil ? .auto : .pinned
        pinnedWorkspace = config.initialWorkspace ?? ""
        refreshInterval = 2.0
        globalRootOverride = config.initialGlobalRoot ?? ""
    }

    var effectiveWorkspaceArgument: String? {
        guard workspaceMode == .pinned else { return nil }
        let trimmed = pinnedWorkspace.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var effectiveGlobalRoot: String {
        let trimmed = globalRootOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultGlobalRoot : trimmed
    }

    private func persistIfNeeded() {
        guard !isLoading else { return }
        defaults.set(workspaceMode.rawValue, forKey: Keys.workspaceMode)
        defaults.set(pinnedWorkspace, forKey: Keys.pinnedWorkspace)
        defaults.set(refreshInterval, forKey: Keys.refreshInterval)
        defaults.set(globalRootOverride, forKey: Keys.globalRootOverride)
    }
}

final class DashboardViewModel: ObservableObject {
    @Published var snapshot: DashboardSnapshot?
    @Published var errorMessage = ""
    @Published var refreshToken = UUID()

    func apply(snapshot: DashboardSnapshot) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
            self.snapshot = snapshot
            errorMessage = ""
            refreshToken = UUID()
        }
    }

    func apply(error: Error) {
        withAnimation(.easeInOut(duration: 0.2)) {
            errorMessage = error.localizedDescription
            refreshToken = UUID()
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.material = material
        view.blendingMode = blendingMode
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct SharedFabricMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.11, green: 0.46, blue: 0.90),
                            Color(red: 0.10, green: 0.77, blue: 0.83),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
            VStack(spacing: 4) {
                markLayer(width: 23)
                markLayer(width: 19)
                markLayer(width: 15)
            }
            .rotationEffect(.degrees(-14))
            .offset(x: -1, y: 0.5)
        }
        .frame(width: 42, height: 42)
        .shadow(color: Color.black.opacity(0.16), radius: 14, x: 0, y: 10)
    }

    private func markLayer(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(.white.opacity(0.96))
            .frame(width: width, height: 6)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(0.35), lineWidth: 0.6)
            )
    }
}

struct StatusBadge: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }
}

struct DashboardCard<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.86))
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.08), radius: 14, x: 0, y: 8)
    }
}

struct PhasePill: View {
    let key: String
    let current: String
    let completed: [String]

    var body: some View {
        let isCurrent = key == current
        let isCompleted = completed.contains(key)
        let color: Color = isCurrent ? .blue : (isCompleted ? .green : Color.white.opacity(0.16))

        VStack(spacing: 5) {
            Capsule(style: .continuous)
                .fill(color)
                .frame(height: 7)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(isCurrent ? 0.0 : 0.08), lineWidth: 1)
                )
                .shadow(color: color.opacity(isCurrent ? 0.36 : 0.0), radius: 8, x: 0, y: 0)
            Text(phaseLabels[key] ?? key)
                .font(.system(size: 10, weight: isCurrent ? .semibold : .regular, design: .rounded))
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .lineLimit(1)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: current)
    }
}

struct SyncMetricButton: View {
    let label: String
    let value: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Text("\(value)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }
}

struct DashboardSettingsView: View {
    @ObservedObject var preferences: DashboardPreferences
    let onChoosePinnedWorkspace: () -> Void
    let onResetDefaults: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.system(size: 18, weight: .bold, design: .rounded))

            VStack(alignment: .leading, spacing: 8) {
                Text("Workspace Mode")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Picker("", selection: $preferences.workspaceMode) {
                    ForEach(WorkspaceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(preferences.workspaceMode.subtitle)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Pinned Workspace")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                HStack(spacing: 8) {
                    TextField("/path/to/workspace", text: $preferences.pinnedWorkspace)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: onChoosePinnedWorkspace)
                }
                .disabled(preferences.workspaceMode == .auto)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Refresh Interval")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                HStack {
                    Stepper(value: $preferences.refreshInterval, in: 1.0...60.0, step: 1.0) {
                        Text("\(Int(preferences.refreshInterval)) s")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                    Spacer()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Global Root Override")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                TextField(defaultGlobalRoot, text: $preferences.globalRootOverride)
                    .textFieldStyle(.roundedBorder)
                Text("Leave blank to use the canonical shared fabric root.")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Reset Defaults", action: onResetDefaults)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

enum SetupRuntimeSelection: String, CaseIterable, Identifiable {
    case both
    case codex
    case gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both:
            return "Both"
        case .codex:
            return "Codex"
        case .gemini:
            return "Gemini"
        }
    }
}

final class SetupAssistantViewModel: ObservableObject {
    @Published var globalRoot: String
    @Published var workspacePath: String
    @Published var runtimeSelection: SetupRuntimeSelection
    @Published var isRunning = false
    @Published var statusTitle = "Ready"
    @Published var statusDetails = "Choose a shared fabric storage root, then run setup from inside the app."
    @Published var commandPreview = ""

    init(globalRoot: String, workspacePath: String) {
        self.globalRoot = globalRoot
        self.workspacePath = workspacePath
        self.runtimeSelection = .both
    }
}

struct SetupAssistantView: View {
    @ObservedObject var viewModel: SetupAssistantViewModel
    let onChooseGlobalRoot: () -> Void
    let onChooseWorkspace: () -> Void
    let onUseCurrentWorkspace: () -> Void
    let onRunStorageSetup: () -> Void
    let onRunWorkspaceSetup: () -> Void
    let onOpenGlobalRoot: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set Up Shared Fabric")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("Create the shared storage root and optionally enable the current workspace for VSCode in one place.")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: onClose)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Storage Root")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                HStack(spacing: 8) {
                    TextField("/path/to/global-agent-fabric", text: $viewModel.globalRoot)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: onChooseGlobalRoot)
                    Button("Open", action: onOpenGlobalRoot)
                        .disabled(viewModel.globalRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("This runs the storage bootstrap and creates the shared fabric directory layout if it does not already exist.")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Create Storage Root", action: onRunStorageSetup)
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(viewModel.isRunning || viewModel.globalRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("Workspace Entry")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                HStack(spacing: 8) {
                    TextField("/path/to/workspace", text: $viewModel.workspacePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: onChooseWorkspace)
                    Button("Use Current", action: onUseCurrentWorkspace)
                }
                Picker("Runtimes", selection: $viewModel.runtimeSelection) {
                    ForEach(SetupRuntimeSelection.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                Text("This writes `AGENTS.md` and `.vscode/tasks.json`, and refreshes the Gemini bridge when selected.")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Enable Workspace", action: onRunWorkspaceSetup)
                        .buttonStyle(.borderedProminent)
                        .tint(.mint)
                        .disabled(
                            viewModel.isRunning ||
                            viewModel.globalRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            viewModel.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if viewModel.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(viewModel.statusTitle)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                Text(viewModel.statusDetails)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                if !viewModel.commandPreview.isEmpty {
                    Text(viewModel.commandPreview)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                        )
                }
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
    }
}

struct SyncRecordsDetailView: View {
    let title: String
    let records: [SyncRecordEntry]
    let onOpenPath: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
                Button("Done", action: onClose)
            }

            if records.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No records")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text("The latest sync did not write any entries for this category.")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(records) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(record.title)
                                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        Text(record.timestamp)
                                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if !record.mechanism.isEmpty {
                                        Text(record.mechanism)
                                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 5)
                                            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.08)))
                                    }
                                }
                                if !record.summary.isEmpty {
                                    Text(record.summary)
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                }
                                if !record.details.isEmpty {
                                    Text(record.details)
                                        .font(.system(size: 11, weight: .regular, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 8) {
                                    Button("Open Source Log") {
                                        onOpenPath(record.sourcePath)
                                    }
                                    .buttonStyle(.bordered)

                                    ForEach(record.artifacts, id: \.self) { artifact in
                                        Button(URL(fileURLWithPath: artifact).lastPathComponent) {
                                            onOpenPath(artifact)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                    )
                            )
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 620, height: 460)
    }
}

struct ProjectMemoryBrowserView: View {
    let snapshot: DashboardSnapshot
    let initialLane: String?
    let onOpenPath: (String) -> Void
    let onClose: () -> Void

    @State private var selectedLane: String = "all"

    init(
        snapshot: DashboardSnapshot,
        initialLane: String?,
        onOpenPath: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.initialLane = initialLane
        self.onOpenPath = onOpenPath
        self.onClose = onClose
        _selectedLane = State(initialValue: initialLane ?? "all")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project Memory")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(snapshot.projectMemoryLastUpdated.isEmpty ? "No project memory recorded yet." : "Last updated \(snapshot.projectMemoryLastUpdated)")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: onClose)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    memoryLaneButton(label: "All", lane: "all", count: snapshot.projectMemoryRecords.count)
                    ForEach(writeTargetLabels.keys.sorted(), id: \.self) { lane in
                        memoryLaneButton(
                            label: writeTargetLabels[lane] ?? lane,
                            lane: lane,
                            count: snapshot.projectMemoryCounts[lane] ?? 0
                        )
                    }
                }
            }

            if filteredRecords.isEmpty {
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Text("No records")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text("There are no project memory records for this lane yet.")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(filteredRecords) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(record.title)
                                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        Text("\(record.timestamp) · \(record.agent.uppercased()) · \(record.taskId)")
                                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    HStack(spacing: 6) {
                                        if record.isBridged {
                                            bridgeBadge(record)
                                        }
                                        Text(writeTargetLabels[record.lane] ?? record.lane)
                                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 5)
                                            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.08)))
                                    }
                                }
                                Text(record.summary)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                if record.isBridged {
                                    bridgeMetadataView(record)
                                }
                                if !record.details.isEmpty {
                                    Text(record.details)
                                        .font(.system(size: 11, weight: .regular, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 8) {
                                    Button("Open Source Log") {
                                        onOpenPath(record.sourcePath)
                                    }
                                    .buttonStyle(.bordered)

                                    ForEach(record.artifacts, id: \.self) { artifact in
                                        Button(URL(fileURLWithPath: artifact).lastPathComponent) {
                                            onOpenPath(artifact)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                    )
                            )
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 720, height: 560)
    }

    private var filteredRecords: [ProjectMemoryRecord] {
        if selectedLane == "all" {
            return snapshot.projectMemoryRecords
        }
        return snapshot.projectMemoryRecords.filter { $0.lane == selectedLane }
    }

    private func memoryLaneButton(label: String, lane: String, count: Int) -> some View {
        Button {
            selectedLane = lane
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(selectedLane == lane ? Color.blue.opacity(0.22) : Color.white.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
    }

    private func bridgeBadge(_ record: ProjectMemoryRecord) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.system(size: 9, weight: .semibold))
            Text(bridgeFlowLabel(record))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(Color.blue.opacity(0.18)))
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.blue.opacity(0.22), lineWidth: 1)
        )
    }

    private func bridgeMetadataView(_ record: ProjectMemoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cross-runtime provenance")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                metadataCapsule(label: bridgeFlowLabel(record), tint: .blue)
                if !record.bridgeMode.isEmpty {
                    metadataCapsule(label: record.bridgeMode.capitalized, tint: .mint)
                }
                if !record.bridgeSessionId.isEmpty {
                    metadataCapsule(label: record.bridgeSessionId, tint: .secondary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.blue.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.blue.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private func metadataCapsule(label: String, tint: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.14))
            )
    }

    private func bridgeFlowLabel(_ record: ProjectMemoryRecord) -> String {
        let origin = record.originRuntime.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = record.targetRuntime.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (origin.isEmpty, target.isEmpty) {
        case (false, false):
            return "\(origin.capitalized) -> \(target.capitalized)"
        case (false, true):
            return origin.capitalized
        case (true, false):
            return target.capitalized
        default:
            return "Cross-runtime"
        }
    }
}

struct DashboardRootView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var preferences: DashboardPreferences
    let onRefresh: () -> Void
    let onOpenLogs: () -> Void
    let onOpenCurrentWorkspace: () -> Void
    let onOpenPath: (String) -> Void
    let onOpenSettings: () -> Void
    let onOpenSetup: () -> Void
    let onOpenProjectMemory: (String?) -> Void
    let onFollowLatestWorkspace: () -> Void
    let onSelectWorkspace: (String) -> Void
    let onPreviousWorkspace: () -> Void
    let onNextWorkspace: () -> Void
    @State private var selectedSyncTarget: String?

    var body: some View {
        ZStack {
            VisualEffectView(material: .underWindowBackground, blendingMode: .withinWindow)
                .ignoresSafeArea()
            LinearGradient(
                colors: [Color.white.opacity(0.08), Color.blue.opacity(0.05), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if let snapshot = viewModel.snapshot {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        header(snapshot: snapshot)
                        sessionCard(snapshot: snapshot)
                        phaseCard(snapshot: snapshot)
                        syncDeltaCard(snapshot: snapshot)
                        projectMemoryCard(snapshot: snapshot)
                        recentActivityCard(snapshot: snapshot)
                        footerBar
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.errorMessage.isEmpty ? "Loading dashboard…" : viewModel.errorMessage)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.25), value: viewModel.refreshToken)
        .sheet(
            isPresented: Binding(
                get: { selectedSyncTarget != nil },
                set: { if !$0 { selectedSyncTarget = nil } }
            )
        ) {
            if let snapshot = viewModel.snapshot {
                let targetKey = selectedSyncTarget ?? ""
                let label = writeTargetLabels[targetKey] ?? targetKey
                SyncRecordsDetailView(
                    title: "\(label) Details",
                    records: snapshot.lastSyncDelta.records.filter { $0.target == targetKey },
                    onOpenPath: onOpenPath,
                    onClose: { selectedSyncTarget = nil }
                )
            }
        }
    }

    private func header(snapshot: DashboardSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SharedFabricMark()
            VStack(alignment: .leading, spacing: 4) {
                Text("Shared Fabric Dashboard")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                workspaceSelector(snapshot: snapshot)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                attentionBadge(snapshot.attentionState)
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func workspaceSelector(snapshot: DashboardSnapshot) -> some View {
        Menu {
            Button("Follow Latest Workspace", action: onFollowLatestWorkspace)
            Divider()
            if snapshot.availableWorkspaces.isEmpty {
                Button("No workspaces available") {}
                    .disabled(true)
            } else {
                ForEach(snapshot.availableWorkspaces) { option in
                    Button("\(option.label) · \(option.source)") {
                        onSelectWorkspace(option.path)
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(snapshot.projectName)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(preferences.workspaceMode.title.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.09)))
                }
                Text(snapshot.workspace.isEmpty ? "No workspace selected" : snapshot.workspace)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
            )
        }
        .menuStyle(.borderlessButton)
    }

    private func sessionCard(snapshot: DashboardSnapshot) -> some View {
        DashboardCard(title: "Session", symbol: "terminal") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(snapshot.runtime.uppercased()) · \(snapshot.lifecyclePhase)")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                        Text(snapshot.taskId)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("MCP \(snapshot.activeMcpCount)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.08)))
                }
                Text(snapshot.workspace.isEmpty ? "No workspace is active yet." : snapshot.workspace)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    StatusBadge(label: "Boot", value: snapshot.bootStatus, color: snapshot.bootStatus == "OK" ? .green : .orange)
                    StatusBadge(label: "Sync", value: snapshot.syncStatus, color: snapshot.syncStatus == "OK" ? .blue : .orange)
                    StatusBadge(label: "Audit", value: snapshot.syncAuditSource.uppercased(), color: snapshot.syncAuditSource == "exact" ? .mint : .orange)
                }
            }
        }
    }

    private func phaseCard(snapshot: DashboardSnapshot) -> some View {
        let phaseStatusLabel: String
        let phaseStatusSymbol: String
        if snapshot.sixStageCurrent.isEmpty && snapshot.sixStageCompleted.count == phaseOrder.count {
            phaseStatusLabel = "Completed"
            phaseStatusSymbol = "checkmark.circle"
        } else {
            phaseStatusLabel = phaseLabels[snapshot.sixStageCurrent] ?? "Idle"
            phaseStatusSymbol = "point.topleft.down.curvedto.point.bottomright.up"
        }

        return DashboardCard(title: "Phase", symbol: "waveform.path.ecg.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(phaseOrder, id: \.self) { key in
                        PhasePill(key: key, current: snapshot.sixStageCurrent, completed: snapshot.sixStageCompleted)
                    }
                }
                HStack(spacing: 8) {
                    Label(phaseStatusLabel, systemImage: phaseStatusSymbol)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Spacer()
                    Text("source · \(snapshot.phaseSource)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text(snapshot.sixStageNote.isEmpty ? "Exact phase note will appear here once the task writes one." : snapshot.sixStageNote)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(snapshot.sixStageNote.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
            }
        }
    }

    private func syncDeltaCard(snapshot: DashboardSnapshot) -> some View {
        DashboardCard(title: "Sync Delta", symbol: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(writeTargetLabels.keys.sorted(), id: \.self) { key in
                        SyncMetricButton(
                            label: writeTargetLabels[key] ?? key,
                            value: snapshot.lastSyncDelta.writesCountByTarget[key] ?? 0,
                            action: { selectedSyncTarget = key }
                        )
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Learned")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    if snapshot.lastSyncDelta.learnedItems.isEmpty {
                        Text("No durable learnings recorded in the latest sync.")
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(snapshot.lastSyncDelta.learnedItems, id: \.self) { item in
                            bulletRow(symbol: "sparkles", text: item, tint: .green)
                        }
                    }
                }
                if !snapshot.lastSyncDelta.skippedItems.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Skipped")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        ForEach(snapshot.lastSyncDelta.skippedItems, id: \.self) { item in
                            bulletRow(symbol: "exclamationmark.circle", text: item, tint: .orange)
                        }
                    }
                }
                Text(snapshot.lastSyncDelta.sourceSummary)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.86))
                    .lineLimit(2)
            }
        }
    }

    private func recentActivityCard(snapshot: DashboardSnapshot) -> some View {
        DashboardCard(title: "Recent Activity", symbol: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 10) {
                bulletRow(symbol: "memorychip", text: snapshot.lastHandoff, tint: .blue)
                ForEach(snapshot.recentTasks.prefix(3)) { item in
                    HStack(spacing: 8) {
                        Text(item.time)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(item.agent.uppercased())
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.07)))
                        Text(item.taskId)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text("B:\(item.boot) S:\(item.sync)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                if !snapshot.alerts.isEmpty {
                    Divider().overlay(Color.white.opacity(0.08))
                    ForEach(snapshot.alerts.prefix(3), id: \.self) { alert in
                        bulletRow(symbol: "exclamationmark.triangle.fill", text: alert, tint: .orange)
                    }
                }
            }
        }
    }

    private func projectMemoryCard(snapshot: DashboardSnapshot) -> some View {
        DashboardCard(title: "Project Memory", symbol: "books.vertical") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(writeTargetLabels.keys.sorted(), id: \.self) { lane in
                        SyncMetricButton(
                            label: writeTargetLabels[lane] ?? lane,
                            value: snapshot.projectMemoryCounts[lane] ?? 0,
                            action: { onOpenProjectMemory(lane) }
                        )
                    }
                }
                Text(snapshot.projectMemoryLastUpdated.isEmpty ? "No project memory has been indexed yet." : "Last updated \(snapshot.projectMemoryLastUpdated)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                ForEach(snapshot.projectMemoryRecords.prefix(3)) { record in
                    bulletRow(
                        symbol: "tray.full",
                        text: "\(writeTargetLabels[record.lane] ?? record.lane): \(record.summary)",
                        tint: .mint
                    )
                }
                HStack {
                    Spacer()
                    Button("Browse Project Memory") {
                        onOpenProjectMemory(nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }
            }
        }
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            Button(action: { onOpenProjectMemory(nil) }) {
                Label("Memory", systemImage: "books.vertical")
            }
            .buttonStyle(.bordered)

            Button(action: onOpenSetup) {
                Label("Setup", systemImage: "shippingbox")
            }
            .buttonStyle(.bordered)

            Button(action: onPreviousWorkspace) {
                Label("Previous", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)

            Button(action: onNextWorkspace) {
                Label("Next", systemImage: "chevron.right")
            }
            .buttonStyle(.bordered)

            Button(action: onRefresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)

            Button(action: onOpenCurrentWorkspace) {
                Label("Workspace", systemImage: "folder")
            }
            .buttonStyle(.bordered)

            Button(action: onOpenLogs) {
                Label("Sync Logs", systemImage: "tray.full")
            }
            .buttonStyle(.bordered)
        }
    }

    private func bulletRow(symbol: String, text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.primary.opacity(0.92))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func attentionBadge(_ state: String) -> some View {
        let style: (Color, String) = switch state {
        case "healthy": (.green, "Healthy")
        case "missing_learning_receipt": (.orange, "Audit Missing")
        case "synced_without_learning": (.orange, "No Learning")
        case "active_pending_sync": (.blue, "In Flight")
        default: (.secondary, "Idle")
        }
        return HStack(spacing: 6) {
            Circle().fill(style.0).frame(width: 7, height: 7)
            Text(style.1)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.08)))
    }
}

final class FloatingDashboardController: NSObject, NSWindowDelegate {
    private struct SnapshotRequest {
        let script: String
        let workspace: String?
        let globalRoot: String
        let geminiSettings: String?
    }

    private let config: DashboardConfig
    let preferences: DashboardPreferences
    private let viewModel = DashboardViewModel()
    private let onClose: (FloatingDashboardController) -> Void

    private var panel: NSWindow!
    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var setupViewModel: SetupAssistantViewModel?
    private var projectMemoryWindow: NSWindow?
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var pendingRefresh = false
    private var refreshSequence = 0
    private var cancellables = Set<AnyCancellable>()

    init(config: DashboardConfig, preferences: DashboardPreferences, onClose: @escaping (FloatingDashboardController) -> Void) {
        self.config = config
        self.preferences = preferences
        self.onClose = onClose
        super.init()
        observePreferences()
    }

    var window: NSWindow? {
        panel
    }

    func start() {
        createPanel()
        refresh()
        resetRefreshTimer()
    }

    func windowWillClose(_ notification: Notification) {
        if let closed = notification.object as? NSWindow, closed === settingsWindow {
            settingsWindow = nil
            return
        }
        if let closed = notification.object as? NSWindow, closed === setupWindow {
            setupWindow = nil
            setupViewModel = nil
            return
        }
        if let closed = notification.object as? NSWindow, closed === projectMemoryWindow {
            projectMemoryWindow = nil
            return
        }
        refreshTimer?.invalidate()
        refreshTask?.cancel()
        refreshTask = nil
        pendingRefresh = false
        settingsWindow?.close()
        setupWindow?.close()
        projectMemoryWindow?.close()
        onClose(self)
    }

    func refreshNow() {
        refresh()
    }

    func followLatestWorkspace() {
        preferences.setAuto()
    }

    func selectWorkspace(_ path: String) {
        preferences.setPinned(path)
    }

    func selectPreviousWorkspace() {
        cycleWorkspace(step: -1)
    }

    func selectNextWorkspace() {
        cycleWorkspace(step: 1)
    }

    func openCurrentWorkspace() {
        guard let path = currentWorkspacePath() else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    func openSyncFolder() {
        let target = URL(fileURLWithPath: preferences.effectiveGlobalRoot).appendingPathComponent("sync")
        NSWorkspace.shared.open(target)
    }

    func openPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: trimmed))
    }

    func openSettingsWindow() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = DashboardSettingsView(
            preferences: preferences,
            onChoosePinnedWorkspace: { [weak self] in self?.choosePinnedWorkspace() },
            onResetDefaults: { [weak self] in
                guard let self else { return }
                self.preferences.resetToDefaults(config: self.config)
            }
        )
        let hosting = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 280, y: 280, width: 480, height: 280),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        window.delegate = self
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func openSetupWindow() {
        if let setupWindow {
            if let currentWorkspace = currentWorkspacePath() {
                setupViewModel?.workspacePath = currentWorkspace
            }
            setupViewModel?.globalRoot = preferences.effectiveGlobalRoot
            setupWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = SetupAssistantViewModel(
            globalRoot: preferences.effectiveGlobalRoot,
            workspacePath: currentWorkspacePath() ?? ""
        )
        setupViewModel = viewModel

        let rootView = SetupAssistantView(
            viewModel: viewModel,
            onChooseGlobalRoot: { [weak self] in self?.chooseSetupGlobalRoot() },
            onChooseWorkspace: { [weak self] in self?.chooseSetupWorkspace() },
            onUseCurrentWorkspace: { [weak self] in
                guard let self, let current = self.currentWorkspacePath() else { return }
                self.setupViewModel?.workspacePath = current
            },
            onRunStorageSetup: { [weak self] in self?.runStorageSetup() },
            onRunWorkspaceSetup: { [weak self] in self?.runWorkspaceSetup() },
            onOpenGlobalRoot: { [weak self] in
                guard let path = self?.setupViewModel?.globalRoot else { return }
                self?.openPath(path)
            },
            onClose: { [weak self] in self?.closeSetupWindow() }
        )
        let hosting = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 320, y: 240, width: 620, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up Shared Fabric"
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        window.delegate = self
        setupWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func openProjectMemoryWindow(initialLane: String?) {
        guard let snapshot = viewModel.snapshot else { return }
        if let projectMemoryWindow {
            projectMemoryWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = ProjectMemoryBrowserView(
            snapshot: snapshot,
            initialLane: initialLane,
            onOpenPath: { [weak self] path in self?.openPath(path) },
            onClose: { [weak self] in self?.closeProjectMemoryWindow() }
        )
        let hosting = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 340, y: 260, width: 740, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Project Memory"
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        window.delegate = self
        projectMemoryWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func observePreferences() {
        preferences.objectWillChange
            .sink { [weak self] in
                DispatchQueue.main.async {
                    self?.preferencesDidChange()
                }
            }
            .store(in: &cancellables)
    }

    private func preferencesDidChange() {
        resetRefreshTimer()
        refresh()
    }

    private func resetRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: preferences.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func currentWorkspacePath() -> String? {
        let snapshotWorkspace = viewModel.snapshot?.workspace.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !snapshotWorkspace.isEmpty {
            return snapshotWorkspace
        }
        return preferences.effectiveWorkspaceArgument
    }

    private func choosePinnedWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Workspace"
        if panel.runModal() == .OK, let url = panel.url {
            preferences.setPinned(url.path)
        }
    }

    private func closeProjectMemoryWindow() {
        projectMemoryWindow?.close()
        projectMemoryWindow = nil
    }

    private func closeSetupWindow() {
        setupWindow?.close()
        setupWindow = nil
        setupViewModel = nil
    }

    private func cycleWorkspace(step: Int) {
        guard let snapshot = viewModel.snapshot, !snapshot.availableWorkspaces.isEmpty else { return }
        let paths = snapshot.availableWorkspaces.map(\.path)
        let currentPath = currentWorkspacePath() ?? paths[0]
        let currentIndex = paths.firstIndex(of: currentPath) ?? 0
        let nextIndex = (currentIndex + step + paths.count) % paths.count
        preferences.setPinned(paths[nextIndex])
    }

    private func createPanel() {
        panel = NSWindow(
            contentRect: NSRect(x: 220, y: 220, width: 720, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Shared Fabric Dashboard"
        panel.titleVisibility = .visible
        panel.titlebarAppearsTransparent = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.delegate = self
        panel.minSize = NSSize(width: 520, height: 420)
        panel.isReleasedWhenClosed = false

        let rootView = DashboardRootView(
            viewModel: viewModel,
            preferences: preferences,
            onRefresh: { [weak self] in self?.refreshNow() },
            onOpenLogs: { [weak self] in self?.openSyncFolder() },
            onOpenCurrentWorkspace: { [weak self] in self?.openCurrentWorkspace() },
            onOpenPath: { [weak self] path in self?.openPath(path) },
            onOpenSettings: { [weak self] in self?.openSettingsWindow() },
            onOpenSetup: { [weak self] in self?.openSetupWindow() },
            onOpenProjectMemory: { [weak self] lane in self?.openProjectMemoryWindow(initialLane: lane) },
            onFollowLatestWorkspace: { [weak self] in self?.followLatestWorkspace() },
            onSelectWorkspace: { [weak self] path in self?.selectWorkspace(path) },
            onPreviousWorkspace: { [weak self] in self?.selectPreviousWorkspace() },
            onNextWorkspace: { [weak self] in self?.selectNextWorkspace() }
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: contentView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        panel.contentView = contentView
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refresh() {
        pendingRefresh = true
        guard refreshTask == nil else {
            return
        }
        startRefreshTask()
    }

    private func startRefreshTask() {
        guard pendingRefresh else {
            return
        }
        pendingRefresh = false
        refreshSequence += 1
        let requestID = refreshSequence
        let request = makeSnapshotRequest()

        refreshTask = Task.detached(priority: .utility) { [weak self] in
            let result = Result { try Self.loadSnapshot(request: request) }
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                defer {
                    self.refreshTask = nil
                    if self.pendingRefresh {
                        self.startRefreshTask()
                    }
                }
                guard requestID == self.refreshSequence else {
                    return
                }

                switch result {
                case .success(let snapshot):
                    let projectTitle = snapshot.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.panel.title = projectTitle.isEmpty ? "Shared Fabric Dashboard" : "Shared Fabric Dashboard · \(projectTitle)"
                    self.viewModel.apply(snapshot: snapshot)
                case .failure(let error):
                    self.viewModel.apply(error: error)
                }
            }
        }
    }

    private func makeSnapshotRequest() -> SnapshotRequest {
        SnapshotRequest(
            script: config.snapshotScript,
            workspace: preferences.effectiveWorkspaceArgument,
            globalRoot: preferences.effectiveGlobalRoot,
            geminiSettings: config.geminiSettings?.isEmpty == false ? config.geminiSettings : nil
        )
    }

    private static func loadSnapshot(request: SnapshotRequest) throws -> DashboardSnapshot {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        var arguments = ["python3", request.script]
        if let workspace = request.workspace {
            arguments += ["--workspace", workspace]
        }
        arguments += ["--global-root", request.globalRoot]
        if let geminiSettings = request.geminiSettings {
            arguments += ["--gemini-settings", geminiSettings]
        }
        process.arguments = arguments

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
        let stdoutURL = tempRoot.appendingPathComponent("shared-fabric-dashboard-\(UUID().uuidString)-stdout.json")
        let stderrURL = tempRoot.appendingPathComponent("shared-fabric-dashboard-\(UUID().uuidString)-stderr.log")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            try? fileManager.removeItem(at: stdoutURL)
            try? fileManager.removeItem(at: stderrURL)
        }

        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        try process.run()
        process.waitUntilExit()

        let data = try Data(contentsOf: stdoutURL)
        if process.terminationStatus != 0 {
            let errorData = (try? Data(contentsOf: stderrURL)) ?? Data()
            let message = String(data: errorData, encoding: .utf8) ?? "snapshot export failed"
            throw NSError(domain: "FloatingDashboard", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONDecoder().decode(DashboardSnapshot.self, from: data)
    }

    private func chooseSetupGlobalRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Storage Root"
        if panel.runModal() == .OK, let url = panel.url {
            setupViewModel?.globalRoot = url.path
        }
    }

    private func chooseSetupWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Workspace"
        if panel.runModal() == .OK, let url = panel.url {
            setupViewModel?.workspacePath = url.path
        }
    }

    private func setupScriptURL(named fileName: String) -> URL? {
        guard let repoRoot = config.repositoryRoot else { return nil }
        return URL(fileURLWithPath: repoRoot).appendingPathComponent("install/\(fileName)")
    }

    private func runStorageSetup() {
        guard let viewModel = setupViewModel else { return }
        let globalRoot = viewModel.globalRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !globalRoot.isEmpty else { return }
        guard let scriptURL = setupScriptURL(named: "bootstrap_shared_fabric.py") else {
            viewModel.statusTitle = "Setup script missing"
            viewModel.statusDetails = "Could not locate install/bootstrap_shared_fabric.py from the current app workspace."
            return
        }

        let command = ["python3", scriptURL.path, "--global-root", globalRoot, "--non-interactive"]
        viewModel.commandPreview = command.joined(separator: " ")
        viewModel.isRunning = true
        viewModel.statusTitle = "Creating storage root…"
        viewModel.statusDetails = "Running the shared fabric bootstrap now."

        runSetupCommand(command) { [weak self] result in
            guard let self, let viewModel = self.setupViewModel else { return }
            viewModel.isRunning = false
            switch result {
            case .success(let payload):
                let createdCount = (payload["created_paths"] as? [Any])?.count ?? 0
                let globalRootValue = (payload["global_root"] as? String) ?? globalRoot
                self.preferences.globalRootOverride = globalRootValue
                viewModel.globalRoot = globalRootValue
                viewModel.statusTitle = "Storage root ready"
                viewModel.statusDetails = "Bootstrap completed for \(globalRootValue).\nCreated \(createdCount) new path(s) and refreshed the dashboard's global root preference."
            case .failure(let error):
                viewModel.statusTitle = "Storage setup failed"
                viewModel.statusDetails = error.localizedDescription
            }
        }
    }

    private func runWorkspaceSetup() {
        guard let viewModel = setupViewModel else { return }
        let globalRoot = viewModel.globalRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = viewModel.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !globalRoot.isEmpty, !workspace.isEmpty else { return }
        guard let scriptURL = setupScriptURL(named: "bootstrap_vscode_workspace.py") else {
            viewModel.statusTitle = "Workspace script missing"
            viewModel.statusDetails = "Could not locate install/bootstrap_vscode_workspace.py from the current app workspace."
            return
        }

        let command = [
            "python3",
            scriptURL.path,
            "--workspace",
            workspace,
            "--global-root",
            globalRoot,
            "--runtimes",
            viewModel.runtimeSelection.rawValue,
        ]
        viewModel.commandPreview = command.joined(separator: " ")
        viewModel.isRunning = true
        viewModel.statusTitle = "Enabling workspace…"
        viewModel.statusDetails = "Writing AGENTS.md and VSCode tasks for this workspace."

        runSetupCommand(command) { [weak self] result in
            guard let self, let viewModel = self.setupViewModel else { return }
            viewModel.isRunning = false
            switch result {
            case .success(let payload):
                let agentsFile = (payload["agents_file"] as? String) ?? ""
                let tasksFile = (payload["vscode_tasks"] as? String) ?? ""
                self.preferences.setPinned(workspace)
                self.refreshNow()
                viewModel.statusTitle = "Workspace enabled"
                viewModel.statusDetails = "Workspace bootstrap completed for \(workspace).\nAGENTS: \(agentsFile)\nTasks: \(tasksFile)"
            case .failure(let error):
                viewModel.statusTitle = "Workspace setup failed"
                viewModel.statusDetails = error.localizedDescription
            }
        }
    }

    private func runSetupCommand(_ command: [String], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        Task.detached(priority: .userInitiated) {
            do {
                let payload = try Self.executeJSONCommand(command)
                await MainActor.run {
                    completion(.success(payload))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    private static func executeJSONCommand(_ command: [String]) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = stderrText.isEmpty ? stdoutText : stderrText
            throw NSError(
                domain: "SharedFabricSetup",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }

        guard
            let object = parseJSONObject(from: stdoutText)
        else {
            throw NSError(
                domain: "SharedFabricSetup",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Setup completed but did not return valid JSON output."]
            )
        }
        return object
    }

    private static func parseJSONObject(from text: String) -> [String: Any]? {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }

        for index in text.indices.reversed() where text[index] == "{" {
            let candidate = String(text[index...])
            guard let data = candidate.data(using: .utf8) else { continue }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
        }
        return nil
    }
}

final class DashboardAppController: NSObject, NSApplicationDelegate {
    private enum LaunchKeys {
        static let setupCheckVersion = "shared_fabric_dashboard.setup_check_version"
    }

    private let config: DashboardConfig
    private var controllers: [FloatingDashboardController] = []

    init(config: DashboardConfig) {
        self.config = config
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installAppIcon()
        installMenus()
        openNewWindow()
        performInitialSetupCheckIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }

        if controllers.isEmpty {
            openNewWindow()
            return true
        }

        controllers.compactMap(\.window).forEach { $0.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    @objc func newWindow(_ sender: Any?) {
        openNewWindow(seed: activeController()?.preferences.cloned())
    }

    @objc func showSettings(_ sender: Any?) {
        activeController()?.openSettingsWindow()
    }

    @objc func showSetupAssistant(_ sender: Any?) {
        activeController()?.openSetupWindow()
    }

    @objc func browseProjectMemory(_ sender: Any?) {
        activeController()?.openProjectMemoryWindow(initialLane: nil)
    }

    @objc func refreshCurrent(_ sender: Any?) {
        activeController()?.refreshNow()
    }

    @objc func followLatestWorkspace(_ sender: Any?) {
        activeController()?.followLatestWorkspace()
    }

    @objc func previousWorkspace(_ sender: Any?) {
        activeController()?.selectPreviousWorkspace()
    }

    @objc func nextWorkspace(_ sender: Any?) {
        activeController()?.selectNextWorkspace()
    }

    @objc func openCurrentWorkspace(_ sender: Any?) {
        activeController()?.openCurrentWorkspace()
    }

    @objc func openSharedFabricSync(_ sender: Any?) {
        activeController()?.openSyncFolder()
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(sender)
    }

    @objc func openHelp(_ sender: Any?) {
        let docURL = URL(fileURLWithPath: config.snapshotScript)
            .deletingLastPathComponent()
            .appendingPathComponent("README.md")
        NSWorkspace.shared.open(docURL)
    }

    private func activeController() -> FloatingDashboardController? {
        if let keyWindow = NSApp.keyWindow {
            return controllers.first(where: { $0.window === keyWindow })
        }
        if let mainWindow = NSApp.mainWindow {
            return controllers.first(where: { $0.window === mainWindow })
        }
        return controllers.last
    }

    private func openNewWindow(seed: DashboardPreferences? = nil) {
        let preferences = seed ?? DashboardPreferences(config: config)
        let controller = FloatingDashboardController(config: config, preferences: preferences) { [weak self] closed in
            self?.controllers.removeAll(where: { $0 === closed })
        }
        controllers.append(controller)
        controller.start()
    }

    private func performInitialSetupCheckIfNeeded() {
        let defaults = UserDefaults.standard
        let currentVersion = "setup-assistant-v1"
        guard defaults.string(forKey: LaunchKeys.setupCheckVersion) != currentVersion else {
            return
        }
        defaults.set(currentVersion, forKey: LaunchKeys.setupCheckVersion)

        guard let controller = activeController() ?? controllers.last else { return }
        let globalRoot = controller.preferences.effectiveGlobalRoot

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            switch self.assessSetupEnvironment(globalRoot: globalRoot) {
            case .ready:
                self.presentEnvironmentReadyAlert(for: controller, globalRoot: globalRoot)
            case .incomplete(let missing):
                self.presentEnvironmentIncompleteAlert(for: controller, globalRoot: globalRoot, missing: missing)
            }
        }
    }

    private func assessSetupEnvironment(globalRoot: String) -> SetupEnvironmentStatus {
        let root = URL(fileURLWithPath: globalRoot)
        let fileManager = FileManager.default
        let requiredRelativePaths = [
            "sync/boot-sequence.md",
            "memory/architecture.md",
            "memory/routes.yaml",
            "memory/schema.yaml",
            "memory/ki-registry.yaml",
            "memory/mempalace-taxonomy.yaml",
            "mcp/secrets.example.yaml",
            "projects/registry.yaml",
            "scripts/sync/preflight_check.py",
            "scripts/sync/sync_all.py",
            "scripts/sync/postflight_sync.py",
        ]
        let missing = requiredRelativePaths.filter { relativePath in
            !fileManager.fileExists(atPath: root.appendingPathComponent(relativePath).path)
        }
        if missing.isEmpty {
            return .ready
        }
        return .incomplete(missing: missing)
    }

    private func presentEnvironmentReadyAlert(for controller: FloatingDashboardController, globalRoot: String) {
        let alert = NSAlert()
        alert.messageText = "Shared Fabric environment is ready"
        alert.informativeText = "The current storage root already looks complete at:\n\(globalRoot)\n\nNo changes were made."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Open Setup")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            controller.openSetupWindow()
        }
    }

    private func presentEnvironmentIncompleteAlert(for controller: FloatingDashboardController, globalRoot: String, missing: [String]) {
        let alert = NSAlert()
        alert.messageText = "Shared Fabric needs setup"
        let missingPreview = missing.prefix(4).joined(separator: "\n")
        let moreSuffix = missing.count > 4 ? "\n…" : ""
        alert.informativeText = "The current storage root is missing required files or folders:\n\(globalRoot)\n\n\(missingPreview)\(moreSuffix)\n\nOpen the setup assistant now?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Set Up Now")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            controller.openSetupWindow()
        }
    }

    private func installAppIcon() {
        let bundle = Bundle.main
        let iconCandidates = [
            bundle.url(forResource: "SharedFabricDashboard", withExtension: "icns"),
            bundle.url(forResource: "SharedFabricDashboard", withExtension: "png"),
        ].compactMap { $0 }

        for url in iconCandidates {
            if let image = NSImage(contentsOf: url) {
                NSApp.applicationIconImage = image
                break
            }
        }
    }

    private func installMenus() {
        let mainMenu = NSMenu()

        func targetedItem(_ title: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            return item
        }

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(targetedItem("About Shared Fabric Dashboard", action: #selector(showAbout(_:)), key: "", modifiers: []))
        appMenu.addItem(.separator())
        appMenu.addItem(targetedItem("Settings…", action: #selector(showSettings(_:)), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Shared Fabric Dashboard", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Shared Fabric Dashboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(quitItem)

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(targetedItem("New Window", action: #selector(newWindow(_:)), key: "n"))
        fileMenu.addItem(targetedItem("Set Up Shared Fabric…", action: #selector(showSetupAssistant(_:)), key: "", modifiers: []))
        fileMenu.addItem(targetedItem("Open Current Workspace in Finder", action: #selector(openCurrentWorkspace(_:)), key: "o", modifiers: [.command, .shift]))
        fileMenu.addItem(targetedItem("Open Shared Fabric Sync Folder", action: #selector(openSharedFabricSync(_:)), key: "", modifiers: []))
        fileMenu.addItem(.separator())
        let closeWindowItem = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeWindowItem.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(closeWindowItem)

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(targetedItem("Refresh", action: #selector(refreshCurrent(_:)), key: "r"))
        viewMenu.addItem(targetedItem("Browse Project Memory", action: #selector(browseProjectMemory(_:)), key: "m"))
        viewMenu.addItem(targetedItem("Follow Latest Workspace", action: #selector(followLatestWorkspace(_:)), key: "", modifiers: []))
        viewMenu.addItem(targetedItem("Previous Workspace", action: #selector(previousWorkspace(_:)), key: "["))
        viewMenu.addItem(targetedItem("Next Workspace", action: #selector(nextWorkspace(_:)), key: "]"))

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        let minimizeItem = NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        minimizeItem.keyEquivalentModifierMask = [.command]
        windowMenu.addItem(minimizeItem)
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = windowMenu

        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        helpMenu.addItem(targetedItem("Open Dashboard Docs", action: #selector(openHelp(_:)), key: "?", modifiers: [.command, .shift]))

        NSApp.mainMenu = mainMenu
    }
}

func parseConfig() -> DashboardConfig {
    let environment = ProcessInfo.processInfo.environment
    let fileManager = FileManager.default

    func findWorkspaceRoot(from start: URL) -> String? {
        var current = start.resolvingSymlinksInPath()
        while true {
            let snapshot = current.appendingPathComponent("tools/compact_dashboard/export_snapshot.py")
            if fileManager.fileExists(atPath: snapshot.path) {
                return current.path
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
    }

    func defaultWorkspace() -> String? {
        if let override = environment["SHARED_FABRIC_DASHBOARD_WORKSPACE"], !override.isEmpty {
            return override
        }
        if let override = environment["MCP_HUB_DASHBOARD_WORKSPACE"], !override.isEmpty {
            return override
        }
        return nil
    }

    func defaultSnapshotScript(workspace: String?) -> String {
        if let override = environment["SHARED_FABRIC_DASHBOARD_SNAPSHOT_SCRIPT"], !override.isEmpty {
            return override
        }
        if let override = environment["MCP_HUB_DASHBOARD_SNAPSHOT_SCRIPT"], !override.isEmpty {
            return override
        }
        if let workspace, !workspace.isEmpty {
            return URL(fileURLWithPath: workspace)
                .appendingPathComponent("tools/compact_dashboard/export_snapshot.py")
                .path
        }

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [
            executableURL.deletingLastPathComponent(),
            URL(fileURLWithPath: fileManager.currentDirectoryPath).resolvingSymlinksInPath(),
        ]
        for candidate in candidates {
            if let root = findWorkspaceRoot(from: candidate) {
                return URL(fileURLWithPath: root)
                    .appendingPathComponent("tools/compact_dashboard/export_snapshot.py")
                    .path
            }
        }
        return "tools/compact_dashboard/export_snapshot.py"
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
        initialWorkspace: workspace,
        initialGlobalRoot: globalRoot,
        geminiSettings: geminiSettings,
        snapshotScript: snapshotScript
    )
}

let app = NSApplication.shared
let delegate = DashboardAppController(config: parseConfig())
app.setActivationPolicy(.regular)
app.delegate = delegate
app.activate(ignoringOtherApps: true)
app.run()
