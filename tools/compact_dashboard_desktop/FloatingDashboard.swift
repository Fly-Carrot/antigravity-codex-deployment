import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI
import WebKit

private let dataAcquisitionFeaturesEnabled = false
private let exportCommandTimeout: TimeInterval = 60
private let obsidianTaskTimeout: TimeInterval = 120
private let geminiCommandTimeout: TimeInterval = 180
private let snapshotCommandTimeout: TimeInterval = 45
private let setupCommandTimeout: TimeInterval = 90

enum OperationLogStatus: String {
    case running
    case completed
    case failed
    case cancelled

    var title: String {
        switch self {
        case .running:
            return "Running"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
}

struct OperationLogEntry: Identifiable {
    let id: String
    let timestamp: String
    let category: String
    let title: String
    let detail: String
    let status: OperationLogStatus
    let commandPreview: String
    let workspace: String
}

struct DashboardConfig {
    let initialWorkspace: String?
    let initialGlobalRoot: String?
    let initialVaultRoot: String?
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

private let appHomeDirectory = FileManager.default.homeDirectoryForCurrentUser

private struct ExternalCommandResult {
    let stdoutData: Data
    let stderrData: Data
    let terminationStatus: Int32

    var stdoutText: String {
        String(data: stdoutData, encoding: .utf8) ?? ""
    }

    var stderrText: String {
        String(data: stderrData, encoding: .utf8) ?? ""
    }
}

private final class ExternalCommandOutputCollector {
    private let stdout: Pipe
    private let stderr: Pipe
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()

    init(stdout: Pipe, stderr: Pipe) {
        self.stdout = stdout
        self.stderr = stderr
    }

    func start() {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData, toStdout: true)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData, toStdout: false)
        }
    }

    func stopAndResult(terminationStatus: Int32) -> ExternalCommandResult {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        append(stdout.fileHandleForReading.availableData, toStdout: true)
        append(stderr.fileHandleForReading.availableData, toStdout: false)
        lock.lock()
        let result = ExternalCommandResult(stdoutData: stdoutData, stderrData: stderrData, terminationStatus: terminationStatus)
        lock.unlock()
        return result
    }

    func stop() {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
    }

    private func append(_ data: Data, toStdout: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if toStdout {
            stdoutData.append(data)
        } else {
            stderrData.append(data)
        }
        lock.unlock()
    }
}

private enum ExternalCommandError: LocalizedError {
    case timedOut(command: String, timeout: TimeInterval)
    case failed(command: String, status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case let .timedOut(command, timeout):
            return "\(command) timed out after \(Int(timeout))s."
        case let .failed(command, status, message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "\(command) failed with exit code \(status)."
            }
            return "\(command) failed with exit code \(status): \(detail)"
        }
    }
}

private enum OpenTargetError: LocalizedError {
    case pathOutsideAllowedRoots(String)
    case remoteURLNotAllowed(String)

    var errorDescription: String? {
        switch self {
        case let .pathOutsideAllowedRoots(path):
            return "Refused to open a path outside the allowed knowledge-base roots: \(path)"
        case let .remoteURLNotAllowed(url):
            return "Refused to open a remote URL from the local knowledge graph/wiki: \(url)"
        }
    }
}

private func terminateExternalProcess(_ process: Process) {
    if process.isRunning {
        process.terminate()
        usleep(200_000)
    }
    if process.isRunning {
        process.interrupt()
        usleep(200_000)
    }
}

private func processEnvironmentWithoutBytecode() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    // Python bytecode caches would mutate the signed .app bundle when scripts run
    // from Contents/Resources, so keep helper scripts read-only at runtime.
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    return environment
}

private func waitForProcessExit(_ process: Process, timeout: TimeInterval, commandDescription: String) throws {
    let group = DispatchGroup()
    group.enter()
    process.terminationHandler = { _ in
        group.leave()
    }
    try process.run()
    let finishedInTime = group.wait(timeout: .now() + timeout) == .success
    process.terminationHandler = nil
    guard finishedInTime else {
        if process.isRunning {
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
        }
        if process.isRunning {
            process.interrupt()
            _ = group.wait(timeout: .now() + 1)
        }
        throw ExternalCommandError.timedOut(command: commandDescription, timeout: timeout)
    }
}

private func executeExternalCommand(
    arguments: [String],
    currentDirectoryURL: URL? = nil,
    timeout: TimeInterval,
    commandDescription: String
) throws -> ExternalCommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectoryURL
    process.environment = processEnvironmentWithoutBytecode()

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    let output = ExternalCommandOutputCollector(stdout: stdout, stderr: stderr)
    output.start()
    defer { output.stop() }
    try waitForProcessExit(process, timeout: timeout, commandDescription: commandDescription)

    return output.stopAndResult(terminationStatus: process.terminationStatus)
}

private func executeExternalCommandAsync(
    arguments: [String],
    currentDirectoryURL: URL? = nil,
    timeout: TimeInterval,
    commandDescription: String
) async throws -> ExternalCommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectoryURL
    process.environment = processEnvironmentWithoutBytecode()

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    let output = ExternalCommandOutputCollector(stdout: stdout, stderr: stderr)
    output.start()
    return try await withTaskCancellationHandler(operation: {
        let terminationStream = AsyncStream<Int32> { continuation in
            process.terminationHandler = { proc in
                continuation.yield(proc.terminationStatus)
                continuation.finish()
            }
        }
        try process.run()

        defer { output.stop() }
        return try await withThrowingTaskGroup(of: ExternalCommandResult.self) { group in
            group.addTask {
                var status = process.terminationStatus
                for await streamedStatus in terminationStream {
                    status = streamedStatus
                    break
                }
                return output.stopAndResult(terminationStatus: status)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                terminateExternalProcess(process)
                throw ExternalCommandError.timedOut(command: commandDescription, timeout: timeout)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }, onCancel: {
        terminateExternalProcess(process)
    })
}

private func bundledResourceBaseURL() -> URL? {
    Bundle.main.resourceURL
}

private func normalizedFileURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
}

private func isContained(_ candidate: URL, in roots: [URL]) -> Bool {
    let normalizedCandidate = normalizedFileURL(candidate)
    return roots.contains { root in
        let normalizedRoot = normalizedFileURL(root)
        if normalizedCandidate.path == normalizedRoot.path {
            return true
        }
        let rootPrefix = normalizedRoot.path.hasSuffix("/") ? normalizedRoot.path : normalizedRoot.path + "/"
        return normalizedCandidate.path.hasPrefix(rootPrefix)
    }
}

private func isAllowedEmbeddedNavigationURL(_ url: URL?) -> Bool {
    guard let url else { return true }
    if url.isFileURL {
        guard let baseURL = bundledResourceBaseURL() else { return false }
        return isContained(url, in: [baseURL])
    }
    switch url.scheme?.lowercased() {
    case "about", "app-wiki":
        return true
    default:
        return false
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

struct KnowledgeDocument: Identifiable {
    let title: String
    let path: String
    let displayPath: String
    let inlineContent: String

    init(title: String, path: String, displayPath: String? = nil, inlineContent: String = "") {
        self.title = title
        self.path = path
        self.displayPath = displayPath ?? path
        self.inlineContent = inlineContent
    }

    var id: String { path }

    var isVirtual: Bool {
        !inlineContent.isEmpty || path.hasPrefix("virtual://")
    }
}

struct SourceSummaryCardModel: Identifiable {
    let title: String
    let detail: String
    let actionTitle: String
    let actionSymbol: String
    let action: () -> Void

    var id: String { title }
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

struct QuestionProfileDocument: Codable {
    let title: String
    let summary: String
    let preview: String
    let content: String
    let path: String
    let updatedAt: String
    let isAvailable: Bool
    let isPlaceholder: Bool

    enum CodingKeys: String, CodingKey {
        case title
        case summary
        case preview
        case content
        case path
        case updatedAt = "updated_at"
        case isAvailable = "is_available"
        case isPlaceholder = "is_placeholder"
    }
}

struct UserQuestionProfileState: Codable {
    let snapshotCount: Int
    let workspaceSnapshotCount: Int
    let globalProfile: QuestionProfileDocument
    let workspaceProfile: QuestionProfileDocument

    enum CodingKeys: String, CodingKey {
        case snapshotCount = "snapshot_count"
        case workspaceSnapshotCount = "workspace_snapshot_count"
        case globalProfile = "global_profile"
        case workspaceProfile = "workspace_profile"
    }
}

struct ProjectUpdateLog: Codable {
    let title: String
    let summary: String
    let preview: String
    let content: String
    let updatedAt: String
    let preferredLanguage: String
    let sourceTaskCount: Int
    let sourceRecordCount: Int
    let isAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case title
        case summary
        case preview
        case content
        case updatedAt = "updated_at"
        case preferredLanguage = "preferred_language"
        case sourceTaskCount = "source_task_count"
        case sourceRecordCount = "source_record_count"
        case isAvailable = "is_available"
    }
}

struct KnowledgeBaseOverview: Codable {
    let vaultRoot: String
    let isConfigured: Bool
    let isNormalized: Bool
    let totalProjects: Int
    let activeWorkspaces: Int
    let legacySourceCount: Int
    let wikiPageCount: Int
    let graphNodeCount: Int
    let graphEdgeCount: Int
    let lastBuiltAt: String
    let summary: String

    enum CodingKeys: String, CodingKey {
        case vaultRoot = "vault_root"
        case isConfigured = "is_configured"
        case isNormalized = "is_normalized"
        case totalProjects = "total_projects"
        case activeWorkspaces = "active_workspaces"
        case legacySourceCount = "legacy_source_count"
        case wikiPageCount = "wiki_page_count"
        case graphNodeCount = "graph_node_count"
        case graphEdgeCount = "graph_edge_count"
        case lastBuiltAt = "last_built_at"
        case summary
    }
}

struct KnowledgeProjectSummary: Codable, Identifiable {
    let name: String
    let slug: String
    let workspace: String
    let source: String
    let lifecyclePhase: String
    let runtime: String
    let lastUpdated: String
    let focus: String
    let pageCount: Int
    let hasWiki: Bool
    let wikiRoot: String

    var id: String { slug.isEmpty ? workspace : slug }

    enum CodingKeys: String, CodingKey {
        case name
        case slug
        case workspace
        case source
        case lifecyclePhase = "lifecycle_phase"
        case runtime
        case lastUpdated = "last_updated"
        case focus
        case pageCount = "page_count"
        case hasWiki = "has_wiki"
        case wikiRoot = "wiki_root"
    }
}

struct LegacySourceEntry: Codable, Identifiable {
    let name: String
    let path: String
    let classification: String
    let status: String

    var id: String { path }
}

struct KnowledgeGraphNode: Codable, Identifiable {
    let id: String
    let label: String
    let kind: String
    let path: String
    let scope: String
    let workspace: String
    let status: String
}

struct KnowledgeGraphEdge: Codable, Identifiable {
    let source: String
    let target: String
    let kind: String

    var id: String { "\(source)->\(target):\(kind)" }
}

struct KnowledgeGraphMeta: Codable {
    let graphPath: String
    let nodeCount: Int
    let edgeCount: Int
    let updatedAt: String
    let isAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case graphPath = "graph_path"
        case nodeCount = "node_count"
        case edgeCount = "edge_count"
        case updatedAt = "updated_at"
        case isAvailable = "is_available"
    }
}

struct ObserveRollup: Codable, Identifiable {
    let projectName: String
    let slug: String
    let workspaceCount: Int
    let latestRuntime: String
    let latestSyncStatus: String
    let attentionState: String
    let latestActivity: String
    let latestFocus: String
    let openLoopCount: Int
    let decisionCount: Int
    let learningCount: Int
    let workspaces: [String]

    var id: String { slug.isEmpty ? projectName : slug }

    enum CodingKeys: String, CodingKey {
        case projectName = "project_name"
        case slug
        case workspaceCount = "workspace_count"
        case latestRuntime = "latest_runtime"
        case latestSyncStatus = "latest_sync_status"
        case attentionState = "attention_state"
        case latestActivity = "latest_activity"
        case latestFocus = "latest_focus"
        case openLoopCount = "open_loop_count"
        case decisionCount = "decision_count"
        case learningCount = "learning_count"
        case workspaces
    }
}

struct SelectedScope: Codable {
    let kind: String
    let label: String
    let projectName: String
    let workspace: String

    enum CodingKeys: String, CodingKey {
        case kind
        case label
        case projectName = "project_name"
        case workspace
    }
}

struct DashboardSnapshot: Codable {
    let workspace: String
    let workspaceMode: String
    let snapshotMode: String
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
    let userQuestionProfile: UserQuestionProfileState
    let projectUpdateLog: ProjectUpdateLog
    let knowledgeBaseOverview: KnowledgeBaseOverview
    let knowledgeProjects: [KnowledgeProjectSummary]
    let legacySources: [LegacySourceEntry]
    let knowledgeGraphMeta: KnowledgeGraphMeta
    let knowledgeGraphNodes: [KnowledgeGraphNode]
    let knowledgeGraphEdges: [KnowledgeGraphEdge]
    let observeRollups: [ObserveRollup]
    let selectedScope: SelectedScope
    let includesProjectMemoryDetails: Bool
    let includesQuestionProfileContent: Bool
    let projectMemoryCounts: [String: Int]
    let projectMemoryRecords: [ProjectMemoryRecord]
    let projectMemoryLastUpdated: String
    let syncAuditSource: String
    let currentTaskHealth: TaskHealth
    let attentionState: String

    enum CodingKeys: String, CodingKey {
        case workspace
        case workspaceMode = "workspace_mode"
        case snapshotMode = "snapshot_mode"
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
        case userQuestionProfile = "user_question_profile"
        case projectUpdateLog = "project_update_log"
        case knowledgeBaseOverview = "knowledge_base_overview"
        case knowledgeProjects = "knowledge_projects"
        case legacySources = "legacy_sources"
        case knowledgeGraphMeta = "knowledge_graph_meta"
        case knowledgeGraphNodes = "knowledge_graph_nodes"
        case knowledgeGraphEdges = "knowledge_graph_edges"
        case observeRollups = "observe_rollups"
        case selectedScope = "selected_scope"
        case includesProjectMemoryDetails = "includes_project_memory_details"
        case includesQuestionProfileContent = "includes_question_profile_content"
        case projectMemoryCounts = "project_memory_counts"
        case projectMemoryRecords = "project_memory_records"
        case projectMemoryLastUpdated = "project_memory_last_updated"
        case syncAuditSource = "sync_audit_source"
        case currentTaskHealth = "current_task_health"
        case attentionState = "attention_state"
    }
}

let defaultGlobalRoot = appHomeDirectory
    .appendingPathComponent("AgentSharedFabric")
    .appendingPathComponent("global-agent-fabric")
    .path
let defaultObsidianVaultRoot = appHomeDirectory
    .appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Memory")
    .path
let defaultObsidianRawSourcesDir = "00 Raw Sources/Agent Chats"
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

enum DashboardSurfaceMode: String, CaseIterable, Identifiable {
    case graph
    case chat
    case sources
    case wiki
    case observe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .graph:
            return "Graph"
        case .chat:
            return "Chat"
        case .sources:
            return "Sources"
        case .wiki:
            return "Wiki"
        case .observe:
            return "Observe"
        }
    }

    var subtitle: String {
        switch self {
        case .graph:
            return "Vault overview, graph focus, and primary actions"
        case .chat:
            return "Gemini knowledge-base Q&A for the selected scope"
        case .sources:
            return "Raw sources, imports, and capture actions"
        case .wiki:
            return "Maintained pages and wiki outputs"
        case .observe:
            return "Live sync, phase, and memory observability"
        }
    }
}

enum KnowledgeScopeMode: String, CaseIterable, Identifiable {
    case allVault
    case project
    case workspace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allVault:
            return "All Vault"
        case .project:
            return "Project"
        case .workspace:
            return "Workspace"
        }
    }
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
        static let obsidianVaultRoot = "shared_fabric_dashboard.obsidian_vault_root"
        static let obsidianChatHistoryOutputDir = "shared_fabric_dashboard.obsidian_chat_history_output_dir"
        static let surfaceMode = "shared_fabric_dashboard.surface_mode"
        static let scopeMode = "shared_fabric_dashboard.scope_mode"
        static let geminiChatScopeMode = "shared_fabric_dashboard.gemini_chat_scope_mode"
        static let showQuestionProfile = "shared_fabric_dashboard.show_question_profile"
        static let showProjectMemory = "shared_fabric_dashboard.show_project_memory"
        static let showRecentActivity = "shared_fabric_dashboard.show_recent_activity"
        static let showGraphPageNodes = "shared_fabric_dashboard.show_graph_page_nodes"
        static let showGraphSourceNodes = "shared_fabric_dashboard.show_graph_source_nodes"
        static let pinnedProjectKeys = "shared_fabric_dashboard.pinned_project_keys"
        static let showPinnedProjectsOnly = "shared_fabric_dashboard.show_pinned_projects_only"
    }

    private let defaults: UserDefaults
    private let forcedGlobalRootOverride: String?
    private let forcedObsidianVaultRoot: String?
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

    @Published var obsidianVaultRoot: String {
        didSet { persistIfNeeded() }
    }

    @Published var obsidianChatHistoryOutputDir: String {
        didSet { persistIfNeeded() }
    }

    @Published var surfaceMode: DashboardSurfaceMode {
        didSet { persistIfNeeded() }
    }

    @Published var scopeMode: KnowledgeScopeMode {
        didSet { persistIfNeeded() }
    }

    @Published var geminiChatScopeMode: KnowledgeScopeMode {
        didSet { persistIfNeeded() }
    }

    @Published var showQuestionProfile: Bool {
        didSet { persistIfNeeded() }
    }

    @Published var showProjectMemory: Bool {
        didSet { persistIfNeeded() }
    }

    @Published var showRecentActivity: Bool {
        didSet { persistIfNeeded() }
    }

    @Published var showGraphPageNodes: Bool {
        didSet { persistIfNeeded() }
    }

    @Published var showGraphSourceNodes: Bool {
        didSet { persistIfNeeded() }
    }

    @Published var pinnedProjectKeys: [String] {
        didSet { persistIfNeeded() }
    }

    @Published var showPinnedProjectsOnly: Bool {
        didSet { persistIfNeeded() }
    }

    init(config: DashboardConfig, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let trimmedForcedGlobalRoot = config.initialGlobalRoot?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.forcedGlobalRootOverride = (trimmedForcedGlobalRoot?.isEmpty == false) ? trimmedForcedGlobalRoot : nil
        let trimmedForcedVaultRoot = config.initialVaultRoot?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.forcedObsidianVaultRoot = (trimmedForcedVaultRoot?.isEmpty == false) ? trimmedForcedVaultRoot : nil
        self.workspaceMode = .auto
        self.pinnedWorkspace = ""
        self.refreshInterval = 2.0
        self.globalRootOverride = ""
        self.obsidianVaultRoot = ""
        self.obsidianChatHistoryOutputDir = defaultObsidianRawSourcesDir
        self.surfaceMode = .graph
        self.scopeMode = .workspace
        self.geminiChatScopeMode = .workspace
        self.showQuestionProfile = true
        self.showProjectMemory = true
        self.showRecentActivity = true
        self.showGraphPageNodes = false
        self.showGraphSourceNodes = false
        self.pinnedProjectKeys = []
        self.showPinnedProjectsOnly = false

        if let storedMode = defaults.string(forKey: Keys.workspaceMode), let mode = WorkspaceMode(rawValue: storedMode) {
            workspaceMode = mode
        }
        if let storedSurface = defaults.string(forKey: Keys.surfaceMode), let mode = DashboardSurfaceMode(rawValue: storedSurface) {
            surfaceMode = mode
        }
        if let storedScope = defaults.string(forKey: Keys.scopeMode), let mode = KnowledgeScopeMode(rawValue: storedScope) {
            scopeMode = mode
        }
        if let storedGeminiScope = defaults.string(forKey: Keys.geminiChatScopeMode), let mode = KnowledgeScopeMode(rawValue: storedGeminiScope) {
            geminiChatScopeMode = mode
        }
        pinnedWorkspace = defaults.string(forKey: Keys.pinnedWorkspace) ?? ""
        let storedRefresh = defaults.double(forKey: Keys.refreshInterval)
        refreshInterval = storedRefresh > 0 ? storedRefresh : 2.0
        globalRootOverride = defaults.string(forKey: Keys.globalRootOverride) ?? ""
        obsidianVaultRoot = defaults.string(forKey: Keys.obsidianVaultRoot) ?? ""
        let storedOutputDir = defaults.string(forKey: Keys.obsidianChatHistoryOutputDir) ?? ""
        obsidianChatHistoryOutputDir = storedOutputDir.isEmpty ? defaultObsidianRawSourcesDir : storedOutputDir
        if defaults.object(forKey: Keys.showQuestionProfile) != nil {
            showQuestionProfile = defaults.bool(forKey: Keys.showQuestionProfile)
        }
        if defaults.object(forKey: Keys.showProjectMemory) != nil {
            showProjectMemory = defaults.bool(forKey: Keys.showProjectMemory)
        }
        if defaults.object(forKey: Keys.showRecentActivity) != nil {
            showRecentActivity = defaults.bool(forKey: Keys.showRecentActivity)
        }
        if defaults.object(forKey: Keys.showGraphPageNodes) != nil {
            showGraphPageNodes = defaults.bool(forKey: Keys.showGraphPageNodes)
        }
        if defaults.object(forKey: Keys.showGraphSourceNodes) != nil {
            showGraphSourceNodes = defaults.bool(forKey: Keys.showGraphSourceNodes)
        }
        if let storedPinnedProjects = defaults.array(forKey: Keys.pinnedProjectKeys) as? [String] {
            pinnedProjectKeys = storedPinnedProjects
        }
        if defaults.object(forKey: Keys.showPinnedProjectsOnly) != nil {
            showPinnedProjectsOnly = defaults.bool(forKey: Keys.showPinnedProjectsOnly)
        }

        if let initialWorkspace = config.initialWorkspace, !initialWorkspace.isEmpty {
            workspaceMode = .pinned
            pinnedWorkspace = initialWorkspace
        }
        if let forcedGlobalRootOverride {
            globalRootOverride = forcedGlobalRootOverride
        }
        if let forcedObsidianVaultRoot {
            obsidianVaultRoot = forcedObsidianVaultRoot
        } else if obsidianVaultRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           FileManager.default.fileExists(atPath: defaultObsidianVaultRoot)
        {
            obsidianVaultRoot = defaultObsidianVaultRoot
        }

        isLoading = false
        persistIfNeeded()
    }

    init(
        workspaceMode: WorkspaceMode,
        pinnedWorkspace: String,
        refreshInterval: Double,
        globalRootOverride: String,
        obsidianVaultRoot: String,
        obsidianChatHistoryOutputDir: String,
        surfaceMode: DashboardSurfaceMode,
        scopeMode: KnowledgeScopeMode,
        geminiChatScopeMode: KnowledgeScopeMode,
        showQuestionProfile: Bool,
        showProjectMemory: Bool,
        showRecentActivity: Bool,
        showGraphPageNodes: Bool,
        showGraphSourceNodes: Bool,
        pinnedProjectKeys: [String],
        showPinnedProjectsOnly: Bool,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.forcedGlobalRootOverride = nil
        self.forcedObsidianVaultRoot = nil
        self.workspaceMode = workspaceMode
        self.pinnedWorkspace = pinnedWorkspace
        self.refreshInterval = max(1.0, min(refreshInterval, 60.0))
        self.globalRootOverride = globalRootOverride
        self.obsidianVaultRoot = obsidianVaultRoot
        self.obsidianChatHistoryOutputDir = obsidianChatHistoryOutputDir.isEmpty ? defaultObsidianRawSourcesDir : obsidianChatHistoryOutputDir
        self.surfaceMode = surfaceMode
        self.scopeMode = scopeMode
        self.geminiChatScopeMode = geminiChatScopeMode
        self.showQuestionProfile = showQuestionProfile
        self.showProjectMemory = showProjectMemory
        self.showRecentActivity = showRecentActivity
        self.showGraphPageNodes = showGraphPageNodes
        self.showGraphSourceNodes = showGraphSourceNodes
        self.pinnedProjectKeys = pinnedProjectKeys
        self.showPinnedProjectsOnly = showPinnedProjectsOnly
        isLoading = false
    }

    func cloned() -> DashboardPreferences {
        DashboardPreferences(
            workspaceMode: workspaceMode,
            pinnedWorkspace: pinnedWorkspace,
            refreshInterval: refreshInterval,
            globalRootOverride: globalRootOverride,
            obsidianVaultRoot: obsidianVaultRoot,
            obsidianChatHistoryOutputDir: obsidianChatHistoryOutputDir,
            surfaceMode: surfaceMode,
            scopeMode: scopeMode,
            geminiChatScopeMode: geminiChatScopeMode,
            showQuestionProfile: showQuestionProfile,
            showProjectMemory: showProjectMemory,
            showRecentActivity: showRecentActivity,
            showGraphPageNodes: showGraphPageNodes,
            showGraphSourceNodes: showGraphSourceNodes,
            pinnedProjectKeys: pinnedProjectKeys,
            showPinnedProjectsOnly: showPinnedProjectsOnly,
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
        if let forcedGlobalRootOverride {
            globalRootOverride = forcedGlobalRootOverride
        } else {
            globalRootOverride = config.initialGlobalRoot ?? ""
        }
        if let forcedObsidianVaultRoot {
            obsidianVaultRoot = forcedObsidianVaultRoot
        } else {
            obsidianVaultRoot = FileManager.default.fileExists(atPath: defaultObsidianVaultRoot) ? defaultObsidianVaultRoot : ""
        }
        obsidianChatHistoryOutputDir = defaultObsidianRawSourcesDir
        surfaceMode = .graph
        scopeMode = .workspace
        geminiChatScopeMode = .workspace
        showQuestionProfile = true
        showProjectMemory = true
        showRecentActivity = true
        showGraphPageNodes = false
        showGraphSourceNodes = false
        pinnedProjectKeys = []
        showPinnedProjectsOnly = false
    }

    var effectiveWorkspaceArgument: String? {
        guard workspaceMode == .pinned else { return nil }
        let trimmed = pinnedWorkspace.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var effectiveGlobalRoot: String {
        if let forcedGlobalRootOverride {
            return forcedGlobalRootOverride
        }
        let trimmed = globalRootOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultGlobalRoot : trimmed
    }

    var effectiveObsidianVaultRoot: String? {
        if let forcedObsidianVaultRoot {
            return forcedObsidianVaultRoot
        }
        let trimmed = obsidianVaultRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var effectiveObsidianChatHistoryOutputDir: String {
        let trimmed = obsidianChatHistoryOutputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultObsidianRawSourcesDir : trimmed
    }

    func isProjectPinned(_ key: String) -> Bool {
        pinnedProjectKeys.contains(key)
    }

    func togglePinnedProject(_ key: String) {
        guard !key.isEmpty else { return }
        if let index = pinnedProjectKeys.firstIndex(of: key) {
            pinnedProjectKeys.remove(at: index)
            if pinnedProjectKeys.isEmpty {
                showPinnedProjectsOnly = false
            }
        } else {
            pinnedProjectKeys.append(key)
        }
    }

    private func persistIfNeeded() {
        guard !isLoading else { return }
        defaults.set(workspaceMode.rawValue, forKey: Keys.workspaceMode)
        defaults.set(pinnedWorkspace, forKey: Keys.pinnedWorkspace)
        defaults.set(refreshInterval, forKey: Keys.refreshInterval)
        if forcedGlobalRootOverride == nil {
            defaults.set(globalRootOverride, forKey: Keys.globalRootOverride)
        }
        if forcedObsidianVaultRoot == nil {
            defaults.set(obsidianVaultRoot, forKey: Keys.obsidianVaultRoot)
        }
        defaults.set(effectiveObsidianChatHistoryOutputDir, forKey: Keys.obsidianChatHistoryOutputDir)
        defaults.set(surfaceMode.rawValue, forKey: Keys.surfaceMode)
        defaults.set(scopeMode.rawValue, forKey: Keys.scopeMode)
        defaults.set(geminiChatScopeMode.rawValue, forKey: Keys.geminiChatScopeMode)
        defaults.set(showQuestionProfile, forKey: Keys.showQuestionProfile)
        defaults.set(showProjectMemory, forKey: Keys.showProjectMemory)
        defaults.set(showRecentActivity, forKey: Keys.showRecentActivity)
        defaults.set(showGraphPageNodes, forKey: Keys.showGraphPageNodes)
        defaults.set(showGraphSourceNodes, forKey: Keys.showGraphSourceNodes)
        defaults.set(pinnedProjectKeys, forKey: Keys.pinnedProjectKeys)
        defaults.set(showPinnedProjectsOnly, forKey: Keys.showPinnedProjectsOnly)
    }
}

final class DashboardViewModel: ObservableObject {
    private struct ActiveOperation {
        let id: String
        let title: String
        let category: String
        let commandPreview: String
        let workspace: String
    }

    private static let operationTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let maxOperationLogEntries = 80

    @Published var snapshot: DashboardSnapshot?
    @Published var errorMessage = ""
    @Published var refreshToken = UUID()
    @Published var isBusy = false
    @Published var operationStatus = ""
    @Published var operationLogEntries: [OperationLogEntry] = []

    private var activeOperation: ActiveOperation?

    func apply(snapshot: DashboardSnapshot) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
            self.snapshot = snapshot
            errorMessage = ""
            refreshToken = UUID()
        }
    }

    func apply(error: Error) {
        if let activeOperation {
            failOperation(activeOperation.id, error: error)
            return
        }
        if error is CancellationError {
            recordOperation(
                title: "Operation cancelled",
                detail: "A background task was cancelled before it completed.",
                status: .cancelled
            )
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            errorMessage = error.localizedDescription
            refreshToken = UUID()
        }
        recordOperation(
            title: "Operation failed",
            detail: error.localizedDescription,
            status: .failed
        )
    }

    @discardableResult
    func beginOperation(
        _ status: String,
        detail: String = "",
        commandPreview: String = "",
        workspace: String = "",
        category: String = "Runtime"
    ) -> String {
        if let activeOperation {
            finishOperation(activeOperation.id, outcome: .cancelled, detail: "Superseded by \(status).")
        }
        let operationID = UUID().uuidString
        let entry = OperationLogEntry(
            id: operationID,
            timestamp: Self.operationTimestampFormatter.string(from: Date()),
            category: category,
            title: status,
            detail: detail,
            status: .running,
            commandPreview: commandPreview,
            workspace: workspace
        )
        withAnimation(.easeInOut(duration: 0.18)) {
            isBusy = true
            operationStatus = status
            errorMessage = ""
            operationLogEntries.insert(entry, at: 0)
            trimOperationLogIfNeeded()
        }
        activeOperation = ActiveOperation(
            id: operationID,
            title: status,
            category: category,
            commandPreview: commandPreview,
            workspace: workspace
        )
        return operationID
    }

    func endOperation() {
        if let activeOperation {
            finishOperation(activeOperation.id)
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            isBusy = false
        }
    }

    func finishOperation(_ operationID: String, outcome: OperationLogStatus = .completed, detail: String = "") {
        let resolvedDetail: String
        if detail.isEmpty {
            resolvedDetail = switch outcome {
            case .running:
                ""
            case .completed:
                "Operation completed successfully."
            case .failed:
                "Operation failed."
            case .cancelled:
                "Operation cancelled."
            }
        } else {
            resolvedDetail = detail
        }

        updateOperationEntry(operationID) { entry in
            OperationLogEntry(
                id: entry.id,
                timestamp: Self.operationTimestampFormatter.string(from: Date()),
                category: entry.category,
                title: entry.title,
                detail: resolvedDetail,
                status: outcome,
                commandPreview: entry.commandPreview,
                workspace: entry.workspace
            )
        }

        if activeOperation?.id == operationID {
            withAnimation(.easeInOut(duration: 0.18)) {
                isBusy = false
            }
            activeOperation = nil
        }
    }

    func failOperation(_ operationID: String, error: Error) {
        if error is CancellationError {
            finishOperation(operationID, outcome: .cancelled, detail: "Operation cancelled before completion.")
            return
        }
        finishOperation(operationID, outcome: .failed, detail: error.localizedDescription)
        withAnimation(.easeInOut(duration: 0.2)) {
            errorMessage = error.localizedDescription
            refreshToken = UUID()
        }
    }

    func recordOperation(
        title: String,
        detail: String,
        status: OperationLogStatus,
        commandPreview: String = "",
        workspace: String = "",
        category: String = "Runtime"
    ) {
        let entry = OperationLogEntry(
            id: UUID().uuidString,
            timestamp: Self.operationTimestampFormatter.string(from: Date()),
            category: category,
            title: title,
            detail: detail,
            status: status,
            commandPreview: commandPreview,
            workspace: workspace
        )
        withAnimation(.easeInOut(duration: 0.18)) {
            operationLogEntries.insert(entry, at: 0)
            trimOperationLogIfNeeded()
        }
    }

    private func updateOperationEntry(_ operationID: String, transform: (OperationLogEntry) -> OperationLogEntry) {
        guard let index = operationLogEntries.firstIndex(where: { $0.id == operationID }) else {
            if let activeOperation, activeOperation.id == operationID {
                recordOperation(
                    title: activeOperation.title,
                    detail: "Operation state changed but the original log entry was unavailable.",
                    status: .failed,
                    commandPreview: activeOperation.commandPreview,
                    workspace: activeOperation.workspace,
                    category: activeOperation.category
                )
            }
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            operationLogEntries[index] = transform(operationLogEntries[index])
        }
    }

    private func trimOperationLogIfNeeded() {
        if operationLogEntries.count > Self.maxOperationLogEntries {
            operationLogEntries.removeSubrange(Self.maxOperationLogEntries...)
        }
    }
}

final class GeminiChatViewModel: ObservableObject {
    @Published var prompt = ""
    @Published var response = ""
    @Published var status = "Ready"
    @Published var isRunning = false

    func begin(scope: KnowledgeScopeMode) {
        isRunning = true
        status = "Running Gemini for \(scope.title)…"
    }

    func finish(response: String) {
        self.response = response
        self.status = "Complete"
        self.isRunning = false
    }

    func fail(_ error: String) {
        response = error
        status = "Failed"
        isRunning = false
    }

    func clear() {
        prompt = ""
        response = ""
        status = "Ready"
        isRunning = false
    }
}

final class AuxiliaryPanelState: ObservableObject {
    @Published var showObservePanel = false
    @Published var showGeminiPanel = false
}

final class EmbeddedShellSession: ObservableObject {
    @Published var transcript = ""
    @Published var prompt = ""
    @Published var status = "Shell offline"
    @Published var isRunning = false

    let workingDirectory: String

    private var childPID: pid_t?
    private var processMonitor: DispatchSourceProcess?
    private var masterHandle: FileHandle?
    private var pendingChunks: [Data] = []
    private var outputSink: ((Data) -> Void)?

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
    }

    func startIfNeeded() {
        guard childPID == nil else { return }

        var masterFD: Int32 = -1
        var windowSize = winsize(ws_row: 38, ws_col: 140, ws_xpixel: 0, ws_ypixel: 0)

        let pid = forkpty(&masterFD, nil, nil, &windowSize)
        guard pid >= 0 else {
            status = "Shell unavailable"
            transcript.append("Failed to allocate PTY for embedded shell.\n")
            return
        }

        if pid == 0 {
            chdir(workingDirectory)
            setenv("TERM", "xterm-256color", 1)
            setenv("COLORTERM", "truecolor", 1)
            setenv("TERM_PROGRAM", "Apple_Terminal", 1)
            setenv("TERM_PROGRAM_VERSION", "510", 1)
            setenv("CLICOLOR", "1", 1)
            setenv("CLICOLOR_FORCE", "1", 1)
            setenv("LANG", "en_US.UTF-8", 1)
            setenv("LC_ALL", "en_US.UTF-8", 1)
            var argv: [UnsafeMutablePointer<CChar>?] = [
                strdup("zsh"),
                strdup("-il"),
                nil,
            ]
            execv("/bin/zsh", &argv)
            _exit(127)
        }

        let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        masterHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                Task { @MainActor [weak self] in
                    self?.finalizeTermination(status: "Shell exited")
                }
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.transcript.append(text)
                self.isRunning = true
                self.status = "Shell ready"
                if let sink = self.outputSink {
                    sink(data)
                } else {
                    self.pendingChunks.append(data)
                }
            }
        }

        let monitor = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        monitor.setEventHandler { [weak self] in
            guard let self else { return }
            var statusCode: Int32 = 0
            waitpid(pid, &statusCode, WNOHANG)
            let code = (statusCode >> 8) & 0xff
            self.finalizeTermination(status: code == 0 ? "Shell exited" : "Shell exited (\(code))")
        }
        monitor.resume()

        self.childPID = pid
        self.masterHandle = masterHandle
        self.processMonitor = monitor
        status = "Shell ready"
        isRunning = true
    }

    func submitCurrentPrompt() {
        let command = prompt.trimmingCharacters(in: .newlines)
        guard !command.isEmpty else { return }
        send(command: command)
        prompt = ""
    }

    func send(command: String) {
        startIfNeeded()
        guard masterHandle != nil else { return }
        let payload = command.hasSuffix("\n") ? command : command + "\n"
        sendRaw(data: Data(payload.utf8))
    }

    func sendRaw(text: String) {
        sendRaw(data: Data(text.utf8))
    }

    func sendRaw(data: Data) {
        startIfNeeded()
        guard let input = masterHandle else { return }
        do {
            try input.write(contentsOf: data)
        } catch {
            Task { @MainActor in
                self.transcript.append("\n[write failed] \(error.localizedDescription)\n")
                self.status = "Write failed"
            }
        }
    }

    func attachOutputSink(_ sink: @escaping (Data) -> Void, replayTranscript: Bool = false) {
        outputSink = sink
        if replayTranscript {
            if !transcript.isEmpty {
                sink(Data(transcript.utf8))
            }
            pendingChunks.removeAll(keepingCapacity: false)
            return
        }
        if !pendingChunks.isEmpty {
            let queued = pendingChunks
            pendingChunks.removeAll(keepingCapacity: false)
            queued.forEach { sink($0) }
        }
    }

    func detachOutputSink() {
        outputSink = nil
    }

    func resize(cols: Int, rows: Int) {
        guard let masterHandle else { return }
        var size = winsize(
            ws_row: UInt16(max(2, rows)),
            ws_col: UInt16(max(10, cols)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(masterHandle.fileDescriptor, TIOCSWINSZ, &size)
    }

    func clearTranscript() {
        transcript = ""
    }

    func stop() {
        masterHandle?.readabilityHandler = nil
        if let childPID {
            kill(childPID, SIGTERM)
        }
        processMonitor?.cancel()
        processMonitor = nil
        childPID = nil
        masterHandle = nil
        pendingChunks.removeAll(keepingCapacity: false)
        outputSink = nil
        isRunning = false
        status = "Shell offline"
    }

    private func finalizeTermination(status: String) {
        masterHandle?.readabilityHandler = nil
        processMonitor?.cancel()
        processMonitor = nil
        childPID = nil
        masterHandle = nil
        pendingChunks.removeAll(keepingCapacity: false)
        outputSink = nil
        isRunning = false
        self.status = status
    }
}

struct EmbeddedTerminalView: NSViewRepresentable {
    @ObservedObject var session: EmbeddedShellSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "terminalInput")
        contentController.add(context.coordinator, name: "terminalResize")
        contentController.add(context.coordinator, name: "terminalReady")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.bind(webView: webView)

        if let indexURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "terminal") {
            let readAccessURL = indexURL.deletingLastPathComponent()
            webView.loadFileURL(indexURL, allowingReadAccessTo: readAccessURL)
        } else {
            webView.loadHTMLString("<html><body style='background:#090b10;color:white;font-family:monospace'>Missing terminal assets.</body></html>", baseURL: nil)
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.session = session
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var session: EmbeddedShellSession
        weak var webView: WKWebView?
        private var isReady = false

        init(session: EmbeddedShellSession) {
            self.session = session
        }

        func bind(webView: WKWebView) {
            self.webView = webView
        }

        func teardown() {
            session.detachOutputSink()
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "terminalInput")
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "terminalResize")
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "terminalReady")
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(isAllowedEmbeddedNavigationURL(navigationAction.request.url) ? .allow : .cancel)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "terminalInput":
                if let input = message.body as? String {
                    session.sendRaw(text: input)
                }
            case "terminalResize":
                if let payload = message.body as? [String: Any],
                   let cols = payload["cols"] as? Int,
                   let rows = payload["rows"] as? Int {
                    session.resize(cols: cols, rows: rows)
                }
            case "terminalReady":
                isReady = true
                webView?.evaluateJavaScript("window.sharedFabricTerminal && window.sharedFabricTerminal.clear();", completionHandler: nil)
                session.attachOutputSink({ [weak self] data in
                    self?.pushOutput(data)
                }, replayTranscript: true)
                session.startIfNeeded()
                webView?.evaluateJavaScript("window.sharedFabricTerminal && window.sharedFabricTerminal.focus();", completionHandler: nil)
            default:
                break
            }
        }

        private func pushOutput(_ data: Data) {
            guard isReady, let webView else { return }
            let base64 = data.base64EncodedString()
            let js = "window.sharedFabricTerminal && window.sharedFabricTerminal.receive('\(base64)');"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

struct KnowledgeGraphWebView: NSViewRepresentable {
    let html: String
    let onOpenPath: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenPath: onOpenPath)
    }

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "graphOpenNode")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.bind(webView: webView)
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: bundledResourceBaseURL())
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onOpenPath = onOpenPath
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            nsView.loadHTMLString(html, baseURL: bundledResourceBaseURL())
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onOpenPath: (String) -> Void
        weak var webView: WKWebView?
        var lastHTML: String

        init(onOpenPath: @escaping (String) -> Void) {
            self.onOpenPath = onOpenPath
            self.lastHTML = ""
        }

        func bind(webView: WKWebView) {
            self.webView = webView
        }

        func teardown() {
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "graphOpenNode")
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(isAllowedEmbeddedNavigationURL(navigationAction.request.url) ? .allow : .cancel)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "graphOpenNode" else { return }
            if let path = message.body as? String, !path.isEmpty {
                onOpenPath(path)
            }
        }
    }
}

struct WikiArticleWebView: NSViewRepresentable {
    let html: String
    let onNavigatePath: (String) -> Void
    let onOpenPath: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onNavigatePath: onNavigatePath, onOpenPath: onOpenPath)
    }

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "wikiNavigate")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.bind(webView: webView)
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: bundledResourceBaseURL())
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onNavigatePath = onNavigatePath
        context.coordinator.onOpenPath = onOpenPath
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            nsView.loadHTMLString(html, baseURL: bundledResourceBaseURL())
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onNavigatePath: (String) -> Void
        var onOpenPath: (String) -> Void
        weak var webView: WKWebView?
        var lastHTML: String

        init(onNavigatePath: @escaping (String) -> Void, onOpenPath: @escaping (String) -> Void) {
            self.onNavigatePath = onNavigatePath
            self.onOpenPath = onOpenPath
            self.lastHTML = ""
        }

        func bind(webView: WKWebView) {
            self.webView = webView
        }

        func teardown() {
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "wikiNavigate")
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(isAllowedEmbeddedNavigationURL(navigationAction.request.url) ? .allow : .cancel)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "wikiNavigate", let body = message.body as? [String: Any] else { return }
            let kind = String(describing: body["kind"] ?? "")
            let value = String(describing: body["value"] ?? "")
            guard !value.isEmpty else { return }
            if kind == "navigate" {
                onNavigatePath(value)
            } else {
                onOpenPath(value)
            }
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
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 1))
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
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.06),
                            Color.white.opacity(0.03),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.14), radius: 18, x: 0, y: 12)
    }
}

struct PressableChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.975 : 1.0)
            .opacity(configuration.isPressed ? 0.90 : 1.0)
            .brightness(configuration.isPressed ? 0.02 : 0.0)
            .shadow(color: Color.black.opacity(configuration.isPressed ? 0.08 : 0.0), radius: configuration.isPressed ? 6 : 0, x: 0, y: configuration.isPressed ? 2 : 0)
            .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.76, blendDuration: 0.08), value: configuration.isPressed)
    }
}

struct HoverChromeModifier: ViewModifier {
    let active: Bool
    let lift: CGFloat
    let glow: Double
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovering ? 1.012 : 1.0)
            .offset(y: isHovering ? -lift : 0)
            .shadow(
                color: Color.white.opacity(active ? max(glow, 0.10) : glow * 0.65),
                radius: isHovering ? 14 : 0,
                x: 0,
                y: isHovering ? 4 : 0
            )
            .animation(.easeOut(duration: 0.16), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
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
    let onChooseObsidianVaultRoot: () -> Void
    let onNormalizeObsidianVault: () -> Void
    let onProcessObsidianSources: () -> Void
    let onBuildAllProjectWikis: () -> Void
    let onExportAgentChatHistoryNow: () -> Void
    let onExportAllKnownWorkspaces: () -> Void
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

            VStack(alignment: .leading, spacing: 10) {
                Text("Obsidian Knowledge Base")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                HStack(spacing: 8) {
                    TextField(defaultObsidianVaultRoot, text: $preferences.obsidianVaultRoot)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: onChooseObsidianVaultRoot)
                }
                Text("External Input Folder")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                TextField(defaultObsidianRawSourcesDir, text: $preferences.obsidianChatHistoryOutputDir)
                    .textFieldStyle(.roundedBorder)
                Text("External tools may stage raw imports here, but this desktop app now focuses on normalization, source processing, wiki compilation, and review. Normalize Vault repairs structure, Process Sources generates a source-normalization snippet, and Build All generates a source-to-wiki compilation snippet for Gemini CLI.")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Normalize Vault", action: onNormalizeObsidianVault)
                        .disabled((preferences.effectiveObsidianVaultRoot ?? "").isEmpty)
                    Button("Process Sources Prompt", action: onProcessObsidianSources)
                        .disabled((preferences.effectiveObsidianVaultRoot ?? "").isEmpty)
                    Button("Build All Prompt", action: onBuildAllProjectWikis)
                        .disabled((preferences.effectiveObsidianVaultRoot ?? "").isEmpty)
                }
                if dataAcquisitionFeaturesEnabled {
                    HStack {
                        Spacer()
                        Button("Export All", action: onExportAllKnownWorkspaces)
                            .disabled((preferences.effectiveObsidianVaultRoot ?? "").isEmpty)
                        Button("Export Now", action: onExportAgentChatHistoryNow)
                            .disabled((preferences.effectiveObsidianVaultRoot ?? "").isEmpty)
                    }
                } else {
                    Text("Raw imports now arrive through external tooling. Fabric focuses on normalization, source processing, wiki compilation, graph review, and knowledge querying.")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Reset Defaults", action: onResetDefaults)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 520)
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
            return "\(origin) -> \(target)"
        case (false, true):
            return origin
        case (true, false):
            return target
        default:
            return "Cross-runtime"
        }
    }
}

enum DashboardModal: Identifiable {
    case syncTarget(String)
    case sourcePrompt(SourcePromptDocument)

    var id: String {
        switch self {
        case .syncTarget(let key):
            return "sync-\(key)"
        case .sourcePrompt(let document):
            return "source-prompt-\(document.id)"
        }
    }
}

struct SourcePromptDocument: Identifiable {
    let id = UUID().uuidString
    let title: String
    let workingDirectory: String
    let prompt: String
}

struct SourcePromptDetailView: View {
    let document: SourcePromptDocument
    let onClose: () -> Void

    private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(document.prompt, forType: .string)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.title)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(document.workingDirectory)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Copy Prompt") {
                    copyPrompt()
                }
                .buttonStyle(.borderedProminent)
                Button("Done", action: onClose)
            }

            ScrollView {
                Text(document.prompt)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.black.opacity(0.18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                    )
            }
        }
        .padding(20)
        .frame(width: 760, height: 620)
    }
}

struct QuestionProfileDetailView: View {
    let title: String
    let profile: QuestionProfileDocument
    let onOpenPath: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
                if !profile.path.isEmpty {
                    Button("Open Markdown") {
                        onOpenPath(profile.path)
                    }
                    .buttonStyle(.bordered)
                }
                Button("Done", action: onClose)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(profile.summary)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                if !profile.updatedAt.isEmpty {
                    Text("Updated \(profile.updatedAt)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                Text(profile.content.isEmpty ? "No compiled profile content is available yet." : profile.content)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(profile.content.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
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
        .padding(20)
        .frame(width: 660, height: 500)
    }
}

struct UpdateLogDetailView: View {
    let updateLog: ProjectUpdateLog
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(updateLog.title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
                Button("Done", action: onClose)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(updateLog.summary)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                HStack(spacing: 10) {
                    if !updateLog.updatedAt.isEmpty {
                        Text("Updated \(updateLog.updatedAt)")
                    }
                    Text("Language \(updateLog.preferredLanguage.uppercased())")
                    Text("Tasks \(updateLog.sourceTaskCount)")
                    Text("Records \(updateLog.sourceRecordCount)")
                }
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(updateLog.content.isEmpty ? "No compiled update-log content is available yet." : updateLog.content)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(updateLog.content.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
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
        .padding(20)
        .frame(width: 700, height: 520)
    }
}

struct OperationLogDetailView: View {
    @ObservedObject var viewModel: DashboardViewModel
    let onOpenSyncFolder: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Runtime Logs")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("\(viewModel.operationLogEntries.count) recorded operation(s)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Sync Folder", action: onOpenSyncFolder)
                    .buttonStyle(.bordered)
                Button("Done", action: onClose)
                    .buttonStyle(.borderedProminent)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if viewModel.operationLogEntries.isEmpty {
                        Text("No runtime operations have been recorded yet.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                    )
                            )
                    } else {
                        ForEach(viewModel.operationLogEntries) { entry in
                            operationLogCard(entry)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 760, height: 620)
    }

    private func operationLogCard(_ entry: OperationLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    Text("\(entry.timestamp) · \(entry.category)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                operationStatusBadge(entry.status)
            }

            if !entry.workspace.isEmpty {
                Text(entry.workspace)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !entry.detail.isEmpty {
                Text(entry.detail)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.94))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !entry.commandPreview.isEmpty {
                Text(entry.commandPreview)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.18))
                    )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func operationStatusBadge(_ status: OperationLogStatus) -> some View {
        let tint: Color = switch status {
        case .running:
            .cyan
        case .completed:
            .green
        case .failed:
            .red
        case .cancelled:
            .orange
        }
        return HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(status.title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

struct ObservePanelWindowView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var preferences: DashboardPreferences
    let onOpenProjectMemory: (String?) -> Void
    let onOpenUpdateLog: () -> Void
    let onOpenQuestionProfile: (String) -> Void
    let onOpenLogs: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.11, green: 0.12, blue: 0.16), Color(red: 0.08, green: 0.09, blue: 0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if let snapshot = viewModel.snapshot {
                GeometryReader { geometry in
                    let columnCount = observeColumnCount(for: geometry.size.width)
                    let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount)
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Activity")
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                    Text("Shared Fabric monitor for session health, phase progress, sync deltas, and memory readiness.")
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                Button(action: onOpenLogs) {
                                    Image(systemName: "list.bullet.rectangle")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Open runtime logs")
                            }
                            LazyVGrid(columns: columns, spacing: 12) {
                                activityPanelCard("Session") {
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack {
                                            Text("\(snapshot.runtime.uppercased()) · \(snapshot.lifecyclePhase)")
                                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                                .lineLimit(2)
                                            Spacer(minLength: 8)
                                            Capsule(style: .continuous)
                                                .fill(Color.white.opacity(0.08))
                                                .overlay(
                                                    Capsule(style: .continuous)
                                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                                )
                                                .frame(width: 62, height: 28)
                                                .overlay(
                                                    Text("MCP \(snapshot.activeMcpCount)")
                                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                                )
                                        }
                                        HStack(spacing: 8) {
                                            activityStatusChip("Boot", snapshot.currentTaskHealth.isBooted ? "OK" : "MISS", tint: snapshot.currentTaskHealth.isBooted ? .green : .orange)
                                            activityStatusChip("Sync", snapshot.currentTaskHealth.hasPostflightSync ? "OK" : "MISS", tint: snapshot.currentTaskHealth.hasPostflightSync ? .blue : .orange)
                                            activityStatusChip("Audit", snapshot.currentTaskHealth.hasExactPhase ? "EXACT" : "LOOSE", tint: snapshot.currentTaskHealth.hasExactPhase ? .cyan : .orange)
                                        }
                                    }
                                }

                                activityPanelCard("Phase") {
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack(spacing: 10) {
                                            ForEach(phaseOrder, id: \.self) { key in
                                                PhasePill(key: key, current: snapshot.sixStageCurrent, completed: snapshot.sixStageCompleted)
                                                    .frame(maxWidth: .infinity)
                                            }
                                        }
                                        Text(phaseLabels[snapshot.sixStageCurrent] ?? snapshot.sixStageCurrent.capitalized)
                                            .font(.system(size: 14, weight: .bold, design: .rounded))
                                    }
                                }

                                activityPanelCard("Sync Delta") {
                                    VStack(alignment: .leading, spacing: 10) {
                                        let orderedTargets = ["decision_log", "handoffs", "mempalace_records", "open_loops", "promoted_learnings", "receipts"]
                                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], spacing: 8) {
                                            ForEach(orderedTargets, id: \.self) { key in
                                                SyncMetricButton(
                                                    label: writeTargetLabels[key] ?? key,
                                                    value: snapshot.lastSyncDelta.writesCountByTarget[key] ?? 0,
                                                    action: { onOpenProjectMemory(key == "receipts" ? nil : key) }
                                                )
                                            }
                                        }
                                    }
                                }

                                activityPanelCard("Memory") {
                                    VStack(alignment: .leading, spacing: 10) {
                                        activityCounterRow("Records", "\(snapshot.projectMemoryRecords.count)")
                                        activityCounterRow("Tasks", "\(snapshot.recentTasks.count)")
                                        activityCounterRow("Question", preferences.showQuestionProfile ? (snapshot.userQuestionProfile.snapshotCount > 0 ? "ON" : "NONE") : "HIDE")
                                    }
                                }
                            }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(viewModel.errorMessage.isEmpty ? "Loading activity…" : viewModel.errorMessage)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
        }
    }

    private func activityPanelCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 136, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func activityStatusChip(_ title: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func activityCounterRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
        }
    }

    private func observeColumnCount(for width: CGFloat) -> Int {
        if width >= 1180 {
            return 4
        }
        if width >= 760 {
            return 2
        }
        return 1
    }
}

struct GeminiShellPanelView: View {
    @ObservedObject var session: EmbeddedShellSession
    let workingDirectory: String
    var body: some View {
        EmbeddedTerminalView(session: session)
            .background(Color.black)
            .ignoresSafeArea()
    }
}

struct DashboardRootView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var chatModel: GeminiChatViewModel
    @ObservedObject var auxiliaryPanels: AuxiliaryPanelState
    @ObservedObject var preferences: DashboardPreferences
    let relayWorkingDirectory: String
    let onRefresh: () -> Void
    let onOpenLogs: () -> Void
    let onOpenCurrentWorkspace: () -> Void
    let onOpenPath: (String) -> Void
    let onOpenSettings: () -> Void
    let onOpenSetup: () -> Void
    let onOpenProjectMemory: (String?) -> Void
    let onOpenQuestionProfile: (String) -> Void
    let onOpenUpdateLog: () -> Void
    let onFollowLatestWorkspace: () -> Void
    let onSelectWorkspace: (String) -> Void
    let onPreviousWorkspace: () -> Void
    let onNextWorkspace: () -> Void
    let onNormalizeVault: () -> Void
    let onProcessSources: () -> Void
    let onBuildAllProjectWikis: () -> Void
    let onRefreshSelectedScope: () -> Void
    let onExportCurrentChats: () -> Void
    let onExportAllChats: () -> Void
    let onSubmitGeminiQuery: () -> Void
    let onClearGeminiChat: () -> Void
    let onToggleObservePanel: () -> Void
    let onToggleGeminiPanel: () -> Void
    @State private var presentedModal: DashboardModal?
    @State private var showGraphControls = false
    @State private var selectedWikiDocumentPath = ""
    @State private var selectedSourceDocumentPath = ""
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.08, blue: 0.11),
                    Color(red: 0.09, green: 0.10, blue: 0.14),
                    Color(red: 0.05, green: 0.06, blue: 0.09),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            LinearGradient(
                colors: [
                    Color(red: 0.17, green: 0.22, blue: 0.35).opacity(0.45),
                    Color(red: 0.10, green: 0.14, blue: 0.24).opacity(0.10),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .center
            )
            .ignoresSafeArea()

            if let snapshot = viewModel.snapshot {
                HStack(spacing: 0) {
                    projectRail(snapshot: snapshot)
                    VStack(spacing: 0) {
                        chromeBar(snapshot: snapshot)
                        mainWorkbench(snapshot: snapshot)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.errorMessage.isEmpty ? "Loading Fabric…" : viewModel.errorMessage)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 860, maxWidth: .infinity, minHeight: 580, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: viewModel.refreshToken)
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: auxiliaryPanels.showObservePanel)
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: auxiliaryPanels.showGeminiPanel)
        .sheet(item: $presentedModal) { modal in
            if let snapshot = viewModel.snapshot {
                switch modal {
                case .syncTarget(let targetKey):
                    let label = writeTargetLabels[targetKey] ?? targetKey
                    SyncRecordsDetailView(
                        title: "\(label) Details",
                        records: snapshot.lastSyncDelta.records.filter { $0.target == targetKey },
                        onOpenPath: onOpenPath,
                        onClose: { presentedModal = nil }
                    )
                case .sourcePrompt(let document):
                    SourcePromptDetailView(
                        document: document,
                        onClose: { presentedModal = nil }
                    )
                }
            }
        }
    }

    private var sidebarSurfaceModes: [DashboardSurfaceMode] {
        [.graph, .wiki, .sources]
    }

    private func projectRail(snapshot: DashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sidebarSurfaceModes, id: \.self) { mode in
                    railSurfaceButton(mode)
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.06))

            Text("Global")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            Button {
                preferences.scopeMode = .allVault
                preferences.surfaceMode = .graph
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Obsidian Vault")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Spacer()
                        if preferences.scopeMode == .allVault {
                            Circle()
                                .fill(Color.cyan)
                                .frame(width: 7, height: 7)
                        }
                    }
                    Text(preferences.effectiveObsidianVaultRoot ?? "Vault not configured")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(preferences.scopeMode == .allVault ? Color.white.opacity(0.08) : Color.white.opacity(0.025))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(preferences.scopeMode == .allVault ? Color.white.opacity(0.10) : Color.clear, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(PressableChromeButtonStyle())

            HStack {
                Text("Projects")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                if !preferences.pinnedProjectKeys.isEmpty {
                    Button {
                        preferences.showPinnedProjectsOnly.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: preferences.showPinnedProjectsOnly ? "pin.fill" : "pin")
                                .font(.system(size: 9, weight: .semibold))
                            Text(preferences.showPinnedProjectsOnly ? "Pinned" : "All")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(preferences.showPinnedProjectsOnly ? Color.yellow : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(preferences.showPinnedProjectsOnly ? 0.10 : 0.04))
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(PressableChromeButtonStyle())
                    .help(preferences.showPinnedProjectsOnly ? "Show all projects" : "Show only pinned projects")
                }
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    let rollups = projectRailDisplayRollups(snapshot)
                    if rollups.isEmpty {
                        Text(preferences.showPinnedProjectsOnly ? "No pinned projects yet." : "No projects available.")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    } else {
                        ForEach(rollups) { rollup in
                            HStack(alignment: .top, spacing: 8) {
                                Button {
                                    selectProjectRollup(rollup)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(alignment: .top, spacing: 8) {
                                            Text(projectRailPrimaryTitle(rollup))
                                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                                .multilineTextAlignment(.leading)
                                            Spacer(minLength: 6)
                                            Text(relativeTimeLabel(rollup.latestActivity))
                                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(projectRailSecondaryText(rollup, snapshot: snapshot))
                                            .font(.system(size: 10, weight: .regular, design: .rounded))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(isRollupSelected(rollup, snapshot: snapshot) ? Color.white.opacity(0.09) : Color.clear)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                    .stroke(isRollupSelected(rollup, snapshot: snapshot) ? Color.white.opacity(0.10) : Color.clear, lineWidth: 1)
                                            )
                                    )
                                }
                                .buttonStyle(PressableChromeButtonStyle())

                                Button {
                                    preferences.togglePinnedProject(projectRailPinKey(rollup))
                                } label: {
                                    Image(systemName: preferences.isProjectPinned(projectRailPinKey(rollup)) ? "pin.fill" : "pin")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(preferences.isProjectPinned(projectRailPinKey(rollup)) ? Color.yellow : .secondary)
                                        .frame(width: 28, height: 28)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(Color.white.opacity(0.04))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                                                )
                                        )
                                }
                                .buttonStyle(PressableChromeButtonStyle())
                                .help(preferences.isProjectPinned(projectRailPinKey(rollup)) ? "Unpin project" : "Pin project")
                            }
                        }
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                railIconButton("gearshape", action: onOpenSettings)
                railIconButton("wrench.and.screwdriver", action: onOpenSetup)
                railIconButton("folder", action: onOpenCurrentWorkspace)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(width: 250)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.02))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1)
        }
    }

    private func presentSourcePrompt(snapshot: DashboardSnapshot) {
        let vaultRoot = preferences.effectiveObsidianVaultRoot ?? relayWorkingDirectory
        presentedModal = .sourcePrompt(
            SourcePromptDocument(
                title: "Process Sources Prompt",
                workingDirectory: vaultRoot,
                prompt: sourceProcessingPrompt(snapshot: snapshot, vaultRoot: vaultRoot)
            )
        )
    }

    private func sourceProcessingPrompt(snapshot: DashboardSnapshot, vaultRoot: String) -> String {
        let detectedRoots = topLevelImportCandidates(vaultRoot: vaultRoot)
        let candidatesSection = detectedRoots.isEmpty
            ? "- No non-skeleton top-level roots were detected automatically. Inspect the vault manually for stray knowledge folders."
            : detectedRoots.map { "- \($0)" }.joined(separator: "\n")
        let projectName = selectedKnowledgeProject(snapshot)?.name ?? snapshot.projectName
        let scopeLabel = preferences.scopeMode.title
        let scopeValue = preferences.scopeMode.rawValue

        return """
        You are operating inside the Obsidian vault root:
        `\(vaultRoot)`

        Goal:
        Run one conservative source-standardization pass only.
        This step is strictly for source ingestion and normalization; it is not a wiki compilation run.

        Architecture rules:
        - Treat `00 Raw Sources`, `10 Wiki`, `20 Queries and Reports`, and `90 System` as the managed skeleton.
        - Do not recursively re-ingest generated wiki or system pages as raw sources.
        - Treat `.agents` and `.obsidian` as internal metadata, not knowledge imports.
        - Keep raw imports immutable wherever possible: prefer copying or carefully reorganizing into canonical raw-source lanes instead of destructive rewrites.
        - Shared Fabric remains external canonical system state; do not move it into the vault.

        Current focus project:
        `\(projectName)`

        Requested scope mode:
        `\(scopeLabel)` (`\(scopeValue)`)

        Top-level non-skeleton candidates detected in the vault:
        \(candidatesSection)

        Your task:
        1. Inventory every top-level knowledge root that is not part of the managed skeleton.
        2. Classify each root into one of these source families:
           - Agent Chats
           - Gemini
           - ChatGPT
           - NotebookLM
           - Notion
           - Shared Fabric Snapshots
           - Other External Imports
        3. Normalize those materials into canonical raw-source lanes under:
           - `00 Raw Sources/Agent Chats`
           - `00 Raw Sources/External Imports/<Family>`
           - `00 Raw Sources/Shared Fabric Snapshots`
        4. Do not treat `10 Wiki` or `90 System` as inputs to be re-normalized.
        5. If a root is ambiguous, leave it in place and record it explicitly instead of guessing.
        6. Perform normalization work inside a temporary staging workspace first.
           - Use a temp directory under the vault such as `.tmp/process-sources/<timestamp>/`.
           - Copy or mirror candidate inputs into staging when transformation is needed.
           - Validate outputs in staging before writing final managed artifacts back into the vault.
           - Never mutate raw user source folders in-place while you are still reasoning.
        7. Refresh or regenerate only source-side managed outputs if your standardization pass changes source structure:
           - `90 System/normalized-sources-manifest.json`
           - `90 System/source-processing-report.md`
        8. Extract source semantics for downstream deep-wiki and graph building and cache them under:
           - `90 System/semantic-cache/source-keywords.json`
           - `90 System/semantic-cache/source-entities.json`
           - `90 System/semantic-cache/source-relationships.json`
           - `90 System/semantic-cache/source-concepts.json`
           - `90 System/semantic-cache/README.md` (fields + schema notes)
           - `90 System/project-source-index.json`
           - `90 System/global-knowledge-pool.json`
           - The cache should preserve provenance per concept/entity/relationship back to raw sources.
           - Include cross-project hints when the same concept appears in multiple projects or platforms.
           - Treat this as a contract, not a best-effort suggestion. Each file must be parseable JSON and follow the schema below.
           - `project-source-index.json`: object with `projects` array; each project object must include:
             - `project_name`
             - `slug`
             - `workspace` when known
             - `source_paths`
             - `source_families`
             - `evidence_count`
             - `notes`
           - `global-knowledge-pool.json`: object with
             - `global_keywords`
             - `global_concepts`
             - `global_entities`
             - `global_relationships`
             - `source_clusters`
             - `unmapped_summary`
           - `source_clusters` should summarize large source pools such as NotebookLM corpora, agent chat history, and shared fabric snapshots even when they are not cleanly project-bound.
           - Each `source_clusters` item must include:
             - `cluster_name`
             - `slug`
             - `source_families`
             - `themes`
             - `related_projects`
             - `representative_sources`
             - `support_count`
             - `notes`
           - Do not leave a large all-vault unmapped corpus as one monolithic bucket if it obviously contains multiple themes, domains, or platforms.
           - Split large unmapped material into finer semantic clusters before handing it to `Build All`.
           - `source-keywords.json`: array of objects with
             - `keyword`
             - `aliases`
             - `summary`
             - `project_hints`
             - `provenance`
             - `evidence`
             - `support_count`
           - `source-entities.json`: array of objects with
             - `entity_id`
             - `label`
             - `type`
             - `aliases`
             - `summary`
             - `project_hints`
             - `provenance`
             - `evidence`
             - `support_count`
           - `source-concepts.json`: array of objects with
             - `concept`
             - `aliases`
             - `description`
             - `project_hints`
             - `related_entities`
             - `related_concepts`
             - `provenance`
             - `evidence`
             - `support_count`
           - `source-relationships.json`: array of objects with
             - `source`
             - `relation`
             - `target`
             - `summary`
             - `project_hints`
             - `provenance`
             - `evidence`
             - `support_count`
           - `README.md` must describe the exact field meanings and any normalization rules you applied.
           - Do not emit low-information keywords or stopwords such as `and`, `the`, `for`, `next`, `then`, `with`, `that`, `this`, `from`, `into`, `over`, `under`, `still`, or `than`.
           - Do not emit path fragments, markdown separators, or UI filler as keywords.
           - Canonical project units must align to real projects/workspaces, not raw source family buckets.
           - Do not invent pseudo-project names like `NotebookLM: <folder>` or `Agent Chats: <folder>` when those materials actually belong to an existing project.
           - If a source cannot be mapped to a canonical project, keep it in `project-source-index.json` as explicitly unmapped rather than pretending it is a standalone project.
           - For a well-populated project, extract more than one or two semantic terms. Aim for approximately:
             - 8-20 high-quality keywords
             - 4-12 concepts
             - 4-12 entities
             - 3-12 relationships
             when evidence volume supports it.
           - For large unmapped or cross-project corpora, extract a separate global layer rather than collapsing everything into a single placeholder node.
           - Prioritize repeated, evidence-backed terms over generic one-off abstractions.
        9. Do not rebuild wiki project pages, graph, or knowledge-base manifest in this step.
        10. Summarize whether a follow-up `Build All` run is recommended to compile sources into wiki outputs.
        11. Run a self-check before finishing:
           - Every semantic object must have at least one provenance item and one evidence snippet.
           - If a concept/entity/relationship cannot be grounded in source evidence, exclude it.
           - If fewer than 5 strong concepts are found, say so explicitly rather than padding the output with weak abstractions.
           - If cross-project hints are empty because only one project was found, say that explicitly.
           - If requested scope mode is `allVault`, semantic extraction must cover the full canonical raw-source vault, not a single project sample.
           - In `allVault` mode, do not silently limit extraction to the current focus project or one NotebookLM folder.
           - In `allVault` mode, explicitly report the distinct projects or source clusters represented in the semantic cache.
           - Keyword/concept extraction should read full source text, not only file names, index pages, or folder names.
           - If a project or global corpus has substantial evidence volume, but only yields one or two keywords, treat that as under-extraction and report failure or partial completion.
           - If NotebookLM, Agent Chats, or Shared Fabric contribute substantial unmapped material, summarize them in `global-knowledge-pool.json` instead of leaving them semantically thin.
           - For large NotebookLM, Agent Chats, or Shared Fabric corpora, identify representative evidence and higher-order themes rather than outputting only file-level or folder-level labels.

        Required output format:
        - Inventory
        - Proposed family mapping
        - Exact filesystem actions taken
        - Ambiguous roots left untouched
        - Semantic cache files written
        - Project-source mapping summary
        - Global knowledge pool summary
        - Scope coverage statement
        - Validation checks passed or failed
        - Recommended next step

        Failure conditions:
        - If any required semantic-cache file is missing, invalid JSON, or violates the schema above, report failure instead of pretending the pass succeeded.
        - If you are uncertain whether an item belongs in the semantic cache, leave it out and mention the ambiguity explicitly.
        - If requested scope mode is `allVault` but the semantic cache only reflects one project or one narrow source cluster, report failure or partial completion explicitly.

        Safety constraints:
        - Do not delete user data unless there is an obvious duplicate that is already safely represented in canonical raw sources.
        - Prefer conservative reorganization over aggressive cleanup.
        - If you need to choose between preserving provenance and making the folder tree prettier, preserve provenance.
        """
    }

    private func topLevelImportCandidates(vaultRoot: String) -> [String] {
        let root = URL(fileURLWithPath: vaultRoot)
        let excluded = Set([".agents", ".obsidian", "00 Raw Sources", "10 Wiki", "20 Queries and Reports", "90 System"])
        guard let contents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return contents
            .filter { !excluded.contains($0.lastPathComponent) }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                return values?.isDirectory == true ? url.lastPathComponent : nil
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func chromeBar(snapshot: DashboardSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preferences.scopeMode == .allVault ? "Obsidian Vault" : snapshot.projectName)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(preferences.scopeMode == .allVault ? "Knowledge Base" : snapshot.workspace)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 8) {
                    toolbarActionButton("Normalize", symbol: "square.grid.3x3", tint: .indigo, helpText: "Create or repair the canonical vault structure, system pages, manifest, and graph scaffolding without moving legacy folders.", iconOnly: true, action: onNormalizeVault)
                    toolbarActionButton("Process Sources", symbol: "tray.and.arrow.down", tint: .mint, helpText: "Generate a structured source-normalization prompt for Gemini CLI using the current Obsidian vault context.", iconOnly: true, action: {
                        presentSourcePrompt(snapshot: snapshot)
                    })
                    toolbarActionButton("Build All", symbol: "wand.and.stars", tint: .blue, helpText: "Generate a Build All snippet for Gemini CLI to compile source manifests into wiki and system outputs.", iconOnly: true, action: onBuildAllProjectWikis)
                    toolbarActionButton("Reload", symbol: "arrow.clockwise", tint: .cyan, helpText: "Reload the dashboard from current on-disk data without recompiling the vault.", iconOnly: true, action: onRefresh)
                }

                HStack(spacing: 8) {
                    miniInfoPill("MCP \(snapshot.activeMcpCount)")
                    topToggleIcon("eye", active: auxiliaryPanels.showObservePanel, action: onToggleObservePanel)
                    topToggleIcon("terminal", active: auxiliaryPanels.showGeminiPanel, action: onToggleGeminiPanel)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            if viewModel.isBusy {
                VStack(spacing: 6) {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Color.cyan)
                    HStack {
                        Text(viewModel.operationStatus)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            }
        }
        .background(Color.white.opacity(0.02))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
    }

    private func mainWorkbench(snapshot: DashboardSnapshot) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                switch preferences.surfaceMode {
                case .graph, .chat, .observe:
                    graphStage(snapshot: snapshot)
                case .wiki:
                    wikiStage(snapshot: snapshot)
                case .sources:
                    sourcesStage(snapshot: snapshot)
                }
            }
            .id(preferences.surfaceMode)
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.992, anchor: .topLeading)), removal: .opacity))
            .animation(.interactiveSpring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.10), value: preferences.surfaceMode)
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if preferences.surfaceMode == .sources {
                floatingSourceButtons
                    .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func graphStage(snapshot: DashboardSnapshot) -> some View {
        knowledgeGraphCard(snapshot: snapshot)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func wikiStage(snapshot: DashboardSnapshot) -> some View {
        let documents = wikiDocuments(snapshot)
        let previewDocument = resolvedDocument(selectedWikiDocumentPath, fallbackFrom: documents)

        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                wikiStatusCard(snapshot: snapshot)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Wiki")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    ForEach(documents) { page in
                        Button {
                            selectedWikiDocumentPath = page.path
                        } label: {
                            HStack {
                                Text(page.title)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                Spacer()
                                if previewDocument?.path == page.path {
                                    Circle()
                                        .fill(Color.cyan)
                                        .frame(width: 6, height: 6)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(previewDocument?.path == page.path ? Color.white.opacity(0.08) : Color.white.opacity(0.03))
                            )
                        }
                        .buttonStyle(PressableChromeButtonStyle())
                    }
                }
                .padding(14)
                .background(cardBackground(cornerRadius: 18))
            }
            .frame(width: 300, alignment: .topLeading)

            markdownPreviewPanel(
                title: previewTitle(for: previewDocument, fallback: preferences.scopeMode == .allVault ? "Vault Wiki" : "Project Wiki"),
                path: previewDocument?.path ?? "",
                displayPath: previewDocument?.displayPath ?? "",
                contentOverride: previewDocument?.inlineContent ?? "",
                emptyMessage: "No wiki page selected.",
                rendered: true
            )
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 520, alignment: .topLeading)
        }
    }

    private func sourcesStage(snapshot: DashboardSnapshot) -> some View {
        let documents = sourceDocuments(snapshot)
        let previewDocument = resolvedDocument(selectedSourceDocumentPath, fallbackFrom: documents)
        let sidebarWidth: CGFloat = 312

        return GeometryReader { stageGeometry in
            let totalHeight = min(max(420, stageGeometry.size.height), 430)

            HStack(alignment: .top, spacing: 16) {
                obsidianSourceCard(snapshot: snapshot, documents: documents, previewPath: previewDocument?.path ?? "")
                    .frame(width: sidebarWidth, height: totalHeight, alignment: .topLeading)

                markdownPreviewPanel(
                    title: previewTitle(for: previewDocument, fallback: "Knowledge Source"),
                    path: previewDocument?.path ?? "",
                    displayPath: previewDocument?.displayPath ?? "",
                    contentOverride: previewDocument?.inlineContent ?? "",
                    emptyMessage: preferences.scopeMode == .allVault ? "Select an Obsidian document." : "Select an Obsidian-backed source document.",
                    fillHeight: true
                )
                .layoutPriority(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .frame(height: totalHeight, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: totalHeight, alignment: .topLeading)
        }
    }

    private var floatingSourceButtons: some View {
        HStack(spacing: 10) {
            if dataAcquisitionFeaturesEnabled {
                toolbarActionButton("Export Current", symbol: "square.and.arrow.up", tint: .mint, action: onExportCurrentChats)
                toolbarActionButton("Export All", symbol: "tray.full", tint: .blue, action: onExportAllChats)
            }
        }
    }

    private func railSurfaceButton(_ mode: DashboardSurfaceMode) -> some View {
        Button {
            preferences.surfaceMode = mode
        } label: {
            HStack(spacing: 10) {
                Text(mode.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer()
                if preferences.surfaceMode == mode {
                    Circle()
                        .fill(Color(red: 0.27, green: 0.61, blue: 1.0))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(preferences.surfaceMode == mode ? Color.white.opacity(0.07) : Color.clear)
            )
        }
        .buttonStyle(PressableChromeButtonStyle())
        .modifier(HoverChromeModifier(active: preferences.surfaceMode == mode, lift: 1.5, glow: 0.06))
    }

    private func railIconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.035))
                )
        }
        .buttonStyle(PressableChromeButtonStyle())
        .modifier(HoverChromeModifier(active: false, lift: 1.2, glow: 0.04))
    }

    private func toolbarActionButton(_ title: String, symbol: String, tint: Color, helpText: String? = nil, iconOnly: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                if !iconOnly {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, iconOnly ? 9 : 10)
            .padding(.vertical, 8)
            .frame(minWidth: iconOnly ? 30 : nil)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(tint.opacity(0.18), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PressableChromeButtonStyle())
        .help(helpText ?? title)
        .modifier(HoverChromeModifier(active: false, lift: 1.5, glow: 0.05))
    }

    private func topToggleIcon(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? .primary : .secondary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(active ? Color.white.opacity(0.10) : Color.white.opacity(0.035))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(active ? Color.white.opacity(0.10) : Color.clear, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(PressableChromeButtonStyle())
        .modifier(HoverChromeModifier(active: active, lift: 1.2, glow: 0.07))
    }

    private func miniInfoPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
            )
    }

    private func projectRailRollups(_ snapshot: DashboardSnapshot) -> [ObserveRollup] {
        if !snapshot.observeRollups.isEmpty {
            return snapshot.observeRollups
        }
        if !snapshot.knowledgeProjects.isEmpty {
            return snapshot.knowledgeProjects.map {
                ObserveRollup(
                    projectName: $0.name,
                    slug: $0.slug,
                    workspaceCount: 1,
                    latestRuntime: $0.runtime,
                    latestSyncStatus: "UNKNOWN",
                    attentionState: "healthy",
                    latestActivity: $0.lastUpdated,
                    latestFocus: $0.focus,
                    openLoopCount: 0,
                    decisionCount: 0,
                    learningCount: 0,
                    workspaces: [$0.workspace]
                )
            }
        }
        return snapshot.availableWorkspaces.map { option in
            let projectName = option.label.isEmpty ? URL(fileURLWithPath: option.path).lastPathComponent : option.label
            return ObserveRollup(
                projectName: projectName,
                slug: projectName.lowercased().replacingOccurrences(of: " ", with: "-"),
                workspaceCount: 1,
                latestRuntime: "",
                latestSyncStatus: option.source.uppercased(),
                attentionState: "idle",
                latestActivity: option.lastSeen,
                latestFocus: "",
                openLoopCount: 0,
                decisionCount: 0,
                learningCount: 0,
                workspaces: [option.path]
            )
        }
    }

    private func projectRailPinKey(_ rollup: ObserveRollup) -> String {
        if let workspace = rollup.workspaces.first, !workspace.isEmpty {
            return "workspace:\(normalizedGraphMatchKey(workspace))"
        }
        if !rollup.slug.isEmpty {
            return "slug:\(normalizedGraphMatchKey(rollup.slug))"
        }
        return "name:\(normalizedGraphMatchKey(rollup.projectName))"
    }

    private func projectRailDisplayRollups(_ snapshot: DashboardSnapshot) -> [ObserveRollup] {
        let base = projectRailRollups(snapshot)
        let pinnedKeys = Set(preferences.pinnedProjectKeys)
        let filtered = preferences.showPinnedProjectsOnly ? base.filter { pinnedKeys.contains(projectRailPinKey($0)) } : base
        return filtered.sorted { lhs, rhs in
            let leftPinned = pinnedKeys.contains(projectRailPinKey(lhs))
            let rightPinned = pinnedKeys.contains(projectRailPinKey(rhs))
            if leftPinned != rightPinned {
                return leftPinned && !rightPinned
            }
            let leftTime = relativeTimeSortKey(lhs.latestActivity)
            let rightTime = relativeTimeSortKey(rhs.latestActivity)
            if leftTime != rightTime {
                return leftTime > rightTime
            }
            return lhs.projectName.localizedCaseInsensitiveCompare(rhs.projectName) == .orderedAscending
        }
    }

    private func projectRailPrimaryTitle(_ rollup: ObserveRollup) -> String {
        rollup.projectName
    }

    private func projectRailSecondaryText(_ rollup: ObserveRollup, snapshot: DashboardSnapshot) -> String {
        if !rollup.latestFocus.isEmpty {
            return rollup.latestFocus
        }
        let duplicateCount = projectRailRollups(snapshot).filter { $0.projectName.caseInsensitiveCompare(rollup.projectName) == .orderedSame }.count
        if duplicateCount > 1 {
            if let workspace = rollup.workspaces.first, !workspace.isEmpty {
                return URL(fileURLWithPath: workspace).lastPathComponent
            }
            if !rollup.slug.isEmpty {
                return rollup.slug
            }
        }
        if let workspace = rollup.workspaces.first, !workspace.isEmpty, !isRollupSelected(rollup, snapshot: snapshot) {
            return URL(fileURLWithPath: workspace).lastPathComponent
        }
        return "No activity yet"
    }

    private func relativeTimeSortKey(_ timestamp: String) -> String {
        timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isRollupSelected(_ rollup: ObserveRollup, snapshot: DashboardSnapshot) -> Bool {
        if preferences.scopeMode == .allVault { return false }
        if rollup.workspaces.contains(snapshot.workspace) { return true }
        return rollup.projectName == snapshot.projectName
    }

    private func selectProjectRollup(_ rollup: ObserveRollup) {
        if let workspace = rollup.workspaces.first, !workspace.isEmpty {
            selectedWikiDocumentPath = ""
            onSelectWorkspace(workspace)
            preferences.scopeMode = .workspace
        }
    }

    private func relativeTimeLabel(_ timestamp: String) -> String {
        guard !timestamp.isEmpty else { return "" }
        if timestamp.count >= 10 {
            return String(timestamp.prefix(10))
        }
        return timestamp
    }

    private func wikiDocuments(_ snapshot: DashboardSnapshot) -> [KnowledgeDocument] {
        let standardDocument = normalizationStandardDocument()
        if preferences.scopeMode == .allVault {
            return [standardDocument] + vaultWideWikiDocuments(snapshot)
        }
        var documents = [standardDocument] + wikiCards(snapshot)
        if snapshot.projectUpdateLog.isAvailable {
            documents.insert(
                KnowledgeDocument(
                    title: "Update Log",
                    path: "virtual://\(snapshot.projectName)-update-log",
                    displayPath: "Generated from Project Memory",
                    inlineContent: snapshot.projectUpdateLog.content
                ),
                at: 1
            )
        }
        return documents
    }

    private func sourceDocuments(_ snapshot: DashboardSnapshot) -> [KnowledgeDocument] {
        if preferences.scopeMode == .allVault {
            return vaultWideWikiDocuments(snapshot)
        }

        var docs = [normalizationStandardDocument()] + wikiCards(snapshot).filter { $0.title == "Sources" || $0.title == "Current Status" || $0.title == "Architecture" }
        if snapshot.projectUpdateLog.isAvailable {
            docs.insert(
                KnowledgeDocument(
                    title: "Update Log",
                    path: "virtual://\(snapshot.projectName)-source-update-log",
                    displayPath: "Generated from Project Memory",
                    inlineContent: snapshot.projectUpdateLog.content
                ),
                at: 0
            )
        }
        return docs
    }

    private func resolvedDocument(_ selectedPath: String, fallbackFrom documents: [KnowledgeDocument]) -> KnowledgeDocument? {
        if !selectedPath.isEmpty,
           let selected = documents.first(where: { $0.path == selectedPath }),
           selected.isVirtual || FileManager.default.fileExists(atPath: selected.path) {
            return selected
        }
        return documents.first(where: { $0.isVirtual || FileManager.default.fileExists(atPath: $0.path) }) ?? documents.first
    }

    private func previewTitle(for document: KnowledgeDocument?, fallback: String) -> String {
        document?.title ?? fallback
    }

    private func normalizationStandardDocument() -> KnowledgeDocument {
        KnowledgeDocument(
            title: "Normalization Standard",
            path: "virtual://normalization-standard",
            displayPath: "Fabric knowledge ingestion contract",
            inlineContent: """
            # Normalization Standard

            ## Purpose
            The app is the single normalization engine for imported knowledge. External systems do not maintain bespoke wiki logic.

            ## Canonical Layers
            - `00 Raw Sources`
              - Immutable imported materials.
              - Source-family specific folders such as Agent Chats, Gemini, ChatGPT, NotebookLM, Notion, and Shared Fabric Snapshots.
            - `10 Wiki`
              - Maintained human-readable pages compiled from extracted source elements.
            - `20 Queries and Reports`
              - Optional generated reports and query outputs.
            - `90 System`
              - Schema, index, log, graph, source manifests, and processing reports.

            ## Actions
            - `Normalize Vault`
              - Repairs the canonical vault folder structure and system pages.
              - Does not rewrite or reinterpret imported knowledge.
            - `Process Sources`
              - Imports and standardizes supported source families into immutable raw-source lanes.
              - Extracts summaries and project hints.
              - Regenerates source-library pages.
            - `Build All`
              - Recompiles wiki pages, index, log, manifest, and graph from normalized state.

            ## Source Adapter Contract
            Each normalized source item must expose:
            - source family
            - source id
            - title
            - timestamp
            - raw content path
            - provenance path
            - extracted summary
            - extracted wiki elements

            ## Current Source Families
            - Agent Chats
            - Gemini
            - ChatGPT
            - NotebookLM
            - Notion
            - Shared Fabric

            ## Shared Fabric Position
            Shared Fabric stays outside the Obsidian vault as canonical system state.
            The app reads it through an adapter and emits normalized raw-source snapshots plus wiki updates.
            """
        )
    }

    private func vaultWideWikiDocuments(_ snapshot: DashboardSnapshot) -> [KnowledgeDocument] {
        guard let vaultRoot = preferences.effectiveObsidianVaultRoot else { return [] }
        let fileManager = FileManager.default
        let vaultURL = URL(fileURLWithPath: vaultRoot)
        let candidateRoots: [(URL, String)] = [
            (vaultURL.appendingPathComponent("90 System"), "System"),
            (vaultURL.appendingPathComponent("10 Wiki/Sources"), "Sources"),
            (vaultURL.appendingPathComponent("10 Wiki/Projects"), "Project"),
            (vaultURL.appendingPathComponent("10 Wiki/Concepts"), "Concept"),
            (vaultURL.appendingPathComponent("10 Wiki/Entities"), "Entity"),
        ]
        var documents: [KnowledgeDocument] = []
        var seen: Set<String> = []

        for (root, category) in candidateRoots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension.lowercased() == "md" else { continue }
                let path = fileURL.path
                if seen.contains(path) { continue }
                seen.insert(path)
                let relative = path.replacingOccurrences(of: vaultRoot + "/", with: "")
                let title: String
                if category == "Project" {
                    let slug = fileURL.deletingLastPathComponent().lastPathComponent
                    title = "\(slug) · \(fileURL.deletingPathExtension().lastPathComponent)"
                } else {
                    title = "\(category) · \(fileURL.deletingPathExtension().lastPathComponent)"
                }
                documents.append(
                    KnowledgeDocument(
                        title: title,
                        path: path,
                        displayPath: relative
                    )
                )
            }
        }

        return documents.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func markdownPreviewPanel(title: String, path: String, displayPath: String, contentOverride: String = "", emptyMessage: String, fillHeight: Bool = false, rendered: Bool = false) -> some View {
        let content = contentOverride.isEmpty ? loadTextFile(path) : contentOverride
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(displayPath.isEmpty ? "No file selected" : displayPath)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if !path.isEmpty && !path.hasPrefix("virtual://") {
                    Button("Open") {
                        onOpenPath(path)
                    }
                    .buttonStyle(PressableChromeButtonStyle())
                }
            }
            if rendered {
                wikiRenderedPreview(content: content, path: path, title: title, emptyMessage: emptyMessage)
            } else {
                ScrollView {
                    Text(content.isEmpty ? emptyMessage : content)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(content.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.black.opacity(0.16))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                                )
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .padding(16)
        .background(cardBackground(cornerRadius: 20))
        .contentTransition(.opacity)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: title)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: path)
    }

    private func sourceSummaryCard(model: SourceSummaryCardModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(model.detail)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(3)
            Spacer(minLength: 0)
            toolbarActionButton(model.actionTitle, symbol: model.actionSymbol, tint: .gray, action: model.action)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(cardBackground(cornerRadius: 18))
        .modifier(HoverChromeModifier(active: false, lift: 1.5, glow: 0.05))
    }

    private func sourceCards(_ snapshot: DashboardSnapshot) -> [SourceSummaryCardModel] {
        if preferences.scopeMode == .allVault {
            return [
                SourceSummaryCardModel(
                    title: "Knowledge Base",
                    detail: knowledgeBaseFolderPath(snapshot) ?? "Vault not configured",
                    actionTitle: "Open",
                    actionSymbol: "book.closed",
                    action: {
                        if let path = knowledgeBaseFolderPath(snapshot) {
                            onOpenPath(path)
                        }
                    }
                )
            ]
        }

        return [
            SourceSummaryCardModel(
                title: "Knowledge Base",
                detail: knowledgeBaseFolderPath(snapshot) ?? "Project wiki not built yet",
                actionTitle: "Open",
                actionSymbol: "book.closed",
                action: {
                    if let path = knowledgeBaseFolderPath(snapshot) {
                        onOpenPath(path)
                    }
                }
            ),
            SourceSummaryCardModel(
                title: "Repository",
                detail: snapshot.workspace,
                actionTitle: "Open",
                actionSymbol: "folder",
                action: onOpenCurrentWorkspace
            )
        ]
    }

    private func knowledgeBaseFolderPath(_ snapshot: DashboardSnapshot) -> String? {
        if preferences.scopeMode == .allVault {
            guard let vaultRoot = preferences.effectiveObsidianVaultRoot else { return nil }
            return URL(fileURLWithPath: vaultRoot).appendingPathComponent("10 Wiki").path
        }
        return selectedKnowledgeProject(snapshot)?.wikiRoot
    }

    private func obsidianSourceCard(snapshot: DashboardSnapshot, documents: [KnowledgeDocument], previewPath: String) -> some View {
        let knowledgeBasePath = knowledgeBaseFolderPath(snapshot) ?? "Knowledge base path unavailable"
        let workspacePath = snapshot.workspace

        return VStack(alignment: .leading, spacing: 10) {
            Text("Knowledge Base Sources")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(preferences.effectiveObsidianVaultRoot ?? "Vault not configured")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            VStack(alignment: .leading, spacing: 6) {
                Text("Knowledge Base")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(knowledgeBasePath)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .lineLimit(2)
                if preferences.scopeMode != .allVault {
                    Text("Repository")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(workspacePath)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    toolbarActionButton("Open KB", symbol: "book.closed", tint: .gray, action: {
                        if let path = knowledgeBaseFolderPath(snapshot) {
                            onOpenPath(path)
                        }
                    })
                    if preferences.scopeMode != .allVault {
                        toolbarActionButton("Open Repo", symbol: "folder", tint: .gray, action: onOpenCurrentWorkspace)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.03))
            )

            ForEach(documents, id: \.path) { document in
                Button {
                    selectedSourceDocumentPath = document.path
                } label: {
                    HStack {
                        Text(document.title)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                        Spacer()
                        if previewPath == document.path {
                            Circle()
                                .fill(Color.cyan)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(previewPath == document.path ? Color.white.opacity(0.08) : Color.white.opacity(0.03))
                    )
                }
                .buttonStyle(PressableChromeButtonStyle())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(cardBackground(cornerRadius: 18))
        .modifier(HoverChromeModifier(active: false, lift: 1.4, glow: 0.05))
    }

    private func loadTextFile(_ path: String) -> String {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private func wikiRenderedPreview(content: String, path: String, title: String, emptyMessage: String) -> some View {
        let html = wikiArticleHTML(markdown: content, currentPath: path, title: title, emptyMessage: emptyMessage)
        return WikiArticleWebView(
            html: html,
            onNavigatePath: { target in
                if !target.isEmpty {
                    selectedWikiDocumentPath = target
                }
            },
            onOpenPath: { target in
                onOpenPath(target)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private func wikiArticleHTML(markdown: String, currentPath: String, title: String, emptyMessage: String) -> String {
        let vaultRoot = preferences.effectiveObsidianVaultRoot ?? ""
        let preprocessed = preprocessWikiMarkdown(markdown, currentPath: currentPath, vaultRoot: vaultRoot)
        let markdownJSON = javascriptStringLiteral(preprocessed)
        let titleHTML = graphEscapedHTML(title)
        let emptyHTML = graphEscapedHTML(emptyMessage)
        return """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<script src="vendor/marked.min.js"></script>
<style>
  html, body { margin: 0; width: 100%; height: 100%; background: transparent; overflow: hidden; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
  body { color: #eef2ff; }
  #shell { height: 100%; overflow-y: auto; padding: 26px 28px 42px; box-sizing: border-box; background:
      radial-gradient(circle at 16% 0%, rgba(66, 153, 225, 0.09), transparent 28%),
      radial-gradient(circle at 100% 22%, rgba(56, 189, 248, 0.08), transparent 24%),
      linear-gradient(180deg, rgba(17, 20, 31, 0.88), rgba(11, 13, 20, 0.96)); }
  #article { max-width: 900px; margin: 0 auto; }
  #eyebrow { font-size: 11px; text-transform: uppercase; letter-spacing: 0.08em; color: #8da2c9; margin-bottom: 10px; }
  h1, h2, h3, h4 { color: #f8fafc; line-height: 1.18; margin-top: 1.4em; }
  h1 { font-size: 34px; margin-top: 0.2em; margin-bottom: 0.4em; }
  h2 { font-size: 24px; border-bottom: 1px solid rgba(255,255,255,0.08); padding-bottom: 0.28em; }
  h3 { font-size: 18px; }
  p, li { color: #d8def4; font-size: 15px; line-height: 1.7; }
  ul, ol { padding-left: 1.5rem; }
  code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px; background: rgba(255,255,255,0.06); padding: 0.12rem 0.36rem; border-radius: 6px; }
  pre { background: rgba(0,0,0,0.30); padding: 16px; border-radius: 14px; overflow-x: auto; border: 1px solid rgba(255,255,255,0.06); }
  pre code { background: transparent; padding: 0; }
  blockquote { margin: 1.1em 0; padding: 0.4em 1em; border-left: 3px solid rgba(125, 211, 252, 0.56); color: #b9c5e6; background: rgba(255,255,255,0.03); border-radius: 0 12px 12px 0; }
  a { color: #7dd3fc; text-decoration: none; }
  a:hover { text-decoration: underline; }
  table { width: 100%; border-collapse: collapse; margin: 1.1em 0; }
  th, td { border: 1px solid rgba(255,255,255,0.08); padding: 10px 12px; text-align: left; }
  th { background: rgba(255,255,255,0.04); }
  hr { border: none; border-top: 1px solid rgba(255,255,255,0.08); margin: 1.8em 0; }
  .empty { color: #9aa6c4; font-size: 15px; }
  .toc { margin: 0 0 22px; padding: 14px 16px; border-radius: 16px; background: rgba(255,255,255,0.035); border: 1px solid rgba(255,255,255,0.06); }
  .toc-title { font-size: 11px; text-transform: uppercase; letter-spacing: 0.08em; color: #8da2c9; margin-bottom: 8px; }
  .toc a { display: block; margin: 6px 0; font-size: 13px; }
</style>
</head>
<body>
<div id="shell">
  <div id="article">
    <div id="eyebrow">Wiki Reader</div>
    <div id="content" class="empty">\(emptyHTML)</div>
  </div>
</div>
<script>
const RAW_MARKDOWN = \(markdownJSON);
const TITLE = "\(titleHTML)";

function renderFallback(text) {
  const content = document.getElementById('content');
  const escaped = text.replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
  content.className = '';
  content.innerHTML = `<h1>${TITLE}</h1><pre>${escaped}</pre>`;
}

function renderMarkdown(text) {
  if (!text.trim()) {
    return;
  }
  if (!window.marked) {
    renderFallback(text);
    return;
  }
  marked.setOptions({ gfm: true, breaks: false, headerIds: true, mangle: false });
  const html = marked.parse(text);
  const content = document.getElementById('content');
  content.className = '';
  content.innerHTML = html;
  if (!content.querySelector('h1')) {
    content.innerHTML = `<h1>${TITLE}</h1>` + content.innerHTML;
  }
  const headings = Array.from(content.querySelectorAll('h2, h3')).slice(0, 10);
  if (headings.length) {
    const toc = document.createElement('div');
    toc.className = 'toc';
    toc.innerHTML = `<div class="toc-title">On This Page</div>`;
    headings.forEach((heading, index) => {
      if (!heading.id) {
        heading.id = `section-${index}`;
      }
      const link = document.createElement('a');
      link.href = `#${heading.id}`;
      link.textContent = heading.textContent || `Section ${index + 1}`;
      toc.appendChild(link);
    });
    content.insertBefore(toc, content.firstChild.nextSibling || null);
  }
}

document.addEventListener('click', event => {
  const link = event.target.closest('a');
  if (!link) return;
  const href = link.getAttribute('href') || '';
  if (!href || href.startsWith('#')) return;
  event.preventDefault();
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.wikiNavigate) {
    if (href.startsWith('app-wiki://')) {
      window.webkit.messageHandlers.wikiNavigate.postMessage({ kind: 'navigate', value: decodeURIComponent(href.replace('app-wiki://', '')) });
    } else if (href.startsWith('file://')) {
      window.webkit.messageHandlers.wikiNavigate.postMessage({ kind: 'open', value: decodeURIComponent(href.replace('file://', '')) });
    } else {
      window.webkit.messageHandlers.wikiNavigate.postMessage({ kind: 'open', value: href });
    }
  }
});

renderMarkdown(RAW_MARKDOWN);
</script>
</body>
</html>
"""
    }

    private func preprocessWikiMarkdown(_ markdown: String, currentPath: String, vaultRoot: String) -> String {
        let pattern = #"\[\[([^\]|#]+)(?:#[^\]|]+)?(?:\|([^\]]+))?\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return markdown
        }
        let nsrange = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        var replacements: [(NSRange, String)] = []
        regex.enumerateMatches(in: markdown, options: [], range: nsrange) { match, _, _ in
            guard let match else { return }
            guard let pathRange = Range(match.range(at: 1), in: markdown) else { return }
            let rawPath = String(markdown[pathRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let label: String
            if let labelRange = Range(match.range(at: 2), in: markdown) {
                label = String(markdown[labelRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                label = URL(fileURLWithPath: rawPath).deletingPathExtension().lastPathComponent
            }
            let resolved = resolveWikiLinkTarget(rawPath: rawPath, currentPath: currentPath, vaultRoot: vaultRoot)
            let replacement: String
            if resolved.isEmpty {
                replacement = label
            } else {
                let encoded = resolved.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? resolved
                replacement = "[\(label)](app-wiki://\(encoded))"
            }
            replacements.append((match.range, replacement))
        }

        var result = markdown
        for (range, replacement) in replacements.reversed() {
            if let swiftRange = Range(range, in: result) {
                result.replaceSubrange(swiftRange, with: replacement)
            }
        }
        return result
    }

    private func resolveWikiLinkTarget(rawPath: String, currentPath: String, vaultRoot: String) -> String {
        let cleaned = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if let remoteURL = URL(string: cleaned), let scheme = remoteURL.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            return ""
        }
        let fileManager = FileManager.default
        var candidates: [String] = []
        if !vaultRoot.isEmpty {
            candidates.append(URL(fileURLWithPath: vaultRoot).appendingPathComponent(cleaned).path)
            if !cleaned.lowercased().hasSuffix(".md") {
                candidates.append(URL(fileURLWithPath: vaultRoot).appendingPathComponent(cleaned + ".md").path)
            }
        }
        if !currentPath.isEmpty && !currentPath.hasPrefix("virtual://") {
            let currentURL = URL(fileURLWithPath: currentPath).deletingLastPathComponent()
            candidates.append(currentURL.appendingPathComponent(cleaned).path)
            if !cleaned.lowercased().hasSuffix(".md") {
                candidates.append(currentURL.appendingPathComponent(cleaned + ".md").path)
            }
        }
        if cleaned.hasPrefix("/") {
            candidates.insert(cleaned, at: 0)
        }
        for candidate in candidates {
            if fileManager.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return candidates.first ?? cleaned
    }

    private func chatKnowledgeDocuments(_ snapshot: DashboardSnapshot, scope: KnowledgeScopeMode) -> [KnowledgeDocument] {
        switch scope {
        case .allVault:
            return allVaultKnowledgeDocuments(snapshot)
        case .project, .workspace:
            var documents = wikiDocuments(snapshot)
            let sourceDocs = sourceDocuments(snapshot)
            let existingPaths = Set(documents.map(\.path))
            for document in sourceDocs where !existingPaths.contains(document.path) {
                documents.append(document)
            }
            return documents
        }
    }

    private func allVaultKnowledgeDocuments(_ snapshot: DashboardSnapshot) -> [KnowledgeDocument] {
        guard let vaultRoot = preferences.effectiveObsidianVaultRoot else {
            return wikiDocuments(snapshot)
        }
        let fileManager = FileManager.default
        let vaultURL = URL(fileURLWithPath: vaultRoot)
        let candidateRoots = [
            vaultURL.appendingPathComponent("90 System"),
            vaultURL.appendingPathComponent("10 Wiki/Sources"),
            vaultURL.appendingPathComponent("10 Wiki/Projects"),
        ]
        var documents: [KnowledgeDocument] = []
        var seen: Set<String> = []

        for root in candidateRoots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension.lowercased() == "md" else { continue }
                let path = fileURL.path
                if seen.contains(path) { continue }
                seen.insert(path)
                documents.append(
                    KnowledgeDocument(
                        title: fileURL.deletingPathExtension().lastPathComponent,
                        path: path
                    )
                )
            }
        }

        return documents.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func retrievalTokens(_ text: String) -> [String] {
        let stopwords: Set<String> = [
            "about", "after", "also", "build", "current", "from", "have", "into", "just", "more", "only",
            "page", "project", "should", "source", "status", "that", "their", "there", "these", "this",
            "through", "what", "when", "where", "which", "wiki", "with", "would", "可以", "怎么", "什么",
            "我们", "这个", "那个", "需要", "以及", "现在", "是否", "进行", "构建"
        ]
        let scalars = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        let normalized = String(scalars)
        var seen: Set<String> = []
        var tokens: [String] = []
        for token in normalized.split(separator: " ").map(String.init) {
            guard token.count >= 2, !stopwords.contains(token), !seen.contains(token) else { continue }
            seen.insert(token)
            tokens.append(token)
        }
        return tokens
    }

    private func relevantSnippet(for content: String, question: String, tokens: [String], limit: Int = 520) -> String {
        let paragraphs = content
            .components(separatedBy: "\n\n")
            .map { block in block.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if paragraphs.isEmpty {
            return String(content.prefix(limit))
        }

        let fallbackToken = question.lowercased()
        let ranked = paragraphs.map { paragraph -> (String, Int) in
            let haystack = paragraph.lowercased()
            var score = 0
            for token in tokens {
                if haystack.contains(token) {
                    score += 2
                }
            }
            if !fallbackToken.isEmpty, haystack.contains(fallbackToken) {
                score += 3
            }
            return (paragraph, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.count < rhs.0.count
        }

        let best = ranked.first?.0 ?? paragraphs[0]
        return best.count > limit ? String(best.prefix(limit)) + "..." : best
    }

    private func retrievedWikiContextBlocks(snapshot: DashboardSnapshot, scope: KnowledgeScopeMode, question: String) -> [String] {
        let documents = chatKnowledgeDocuments(snapshot, scope: scope)
        let tokens = retrievalTokens(question)
        let scored: [(document: KnowledgeDocument, snippet: String, score: Int)] = documents.compactMap { document in
            let content = document.inlineContent.isEmpty ? loadTextFile(document.path) : document.inlineContent
            guard !content.isEmpty else { return nil }

            let haystack = "\(document.title)\n\(document.displayPath)\n\(content.prefix(6000))".lowercased()
            var score = 0
            for token in tokens {
                if document.title.lowercased().contains(token) {
                    score += 4
                }
                if haystack.contains(token) {
                    score += 1
                }
            }
            if score == 0 {
                return nil
            }
            let snippet = relevantSnippet(for: content, question: question, tokens: tokens)
            return (document, snippet, score)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.document.title.localizedCaseInsensitiveCompare(rhs.document.title) == .orderedAscending
            }
            .prefix(scope == .allVault ? 6 : 4)
            .map { item in
                let pathLabel = item.document.displayPath.isEmpty ? item.document.path : item.document.displayPath
                return "- \(item.document.title) [`\(pathLabel)`]\n  \(item.snippet)"
            }
    }

    private func cardBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.06), Color.white.opacity(0.03)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    private func sidebar(snapshot: DashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                SharedFabricMark()
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shared Fabric")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Knowledge Console")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Surfaces")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                ForEach(DashboardSurfaceMode.allCases) { mode in
                    surfaceRailButton(mode)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Focus")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                surfaceInfoRow(title: "Scope", value: scopeLabel(snapshot))
                surfaceInfoRow(title: "Runtime", value: snapshot.runtime)
                surfaceInfoRow(title: "Phase", value: snapshot.lifecyclePhase)
            }

            Spacer()

            VStack(spacing: 8) {
                sidebarUtilityButton("Refresh", symbol: "arrow.clockwise", action: onRefresh)
                sidebarUtilityButton("Workspace", symbol: "folder", action: onOpenCurrentWorkspace)
                sidebarUtilityButton("Setup", symbol: "wrench.and.screwdriver", action: onOpenSetup)
                sidebarUtilityButton("Settings", symbol: "gearshape", action: onOpenSettings)
            }
        }
        .padding(18)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.05),
                    Color.white.opacity(0.02),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1)
        }
    }

    private func surfaceRailButton(_ mode: DashboardSurfaceMode) -> some View {
        Button {
            preferences.surfaceMode = mode
        } label: {
            HStack(spacing: 10) {
                Image(systemName: surfaceIcon(mode))
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14)
                Text(mode.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer()
                if preferences.surfaceMode == mode {
                    Circle()
                        .fill(Color(red: 0.27, green: 0.61, blue: 1.0))
                        .frame(width: 7, height: 7)
                }
            }
            .foregroundStyle(preferences.surfaceMode == mode ? .primary : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(preferences.surfaceMode == mode ? Color.white.opacity(0.08) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(preferences.surfaceMode == mode ? Color.white.opacity(0.08) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func surfaceIcon(_ mode: DashboardSurfaceMode) -> String {
        switch mode {
        case .graph:
            return "point.3.connected.trianglepath.dotted"
        case .chat:
            return "sparkles"
        case .sources:
            return "tray.and.arrow.down"
        case .wiki:
            return "book.closed"
        case .observe:
            return "eye"
        }
    }

    private func surfaceInfoRow(title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .lineLimit(1)
        }
    }

    private func sidebarUtilityButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.035))
            )
        }
        .buttonStyle(.plain)
    }

    private func toolbar(snapshot: DashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                workspaceSelector(snapshot: snapshot)
                Picker("", selection: $preferences.scopeMode) {
                    ForEach(KnowledgeScopeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                Spacer()

                metricPill("Vault", snapshot.knowledgeBaseOverview.isNormalized ? "Ready" : "Needs Work", tint: snapshot.knowledgeBaseOverview.isNormalized ? .green : .orange)
                metricPill("Graph", "\(snapshot.knowledgeGraphMeta.nodeCount)", tint: .blue)
                metricPill("Wiki", "\(snapshot.knowledgeBaseOverview.wikiPageCount)", tint: .indigo)
            }
            HStack(spacing: 10) {
                compactBooleanPill(
                    title: "Auto Follow",
                    isOn: Binding(
                        get: { preferences.workspaceMode == .auto },
                        set: { isOn in
                            if isOn {
                                preferences.setAuto()
                            } else {
                                preferences.setPinned(snapshot.workspace)
                            }
                        }
                    ),
                    tint: .blue
                )
                compactBooleanPill(title: "Question Profile", isOn: $preferences.showQuestionProfile, tint: .mint)
                compactBooleanPill(title: "Project Memory", isOn: $preferences.showProjectMemory, tint: .indigo)
                compactBooleanPill(title: "Recent Activity", isOn: $preferences.showRecentActivity, tint: .cyan)
                Spacer()
                compactToolbarButton(symbol: "chevron.left", action: onPreviousWorkspace)
                compactToolbarButton(symbol: "chevron.right", action: onNextWorkspace)
                compactToolbarButton(symbol: "list.bullet.rectangle", action: onOpenLogs)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.02))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
    }

    private func compactToolbarButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
        }
        .buttonStyle(.plain)
    }

    private func metricPill(_ label: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    private func compactBooleanPill(title: String, isOn: Binding<Bool>, tint: Color) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(isOn.wrappedValue ? tint : Color.white.opacity(0.18))
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(isOn.wrappedValue ? .primary : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(isOn.wrappedValue ? tint.opacity(0.12) : Color.white.opacity(0.03))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(isOn.wrappedValue ? tint.opacity(0.16) : Color.white.opacity(0.06), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func surfaceCanvas(snapshot: DashboardSnapshot) -> some View {
        Group {
            switch preferences.surfaceMode {
            case .graph:
                graphWorkbench(snapshot: snapshot)
            case .chat:
                chatWorkbench(snapshot: snapshot)
            case .sources:
                sourcesWorkbench(snapshot: snapshot)
            case .wiki:
                wikiWorkbench(snapshot: snapshot)
            case .observe:
                observeWorkbench(snapshot: snapshot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func graphWorkbench(snapshot: DashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                metricPill("Projects", "\(snapshot.knowledgeBaseOverview.totalProjects)", tint: .blue)
                metricPill("Pages", "\(snapshot.knowledgeBaseOverview.wikiPageCount)", tint: .cyan)
                metricPill("Legacy", "\(snapshot.knowledgeBaseOverview.legacySourceCount)", tint: .orange)
                metricPill("Focus", scopeLabel(snapshot), tint: .mint)
                Spacer()
            }
            knowledgeGraphCard(snapshot: snapshot)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if preferences.showRecentActivity {
                compactObserveStrip(snapshot: snapshot)
            }
        }
    }

    private func wikiWorkbench(snapshot: DashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            wikiStatusCard(snapshot: snapshot)
            projectUpdateLogCard(snapshot: snapshot)
            if preferences.showProjectMemory {
                projectMemoryCard(snapshot: snapshot)
            }
        }
    }

    private func observeWorkbench(snapshot: DashboardSnapshot) -> some View {
        Group {
            if preferences.scopeMode == .workspace {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        sessionCard(snapshot: snapshot)
                        phaseCard(snapshot: snapshot)
                        syncDeltaCard(snapshot: snapshot)
                        if preferences.showQuestionProfile {
                            questionProfileCard(snapshot: snapshot)
                        }
                        if preferences.showProjectMemory {
                            projectMemoryCard(snapshot: snapshot)
                        }
                    }
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        observeRollupsCard(snapshot: snapshot)
                        if preferences.showRecentActivity {
                            recentActivityCard(snapshot: snapshot)
                        }
                    }
                }
            }
        }
    }

    private func chatWorkbench(snapshot: DashboardSnapshot) -> some View {
        geminiChatCard(snapshot: snapshot)
    }

    private func sourcesWorkbench(snapshot: DashboardSnapshot) -> some View {
        sourcesCard(snapshot: snapshot)
    }

    private func inspector(snapshot: DashboardSnapshot) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                inspectorSection(title: "Status") {
                    VStack(alignment: .leading, spacing: 8) {
                        surfaceInfoRow(title: "Workspace", value: snapshot.projectName)
                        surfaceInfoRow(title: "Boot", value: snapshot.bootStatus)
                        surfaceInfoRow(title: "Sync", value: snapshot.syncStatus)
                        surfaceInfoRow(title: "Audit", value: snapshot.syncAuditSource.uppercased())
                        surfaceInfoRow(title: "MCP", value: "\(snapshot.activeMcpCount)")
                    }
                }
                inspectorSection(title: "Actions") {
                    VStack(spacing: 8) {
                        compactActionButton("Normalize Vault", symbol: "square.grid.3x3", tint: .indigo, action: onNormalizeVault)
                        compactActionButton("Process Sources", symbol: "tray.and.arrow.down", tint: .mint, action: {
                            presentSourcePrompt(snapshot: snapshot)
                        })
                        compactActionButton("Build All Prompt", symbol: "wand.and.stars", tint: .blue, action: onBuildAllProjectWikis)
                        compactActionButton("Refresh Scope", symbol: "arrow.clockwise", tint: .cyan, action: onRefreshSelectedScope)
                        compactActionButton("Ask Gemini", symbol: "sparkles", tint: .mint) {
                            preferences.surfaceMode = .chat
                        }
                    }
                }
                inspectorSection(title: "Toggles") {
                    VStack(spacing: 8) {
                        toggleTile(title: "Auto", subtitle: "", isOn: Binding(
                            get: { preferences.workspaceMode == .auto },
                            set: { isOn in
                                if isOn {
                                    preferences.setAuto()
                                } else {
                                    preferences.setPinned(snapshot.workspace)
                                }
                            }
                        ), tint: .blue)
                        toggleTile(title: "Q", subtitle: "", isOn: $preferences.showQuestionProfile, tint: .mint)
                        toggleTile(title: "Mem", subtitle: "", isOn: $preferences.showProjectMemory, tint: .indigo)
                        toggleTile(title: "Act", subtitle: "", isOn: $preferences.showRecentActivity, tint: .cyan)
                    }
                }
                inspectorContext(snapshot: snapshot)
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func inspectorContext(snapshot: DashboardSnapshot) -> some View {
        Group {
            switch preferences.surfaceMode {
            case .graph:
                inspectorSection(title: "Focus") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(filteredRollups(snapshot).prefix(5)) { rollup in
                            Button {
                                if let workspace = rollup.workspaces.first, !workspace.isEmpty {
                                    onSelectWorkspace(workspace)
                                    preferences.scopeMode = .workspace
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(rollup.attentionState == "healthy" ? Color.green : Color.orange)
                                        .frame(width: 7, height: 7)
                                    Text(rollup.projectName)
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    Spacer()
                                    Text(rollup.latestActivity)
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            case .wiki:
                inspectorSection(title: "Pages") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(wikiCards(snapshot), id: \.path) { page in
                            Button(page.title) {
                                if FileManager.default.fileExists(atPath: page.path) {
                                    onOpenPath(page.path)
                                } else {
                                    onRefreshSelectedScope()
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                        }
                    }
                }
            case .observe:
                inspectorSection(title: "Observe") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(snapshot.lastHandoff.isEmpty ? "No handoff yet." : snapshot.lastHandoff)
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(5)
                    }
                }
            case .chat:
                inspectorSection(title: "Chat") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("", selection: $preferences.geminiChatScopeMode) {
                            ForEach(KnowledgeScopeMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(chatModel.status)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            case .sources:
                inspectorSection(title: "Sources") {
                    VStack(alignment: .leading, spacing: 8) {
                        surfaceInfoRow(title: "Legacy", value: "\(snapshot.legacySources.count)")
                        surfaceInfoRow(title: "Raw", value: preferences.effectiveObsidianChatHistoryOutputDir)
                        if dataAcquisitionFeaturesEnabled {
                            compactActionButton("Export Current", symbol: "square.and.arrow.up", tint: .mint, action: onExportCurrentChats)
                            compactActionButton("Export All", symbol: "tray.full", tint: .blue, action: onExportAllChats)
                        }
                    }
                }
            }
        }
    }

    private func inspectorSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func compactActionButton(_ title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Spacer()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(tint.opacity(0.18), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func compactObserveStrip(snapshot: DashboardSnapshot) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filteredRollups(snapshot).prefix(8)) { rollup in
                    Button {
                        if let workspace = rollup.workspaces.first, !workspace.isEmpty {
                            onSelectWorkspace(workspace)
                            preferences.scopeMode = .workspace
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(rollup.attentionState == "healthy" ? Color.green : Color.orange)
                                .frame(width: 6, height: 6)
                            Text(rollup.projectName)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.04))
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var modeStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $preferences.surfaceMode) {
                ForEach(DashboardSurfaceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(preferences.surfaceMode.subtitle)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                )
        )
    }

    private func scopeStrip(snapshot: DashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text("Scope")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Picker("", selection: $preferences.scopeMode) {
                    ForEach(KnowledgeScopeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            HStack(spacing: 8) {
                StatusBadge(label: "Selected", value: scopeLabel(snapshot), color: .cyan)
                StatusBadge(label: "Vault", value: snapshot.knowledgeBaseOverview.isNormalized ? "NORMALIZED" : "UNSYNCED", color: snapshot.knowledgeBaseOverview.isNormalized ? .green : .orange)
                StatusBadge(label: "Graph", value: "\(snapshot.knowledgeGraphMeta.nodeCount) nodes", color: .blue)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func header(snapshot: DashboardSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SharedFabricMark()
            VStack(alignment: .leading, spacing: 4) {
                Text("Fabric")
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

    private func knowledgeOverviewCard(snapshot: DashboardSnapshot) -> some View {
        DashboardCard(title: "Knowledge Base", symbol: "square.stack.3d.up") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    StatusBadge(label: "Projects", value: "\(snapshot.knowledgeBaseOverview.totalProjects)", color: .blue)
                    StatusBadge(label: "Wiki Pages", value: "\(snapshot.knowledgeBaseOverview.wikiPageCount)", color: .cyan)
                    StatusBadge(label: "Legacy", value: "\(snapshot.knowledgeBaseOverview.legacySourceCount)", color: .orange)
                    StatusBadge(label: "Graph", value: "\(snapshot.knowledgeBaseOverview.graphNodeCount) / \(snapshot.knowledgeBaseOverview.graphEdgeCount)", color: .mint)
                }
                Text(snapshot.knowledgeBaseOverview.summary)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 10) {
                    librarySummaryPill(
                        title: "Vault",
                        value: snapshot.knowledgeBaseOverview.vaultRoot.isEmpty ? "Not set" : snapshot.knowledgeBaseOverview.vaultRoot,
                        subtitle: snapshot.knowledgeBaseOverview.isNormalized ? "normalized" : "needs normalization"
                    )
                    librarySummaryPill(
                        title: "Wiki",
                        value: snapshot.knowledgeBaseOverview.lastBuiltAt.isEmpty ? "Not built" : snapshot.knowledgeBaseOverview.lastBuiltAt,
                        subtitle: "last full compile"
                    )
                    librarySummaryPill(
                        title: "Observe",
                        value: scopeLabel(snapshot),
                        subtitle: "active focus scope"
                    )
                }
            }
        }
    }

    private func librarySummaryPill(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func knowledgeControlsCard(snapshot: DashboardSnapshot) -> some View {
        DashboardCard(title: "Console", symbol: "switch.2") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    actionTile(title: "Normalize Vault", subtitle: "Scaffold system pages and canonical folders", tint: .indigo, action: onNormalizeVault)
                    actionTile(title: "Process Sources", subtitle: "Generate a Gemini standardization prompt", tint: .mint, action: {
                        presentSourcePrompt(snapshot: snapshot)
                    })
                    actionTile(title: "Build All Prompt", subtitle: "Generate a Gemini snippet for source-to-wiki compilation", tint: .blue, action: onBuildAllProjectWikis)
                }
                HStack(spacing: 10) {
                    actionTile(title: "Refresh Selected Scope", subtitle: "Rebuild the current workspace or vault focus", tint: .cyan, action: onRefreshSelectedScope)
                    actionTile(title: "Ask Gemini", subtitle: "Open contextual knowledge-base chat", tint: .mint) {
                        preferences.surfaceMode = .chat
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Quick Toggles")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        toggleTile(
                            title: "Auto Follow",
                            subtitle: "Track latest active workspace",
                            isOn: Binding(
                                get: { preferences.workspaceMode == .auto },
                                set: { isOn in
                                    if isOn {
                                        preferences.setAuto()
                                    } else {
                                        preferences.setPinned(snapshot.workspace)
                                    }
                                }
                            ),
                            tint: .blue
                        )
                        toggleTile(title: "Observe Mode", subtitle: "Jump into sync and phase detail", isOn: Binding(
                            get: { preferences.surfaceMode == .observe },
                            set: { isOn in
                                if isOn {
                                    preferences.surfaceMode = .observe
                                } else if preferences.surfaceMode == .observe {
                                    preferences.surfaceMode = .graph
                                }
                            }
                        ), tint: .orange)
                        toggleTile(title: "Question Profile", subtitle: "Show distilled user overlay", isOn: $preferences.showQuestionProfile, tint: .mint)
                        toggleTile(title: "Project Memory", subtitle: "Show memory lanes in Observe/Wiki", isOn: $preferences.showProjectMemory, tint: .indigo)
                        toggleTile(title: "Recent Activity", subtitle: "Keep rollups and rounds visible", isOn: $preferences.showRecentActivity, tint: .cyan)
                    }
                }
            }
        }
    }

    private func sourcesCard(snapshot: DashboardSnapshot) -> some View {
        DashboardCard(title: "Sources", symbol: "tray.and.arrow.down") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    StatusBadge(label: "Vault", value: snapshot.legacySources.isEmpty ? "Clean" : "\(snapshot.legacySources.count) legacy", color: snapshot.legacySources.isEmpty ? .green : .orange)
                    StatusBadge(label: "Chat Exports", value: preferences.effectiveObsidianChatHistoryOutputDir, color: .mint)
                }
                if snapshot.legacySources.isEmpty {
                    Text("No legacy source folders found.")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                        ForEach(snapshot.legacySources.prefix(6)) { source in
                            Button {
                                onOpenPath(source.path)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.name)
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    Text(source.classification.uppercased())
                                        .font(.system(size: 10, weight: .regular, design: .rounded))
                                        .foregroundStyle(.secondary)
                                    Text(source.path)
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(Color.white.opacity(0.04))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .stroke(Color.white.opacity(0.07), lineWidth: 1)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if dataAcquisitionFeaturesEnabled {
                    HStack(spacing: 10) {
                        actionTile(title: "Export Current", subtitle: "Current workspace", tint: .mint, action: onExportCurrentChats)
                        actionTile(title: "Export All", subtitle: "Known workspaces", tint: .blue, action: onExportAllChats)
                    }
                }
            }
        }
    }

    private func wikiStatusCard(snapshot: DashboardSnapshot) -> some View {
        return DashboardCard(title: "Wiki", symbol: "book.closed") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusBadge(label: "Project", value: selectedKnowledgeProject(snapshot)?.name ?? "None", color: .blue)
                    StatusBadge(label: "Pages", value: "\(wikiCards(snapshot).count)", color: .indigo)
                }
                Text("Use the top toolbar for Normalize, Process Sources, and Build All.")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func knowledgeGraphCard(snapshot: DashboardSnapshot) -> some View {
        let filteredNodes = graphNodes(snapshot)
        return ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.05), Color.cyan.opacity(0.035), Color.black.opacity(0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

            if snapshot.knowledgeGraphNodes.isEmpty {
                Text("No graph yet.")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if filteredNodes.isEmpty {
                Text("No graph nodes match the current scope and visibility filters.")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                KnowledgeGraphWebView(
                    html: graphHTML(snapshot),
                    onOpenPath: onOpenPath
                )
                .padding(26)
            }

            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    showGraphControls.toggle()
                } label: {
                    Image(systemName: showGraphControls ? "slider.horizontal.3.circle.fill" : "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(showGraphControls ? .primary : .secondary)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(PressableChromeButtonStyle())

                if showGraphControls {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Semantic-first mode keeps projects, concepts, entities, keywords, clusters, and hubs visible while hiding structural noise by default.")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text("Single-click a node to inspect, drag canvas to pan, scroll or pinch to zoom, and double-click a node to open its source path.")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        Toggle(isOn: $preferences.showGraphPageNodes) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show Wiki Pages")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                Text("Reveal structural wiki page nodes like Overview or Sources.")
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        Toggle(isOn: $preferences.showGraphSourceNodes) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show Source Evidence")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                Text("Reveal raw file and provenance anchors when you want to inspect detailed evidence.")
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        HStack(spacing: 8) {
                            Text(snapshot.knowledgeGraphMeta.updatedAt.isEmpty ? "No update" : "Updated")
                            if !snapshot.knowledgeGraphMeta.updatedAt.isEmpty {
                                Text(snapshot.knowledgeGraphMeta.updatedAt)
                                    .lineLimit(1)
                            }
                        }
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(width: 280, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(16)

            VStack(alignment: .leading, spacing: 8) {
                Text("Graph")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("Interactive Obsidian knowledge graph")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    miniInfoPill("\(snapshot.knowledgeGraphMeta.nodeCount) nodes")
                    miniInfoPill("\(snapshot.knowledgeGraphMeta.edgeCount) edges")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func observeRollupsCard(snapshot: DashboardSnapshot) -> some View {
        DashboardCard(title: "Observe", symbol: "eye") {
            VStack(alignment: .leading, spacing: 12) {
                if filteredRollups(snapshot).isEmpty {
                    Text("No project rollups are available yet.")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                        ForEach(filteredRollups(snapshot)) { rollup in
                            Button {
                                if let workspace = rollup.workspaces.first, !workspace.isEmpty {
                                    onSelectWorkspace(workspace)
                                    preferences.scopeMode = .workspace
                                    preferences.surfaceMode = .observe
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(rollup.projectName)
                                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        Spacer()
                                        attentionPill(rollup.attentionState)
                                    }
                                    Text(rollup.latestFocus.isEmpty ? "No focus summary yet." : rollup.latestFocus)
                                        .font(.system(size: 10, weight: .regular, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                    HStack(spacing: 8) {
                                        summaryMetric(label: "Decision", value: "\(rollup.decisionCount)")
                                        summaryMetric(label: "Loop", value: "\(rollup.openLoopCount)")
                                        summaryMetric(label: "Learn", value: "\(rollup.learningCount)")
                                    }
                                    Text(rollup.latestActivity.isEmpty ? "No sync timestamp" : rollup.latestActivity)
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Color.white.opacity(0.045))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func geminiChatCard(snapshot: DashboardSnapshot) -> some View {
        DashboardCard(title: "Gemini", symbol: "sparkles") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Picker("", selection: $preferences.geminiChatScopeMode) {
                        ForEach(KnowledgeScopeMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(chatModel.status)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                TextEditor(text: $chatModel.prompt)
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .frame(minHeight: 110)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(0.045))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                    )
                HStack(spacing: 10) {
                    actionTile(title: chatModel.isRunning ? "Running…" : "Ask Gemini", subtitle: "Use the selected knowledge scope", tint: .mint, action: onSubmitGeminiQuery)
                        .disabled(chatModel.isRunning || chatModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    actionTile(title: "Clear", subtitle: "Reset the knowledge-base panel", tint: .gray, action: onClearGeminiChat)
                }
                ScrollView {
                    Text(chatModel.response.isEmpty ? "Responses appear here." : chatModel.response)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(chatModel.response.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                                )
                        )
                }
                .frame(minHeight: 220)
            }
        }
    }

    private func wikiCards(_ snapshot: DashboardSnapshot) -> [KnowledgeDocument] {
        let project = selectedKnowledgeProject(snapshot)
        guard let project else { return [] }
        let projectRoot = URL(fileURLWithPath: project.wikiRoot)
        return [
            KnowledgeDocument(title: "Overview", path: projectRoot.appendingPathComponent("Overview.md").path),
            KnowledgeDocument(title: "Current Status", path: projectRoot.appendingPathComponent("Current Status.md").path),
            KnowledgeDocument(title: "Architecture", path: projectRoot.appendingPathComponent("Architecture.md").path),
            KnowledgeDocument(title: "Decisions", path: projectRoot.appendingPathComponent("Decisions.md").path),
            KnowledgeDocument(title: "Open Questions", path: projectRoot.appendingPathComponent("Open Questions.md").path),
            KnowledgeDocument(title: "Sources", path: projectRoot.appendingPathComponent("Sources.md").path),
        ]
    }

    private func scopeLabel(_ snapshot: DashboardSnapshot) -> String {
        switch preferences.scopeMode {
        case .allVault:
            return "All Vault"
        case .project:
            return selectedKnowledgeProject(snapshot)?.name ?? snapshot.selectedScope.projectName
        case .workspace:
            return snapshot.projectName
        }
    }

    private func selectedKnowledgeProject(_ snapshot: DashboardSnapshot) -> KnowledgeProjectSummary? {
        switch preferences.scopeMode {
        case .allVault:
            return snapshot.knowledgeProjects.first
        case .project:
            if let match = snapshot.knowledgeProjects.first(where: { $0.workspace == snapshot.workspace || $0.name == snapshot.selectedScope.projectName }) {
                return match
            }
            return snapshot.knowledgeProjects.first
        case .workspace:
            return snapshot.knowledgeProjects.first(where: { $0.workspace == snapshot.workspace }) ?? snapshot.knowledgeProjects.first
        }
    }

    private func normalizedGraphMatchKey(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = value.lowercased().unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    private func filteredRollups(_ snapshot: DashboardSnapshot) -> [ObserveRollup] {
        switch preferences.scopeMode {
        case .allVault:
            return snapshot.observeRollups
        case .project:
            let currentProject = snapshot.selectedScope.projectName
            return snapshot.observeRollups.filter { $0.projectName == currentProject || $0.slug == selectedKnowledgeProject(snapshot)?.slug }
        case .workspace:
            return snapshot.observeRollups.filter { rollup in
                rollup.workspaces.contains(snapshot.workspace)
            }
        }
    }

    private func scopedGraphNodeIDs(_ snapshot: DashboardSnapshot) -> Set<String> {
        if preferences.scopeMode == .allVault {
            return Set(snapshot.knowledgeGraphNodes.map(\.id))
        }
        let selectedProjectSlug = selectedKnowledgeProject(snapshot)?.slug ?? ""
        let selectedProjectName = selectedKnowledgeProject(snapshot)?.name ?? snapshot.selectedScope.projectName
        let selectedWorkspace = snapshot.workspace
        let slugKey = normalizedGraphMatchKey(selectedProjectSlug)
        let projectKey = normalizedGraphMatchKey(selectedProjectName)
        let workspaceKey = normalizedGraphMatchKey(URL(fileURLWithPath: selectedWorkspace).lastPathComponent)
        let seed = snapshot.knowledgeGraphNodes.filter { node in
            let scopeKey = normalizedGraphMatchKey(node.scope)
            let workspaceNodeKey = normalizedGraphMatchKey(node.workspace)
            let pathKey = normalizedGraphMatchKey(node.path)
            let labelKey = normalizedGraphMatchKey(node.label)
            let idKey = normalizedGraphMatchKey(node.id)

            let directProjectMatch =
                (!slugKey.isEmpty && (scopeKey == slugKey || idKey.contains(slugKey) || labelKey.contains(slugKey) || pathKey.contains(slugKey) || workspaceNodeKey.contains(slugKey))) ||
                (!projectKey.isEmpty && (labelKey.contains(projectKey) || pathKey.contains(projectKey) || workspaceNodeKey.contains(projectKey) || idKey.contains(projectKey))) ||
                (!workspaceKey.isEmpty && (workspaceNodeKey.contains(workspaceKey) || pathKey.contains(workspaceKey)))

            if preferences.scopeMode == .workspace {
                return (!snapshot.workspace.isEmpty && node.workspace == snapshot.workspace) || (!selectedProjectSlug.isEmpty && node.scope == selectedProjectSlug) || directProjectMatch
            }
            return (!selectedProjectSlug.isEmpty && node.scope == selectedProjectSlug) || directProjectMatch
        }
        let seedIDs = Set(seed.map(\.id))
        var ids = seedIDs
        if ids.isEmpty {
            return []
        }
        for edge in snapshot.knowledgeGraphEdges {
            if seedIDs.contains(edge.source) || seedIDs.contains(edge.target) {
                ids.insert(edge.source)
                ids.insert(edge.target)
            }
        }
        return ids
    }

    private func graphNodes(_ snapshot: DashboardSnapshot) -> [KnowledgeGraphNode] {
        let scopedIDs = scopedGraphNodeIDs(snapshot)
        if preferences.scopeMode != .allVault && scopedIDs.isEmpty {
            return []
        }
        let filteredBySearch = snapshot.knowledgeGraphNodes.filter { node in
            guard scopedIDs.contains(node.id) else { return false }
            guard shouldIncludeGraphNodeKind(node.kind) else { return false }
            return true
        }
        let prioritized = filteredBySearch.sorted { lhs, rhs in
            let leftPriority = graphNodeSortPriority(lhs.kind)
            let rightPriority = graphNodeSortPriority(rhs.kind)
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
        let limit = preferences.scopeMode == .allVault ? 320 : 220
        return Array(prioritized.prefix(limit))
    }

    private func shouldIncludeGraphNodeKind(_ kind: String) -> Bool {
        switch kind {
        case "page":
            return preferences.showGraphPageNodes
        case "source", "source-item", "source-family", "source-library":
            return preferences.showGraphSourceNodes
        default:
            return true
        }
    }

    private func graphEdges(_ snapshot: DashboardSnapshot, nodes: [KnowledgeGraphNode]) -> [KnowledgeGraphEdge] {
        let ids = Set(nodes.map(\.id))
        return snapshot.knowledgeGraphEdges.filter { ids.contains($0.source) && ids.contains($0.target) }
    }

    private func graphHTML(_ snapshot: DashboardSnapshot) -> String {
        let nodes = graphNodes(snapshot)
        let edges = graphEdges(snapshot, nodes: nodes)
        return graphHTMLDocument(nodes: nodes, edges: edges, scopeLabel: scopeLabel(snapshot))
    }

    private func graphHTMLDocument(nodes: [KnowledgeGraphNode], edges: [KnowledgeGraphEdge], scopeLabel: String) -> String {
        let degreeCounts = graphDegreeCounts(edges: edges)
        let nodeObjects = nodes.map { node in
            [
                "id": node.id,
                "label": node.label,
                "kind": node.kind,
                "path": node.path,
                "group": node.kind,
                "color": graphNodeHexColor(node.kind),
                "size": graphNodeSizeValue(node, degree: degreeCounts[node.id] ?? 0),
                "fontSize": graphNodeFontSizeValue(node, degree: degreeCounts[node.id] ?? 0),
                "title": graphNodeTooltip(node)
            ]
        }
        let edgeObjects = edges.enumerated().map { index, edge in
            [
                "id": "\(index)",
                "from": edge.source,
                "to": edge.target,
                "kind": edge.kind,
                "title": edge.kind
            ]
        }
        let legendObjects = graphLegendObjects(nodes: nodes)
        let nodesJSON = graphJSONString(nodeObjects)
        let edgesJSON = graphJSONString(edgeObjects)
        let legendJSON = graphJSONString(legendObjects)
        let escapedScope = graphEscapedHTML(scopeLabel)

        return """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<script src="vendor/vis-network.min.js"></script>
<style>
  html, body { margin: 0; width: 100%; height: 100%; background: transparent; overflow: hidden; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
  #graph { position: absolute; inset: 0; background:
      radial-gradient(circle at 18% 20%, rgba(81, 126, 255, 0.12), transparent 28%),
      radial-gradient(circle at 82% 28%, rgba(44, 208, 182, 0.10), transparent 24%),
      radial-gradient(circle at 50% 100%, rgba(255,255,255,0.04), transparent 30%),
      linear-gradient(180deg, rgba(15,18,29,0.88), rgba(10,12,19,0.96)); }
  #toolbar { position: absolute; top: 86px; left: 18px; display: flex; align-items: center; gap: 10px; z-index: 4; }
  #search { width: 180px; padding: 8px 10px; border-radius: 10px; border: 1px solid rgba(255,255,255,0.12); background: rgba(10,12,19,0.76); color: #edf1ff; font-size: 12px; outline: none; backdrop-filter: blur(12px); }
  #fit { padding: 8px 10px; border-radius: 10px; border: 1px solid rgba(255,255,255,0.12); background: rgba(10,12,19,0.76); color: #edf1ff; font-size: 12px; cursor: pointer; backdrop-filter: blur(12px); }
  #legend { position: absolute; top: 86px; right: 18px; z-index: 4; min-width: 170px; max-width: 240px; padding: 12px; border-radius: 14px; border: 1px solid rgba(255,255,255,0.10); background: rgba(10,12,19,0.78); color: #d8def4; backdrop-filter: blur(14px); }
  #legend-title { font-size: 11px; font-weight: 700; letter-spacing: 0.06em; text-transform: uppercase; color: #99a3c7; margin-bottom: 8px; }
  .legend-row { display: flex; align-items: center; gap: 8px; font-size: 11px; margin-bottom: 6px; }
  .legend-dot { width: 10px; height: 10px; border-radius: 999px; flex: 0 0 auto; }
  .legend-label { flex: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .legend-count { color: #7f89aa; }
  #status { position: absolute; left: 14px; bottom: 14px; z-index: 4; padding: 10px 12px; border-radius: 12px; border: 1px solid rgba(255,255,255,0.10); background: rgba(10,12,19,0.78); color: #d8def4; font-size: 12px; max-width: 360px; backdrop-filter: blur(14px); }
</style>
</head>
<body>
<div id="graph"></div>
<div id="toolbar">
  <input id="search" type="text" placeholder="Search nodes">
  <button id="fit">Fit</button>
</div>
<div id="legend">
  <div id="legend-title">Scope: \(escapedScope)</div>
  <div id="legend-list"></div>
</div>
<div id="status">Drag to pan, scroll to zoom, double-click a node to open its source.</div>
<script>
const RAW_NODES = \(nodesJSON);
const RAW_EDGES = \(edgesJSON);
const LEGEND = \(legendJSON);
const GRAPH_KEY = (() => {
  const nodeSignature = RAW_NODES.map(node => node.id).join('|');
  const edgeSignature = RAW_EDGES.map(edge => `${edge.from}>${edge.to}:${edge.kind}`).join('|');
  return `ag-knowledge-graph::${nodeSignature}::${edgeSignature}`;
})();

function loadCachedPositions() {
  try {
    const payload = window.localStorage.getItem(GRAPH_KEY);
    return payload ? JSON.parse(payload) : {};
  } catch (error) {
    return {};
  }
}

const cachedPositions = loadCachedPositions();
const cachedPositionCount = RAW_NODES.filter(node => cachedPositions[node.id]).length;
const useCachedLayout = RAW_NODES.length > 0 && cachedPositionCount >= Math.max(4, Math.floor(RAW_NODES.length * 0.8));

const nodesDS = new vis.DataSet(RAW_NODES.map(node => ({
  id: node.id,
  label: node.label,
  title: node.title,
  color: {
    background: node.color,
    border: node.color,
    highlight: { background: '#ffffff', border: node.color }
  },
  size: node.size,
  font: { size: node.fontSize, color: '#eef2ff', face: '-apple-system' },
  group: node.group,
  path: node.path,
  kind: node.kind,
  x: useCachedLayout && cachedPositions[node.id] ? cachedPositions[node.id].x : undefined,
  y: useCachedLayout && cachedPositions[node.id] ? cachedPositions[node.id].y : undefined
})));

const edgesDS = new vis.DataSet(RAW_EDGES.map(edge => ({
  id: edge.id,
  from: edge.from,
  to: edge.to,
  title: edge.title,
  color: { color: 'rgba(255,255,255,0.18)', highlight: '#93c5fd', hover: 'rgba(255,255,255,0.36)' },
  width: edge.kind === 'semantic' || edge.kind === 'entity' ? 1.6 : 1.0,
  smooth: { type: 'continuous', roundness: 0.18 }
})));

const container = document.getElementById('graph');
const statusEl = document.getElementById('status');
const searchEl = document.getElementById('search');

const network = new vis.Network(container, { nodes: nodesDS, edges: edgesDS }, {
  layout: {
    improvedLayout: true,
    randomSeed: 17
  },
  physics: {
    enabled: !useCachedLayout,
    solver: 'forceAtlas2Based',
    forceAtlas2Based: {
      gravitationalConstant: -58,
      centralGravity: 0.005,
      springLength: 118,
      springConstant: 0.085,
      damping: 0.42,
      avoidOverlap: 0.82
    },
    stabilization: { iterations: 220, fit: true }
  },
  interaction: {
    hover: true,
    hideEdgesOnDrag: true,
    tooltipDelay: 80,
    zoomView: true,
    dragView: true,
    multiselect: false
  },
  nodes: {
    shape: 'dot',
    borderWidth: 1.5,
    scaling: { min: 8, max: 34 }
  },
  edges: {
    selectionWidth: 2.2,
    smooth: { type: 'continuous', roundness: 0.18 }
  }
});

const nodeMap = Object.fromEntries(RAW_NODES.map(node => [node.id, node]));
let layoutFrozen = useCachedLayout;

function persistPositions() {
  try {
    const positions = network.getPositions();
    const payload = {};
    Object.keys(positions).forEach(id => {
      payload[id] = {
        x: Math.round(positions[id].x * 100) / 100,
        y: Math.round(positions[id].y * 100) / 100
      };
    });
    window.localStorage.setItem(GRAPH_KEY, JSON.stringify(payload));
  } catch (error) {
  }
}

function freezeLayout() {
  if (layoutFrozen) {
    return;
  }
  layoutFrozen = true;
  network.stopSimulation();
  network.setOptions({ physics: { enabled: false } });
  persistPositions();
}

if (useCachedLayout) {
  window.setTimeout(() => {
    network.redraw();
    updateStatus(null);
  }, 0);
} else {
  network.once('stabilizationIterationsDone', freezeLayout);
  window.setTimeout(freezeLayout, 1400);
}

function updateStatus(nodeId) {
  if (!nodeId || !nodeMap[nodeId]) {
    statusEl.textContent = 'Drag to pan, scroll to zoom, double-click a node to open its source.';
    return;
  }
  const node = nodeMap[nodeId];
  const neighborCount = network.getConnectedNodes(nodeId).length;
  statusEl.textContent = `${node.label} · ${node.kind} · ${neighborCount} links`;
}

network.on('click', params => {
  const nodeId = params.nodes.length ? params.nodes[0] : null;
  updateStatus(nodeId);
});

network.on('doubleClick', params => {
  if (!params.nodes.length) return;
  const node = nodeMap[params.nodes[0]];
  if (node && node.path && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.graphOpenNode) {
    window.webkit.messageHandlers.graphOpenNode.postMessage(node.path);
  }
});

network.on('dragEnd', () => {
  persistPositions();
});

document.getElementById('fit').addEventListener('click', () => {
  network.fit({ animation: { duration: 240, easingFunction: 'easeInOutQuad' } });
});

searchEl.addEventListener('keydown', event => {
  if (event.key !== 'Enter') return;
  const query = searchEl.value.trim().toLowerCase();
  if (!query) return;
  const match = RAW_NODES.find(node => node.label.toLowerCase().includes(query));
  if (!match) return;
  network.selectNodes([match.id]);
  network.focus(match.id, { scale: 1.45, animation: { duration: 220, easingFunction: 'easeInOutQuad' } });
  updateStatus(match.id);
});

const legendRoot = document.getElementById('legend-list');
LEGEND.forEach(item => {
  const row = document.createElement('div');
  row.className = 'legend-row';
  row.innerHTML = `<span class="legend-dot" style="background:${item.color}"></span><span class="legend-label">${item.label}</span><span class="legend-count">${item.count}</span>`;
  legendRoot.appendChild(row);
});
</script>
</body>
</html>
"""
    }

    private func graphDegreeCounts(edges: [KnowledgeGraphEdge]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for edge in edges {
            counts[edge.source, default: 0] += 1
            counts[edge.target, default: 0] += 1
        }
        return counts
    }

    private func graphLegendObjects(nodes: [KnowledgeGraphNode]) -> [[String: Any]] {
        let grouped = Dictionary(grouping: nodes, by: \.kind)
        return grouped.keys.sorted().map { kind in
            [
                "label": graphKindLabel(kind),
                "count": grouped[kind]?.count ?? 0,
                "color": graphNodeHexColor(kind)
            ]
        }
    }

    private func graphJSONString(_ object: Any) -> String {
        guard
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            var string = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        string = string.replacingOccurrences(of: "</", with: "<\\/")
        return string
    }

    private func javascriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              var string = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        string = string.replacingOccurrences(of: "</", with: "<\\/")
        return string
    }

    private func graphEscapedHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func graphNodeSortPriority(_ kind: String) -> Int {
        switch kind {
        case "vault":
            return 0
        case "hub":
            return 1
        case "project":
            return 2
        case "workspace":
            return 3
        case "cluster":
            return 4
        case "concept":
            return 5
        case "entity":
            return 6
        case "keyword":
            return 7
        case "page":
            return 8
        case "source-family", "source-library":
            return 9
        case "source-item", "source":
            return 10
        default:
            return 11
        }
    }

    private func graphNodeHexColor(_ kind: String) -> String {
        switch kind {
        case "vault":
            return "#42c7f5"
        case "hub":
            return "#22d3ee"
        case "project":
            return "#3b82f6"
        case "workspace":
            return "#22c7a4"
        case "cluster":
            return "#c084fc"
        case "concept":
            return "#e2e8f0"
        case "page":
            return "#7c8cff"
        case "keyword":
            return "#facc15"
        case "entity":
            return "#fb7185"
        case "source-family", "source-library":
            return "#8b5cf6"
        case "source-item", "source":
            return "#64748b"
        case "legacy":
            return "#f59e0b"
        default:
            return "#cbd5e1"
        }
    }

    private func graphKindLabel(_ kind: String) -> String {
        switch kind {
        case "concept":
            return "Concept"
        case "source":
            return "Source"
        case "source-library":
            return "Source Library"
        case "source-family":
            return "Source Family"
        case "source-item":
            return "Source Item"
        default:
            return kind.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    private func graphNodeSizeValue(_ node: KnowledgeGraphNode, degree: Int) -> Double {
        switch node.kind {
        case "vault":
            return 28
        case "hub":
            return degree >= 5 ? 20 : 18
        case "project":
            return 20
        case "workspace":
            return 17
        case "cluster":
            return degree >= 4 ? 16 : 14
        case "concept":
            return degree >= 4 ? 13 : 11
        case "page":
            return degree >= 4 ? 13 : 11
        case "entity":
            return degree >= 3 ? 12 : 10
        case "keyword":
            return degree >= 3 ? 11 : 9
        case "source-family", "source-library":
            return 12
        case "source-item", "source":
            return 7
        default:
            return 9
        }
    }

    private func graphNodeFontSizeValue(_ node: KnowledgeGraphNode, degree: Int) -> Int {
        switch node.kind {
        case "vault":
            return 16
        case "hub":
            return 12
        case "project":
            return 14
        case "workspace":
            return 13
        case "cluster":
            return degree >= 4 ? 11 : 0
        case "concept":
            return degree >= 4 ? 10 : 0
        case "page":
            return degree >= 4 ? 11 : 0
        case "entity":
            return degree >= 4 ? 10 : 0
        case "keyword":
            return degree >= 5 ? 10 : 0
        default:
            return 0
        }
    }

    private func graphNodeTooltip(_ node: KnowledgeGraphNode) -> String {
        let path = node.path.isEmpty ? "No path" : node.path
        return graphEscapedHTML("\(node.label)\n\(graphKindLabel(node.kind))\n\(path)")
    }

    private func attentionPill(_ state: String) -> some View {
        let color: Color = switch state {
        case "healthy":
            .green
        case "active_pending_sync":
            .blue
        case "missing_learning_receipt", "synced_without_learning":
            .orange
        default:
            .secondary
        }
        return Text(state.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(color.opacity(0.18)))
    }

    private func summaryMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
    }

    private func actionTile(title: String, subtitle: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(subtitle)
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tint.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(tint.opacity(0.18), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func toggleTile(title: String, subtitle: String, isOn: Binding<Bool>, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(tint)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
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
                Text(snapshot.sixStageNote.isEmpty ? "Waiting for phase note." : snapshot.sixStageNote)
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
                            action: { presentedModal = .syncTarget(key) }
                        )
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Learned")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    if snapshot.lastSyncDelta.learnedItems.isEmpty {
                        Text("No learnings recorded.")
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

    private func questionProfileCard(snapshot: DashboardSnapshot) -> some View {
        DashboardCard(title: "Question Profile", symbol: "person.text.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusBadge(
                        label: "Global",
                        value: "\(snapshot.userQuestionProfile.snapshotCount)",
                        color: snapshot.userQuestionProfile.snapshotCount > 0 ? .blue : .secondary
                    )
                    StatusBadge(
                        label: "Workspace",
                        value: "\(snapshot.userQuestionProfile.workspaceSnapshotCount)",
                        color: snapshot.userQuestionProfile.workspaceSnapshotCount > 0 ? .mint : .secondary
                    )
                }
                HStack(alignment: .top, spacing: 10) {
                    questionProfilePreview(
                        title: "Global",
                        subtitle: "Cross-project questioning style",
                        profile: snapshot.userQuestionProfile.globalProfile,
                        tint: .blue,
                        scope: "global"
                    )
                    questionProfilePreview(
                        title: "Workspace",
                        subtitle: "Project-specific overlay",
                        profile: snapshot.userQuestionProfile.workspaceProfile,
                        tint: .mint,
                        scope: "workspace"
                    )
                }
            }
        }
    }

    private func questionProfilePreview(
        title: String,
        subtitle: String,
        profile: QuestionProfileDocument,
        tint: Color,
        scope: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text(subtitle)
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !profile.updatedAt.isEmpty {
                    Text(profile.updatedAt)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Text(profile.summary)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(profile.isPlaceholder ? .secondary : .primary)
                .lineLimit(3)
            Text(profile.preview.isEmpty ? "No additional distilled detail is available yet." : profile.preview)
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(4)
            HStack(spacing: 8) {
                Button("View") {
                    onOpenQuestionProfile(scope)
                }
                .buttonStyle(.bordered)

                if !profile.path.isEmpty {
                    Button("Open File") {
                        onOpenPath(profile.path)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(tint.opacity(0.16), lineWidth: 1)
                )
        )
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

    private func projectUpdateLogCard(snapshot: DashboardSnapshot) -> some View {
        DashboardCard(title: "Update Log", symbol: "text.document") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusBadge(
                        label: "Lang",
                        value: snapshot.projectUpdateLog.preferredLanguage.uppercased(),
                        color: snapshot.projectUpdateLog.preferredLanguage == "zh" ? .mint : .blue
                    )
                    StatusBadge(
                        label: "Tasks",
                        value: "\(snapshot.projectUpdateLog.sourceTaskCount)",
                        color: snapshot.projectUpdateLog.sourceTaskCount > 0 ? .blue : .secondary
                    )
                    StatusBadge(
                        label: "Records",
                        value: "\(snapshot.projectUpdateLog.sourceRecordCount)",
                        color: snapshot.projectUpdateLog.sourceRecordCount > 0 ? .indigo : .secondary
                    )
                }
                Text(snapshot.projectUpdateLog.summary)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(snapshot.projectUpdateLog.isAvailable ? .primary : .secondary)
                    .lineLimit(3)
                Text(snapshot.projectUpdateLog.preview.isEmpty ? "The update log will summarize recent project memory once records are available." : snapshot.projectUpdateLog.preview)
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                HStack {
                    if !snapshot.projectUpdateLog.updatedAt.isEmpty {
                        Text("Updated \(snapshot.projectUpdateLog.updatedAt)")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Update Log") {
                        onOpenUpdateLog()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
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
            Button(action: onOpenUpdateLog) {
                Label("Update Log", systemImage: "text.document")
            }
            .buttonStyle(.bordered)

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
                Label("Runtime Logs", systemImage: "list.bullet.rectangle")
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
    private enum AuxiliaryPanelKind {
        case observe
        case gemini
    }

    private struct SnapshotRequest {
        let script: String
        let workspace: String?
        let globalRoot: String
        let geminiSettings: String?
        let vaultRoot: String?
        let snapshotMode: String
    }

    private let config: DashboardConfig
    let preferences: DashboardPreferences
    private let viewModel = DashboardViewModel()
    private let chatModel = GeminiChatViewModel()
    private let auxiliaryPanels = AuxiliaryPanelState()
    private var shellSession: EmbeddedShellSession
    private let onClose: (FloatingDashboardController) -> Void
    private let onSnapshotUpdate: (FloatingDashboardController) -> Void

    private var panel: NSWindow!
    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var setupViewModel: SetupAssistantViewModel?
    private var projectMemoryWindow: NSWindow?
    private var questionProfileWindow: NSWindow?
    private var updateLogWindow: NSWindow?
    private var operationLogWindow: NSWindow?
    private var sourcePromptWindow: NSWindow?
    private var buildAllPromptWindow: NSWindow?
    private var observePanelWindow: NSPanel?
    private var geminiPanelWindow: NSPanel?
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var chatHistoryExportTask: Task<Void, Never>?
    private var obsidianWikiTask: Task<Void, Never>?
    private var geminiTask: Task<Void, Never>?
    private var pendingRefresh = false
    private var pendingRefreshOperationID: String?
    private var refreshSequence = 0
    private var cancellables = Set<AnyCancellable>()

    init(
        config: DashboardConfig,
        preferences: DashboardPreferences,
        onClose: @escaping (FloatingDashboardController) -> Void,
        onSnapshotUpdate: @escaping (FloatingDashboardController) -> Void
    ) {
        self.config = config
        self.preferences = preferences
        self.shellSession = EmbeddedShellSession(workingDirectory: preferences.effectiveObsidianVaultRoot ?? config.repositoryRoot ?? FileManager.default.currentDirectoryPath)
        self.onClose = onClose
        self.onSnapshotUpdate = onSnapshotUpdate
        super.init()
        observePreferences()
    }

    var window: NSWindow? {
        panel
    }

    var currentSnapshot: DashboardSnapshot? {
        viewModel.snapshot
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
        if let closed = notification.object as? NSWindow, closed === questionProfileWindow {
            questionProfileWindow = nil
            return
        }
        if let closed = notification.object as? NSWindow, closed === updateLogWindow {
            updateLogWindow = nil
            return
        }
        if let closed = notification.object as? NSWindow, closed === operationLogWindow {
            operationLogWindow = nil
            return
        }
        if let closed = notification.object as? NSWindow, closed === sourcePromptWindow {
            sourcePromptWindow = nil
            return
        }
        if let closed = notification.object as? NSWindow, closed === buildAllPromptWindow {
            buildAllPromptWindow = nil
            return
        }
        if let closed = notification.object as? NSWindow, closed === observePanelWindow {
            observePanelWindow = nil
            auxiliaryPanels.showObservePanel = false
            return
        }
        if let closed = notification.object as? NSWindow, closed === geminiPanelWindow {
            geminiPanelWindow = nil
            auxiliaryPanels.showGeminiPanel = false
            return
        }
        refreshTimer?.invalidate()
        refreshTask?.cancel()
        chatHistoryExportTask?.cancel()
        obsidianWikiTask?.cancel()
        geminiTask?.cancel()
        shellSession.stop()
        refreshTask = nil
        chatHistoryExportTask = nil
        obsidianWikiTask = nil
        geminiTask = nil
        pendingRefresh = false
        settingsWindow?.close()
        setupWindow?.close()
        projectMemoryWindow?.close()
        questionProfileWindow?.close()
        updateLogWindow?.close()
        operationLogWindow?.close()
        observePanelWindow?.close()
        geminiPanelWindow?.close()
        onSnapshotUpdate(self)
        onClose(self)
    }

    func windowDidMove(_ notification: Notification) {
        guard let moved = notification.object as? NSWindow, moved === panel else { return }
        syncAuxiliaryPanelFrames()
    }

    func windowDidResize(_ notification: Notification) {
        guard let resized = notification.object as? NSWindow else { return }
        if resized === panel {
            syncAuxiliaryPanelFrames()
            return
        }
        if let observePanelWindow, resized === observePanelWindow {
            syncAuxiliaryPanelFrame(observePanelWindow, kind: .observe)
            return
        }
        if let geminiPanelWindow, resized === geminiPanelWindow {
            syncAuxiliaryPanelFrame(geminiPanelWindow, kind: .gemini)
        }
    }

    func refreshNow() {
        let request = makeSnapshotRequest()
        let operationID = viewModel.beginOperation(
            "Refreshing Fabric",
            detail: "Reloading Fabric state from on-disk project and knowledge-base data.",
            commandPreview: snapshotCommandPreview(for: request),
            workspace: preferences.effectiveWorkspaceArgument ?? ""
        )
        refresh(operationID: operationID)
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

    func openOperationLogWindow() {
        if let operationLogWindow {
            operationLogWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 300, y: 260, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Runtime Logs"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let rootView = OperationLogDetailView(
            viewModel: viewModel,
            onOpenSyncFolder: { [weak self] in self?.openSyncFolder() },
            onClose: { [weak self] in
                self?.operationLogWindow?.close()
                self?.operationLogWindow = nil
            }
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let contentView = NSView()
        contentView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: contentView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        window.contentView = contentView
        operationLogWindow = window
        centerWindowOnMainPanel(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func allowedOpenRoots() -> [URL] {
        var paths = [preferences.effectiveGlobalRoot, preferences.effectiveObsidianVaultRoot, config.repositoryRoot]
        if let snapshot = viewModel.snapshot {
            paths.append(snapshot.workspace)
            paths.append(contentsOf: snapshot.availableWorkspaces.map(\.path))
        }
        let uniquePaths = Array(Set(paths.compactMap { raw in
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }))
        return uniquePaths.map { URL(fileURLWithPath: $0) }
    }

    private func resolveOpenTarget(_ target: String) throws -> URL {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenTargetError.pathOutsideAllowedRoots(target)
        }
        if let remoteURL = URL(string: trimmed), let scheme = remoteURL.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            throw OpenTargetError.remoteURLNotAllowed(remoteURL.absoluteString)
        }

        let localPath: String
        if let fileURL = URL(string: trimmed), fileURL.isFileURL {
            localPath = fileURL.path
        } else {
            localPath = trimmed
        }
        let candidate = URL(fileURLWithPath: localPath)
        let roots = allowedOpenRoots()
        guard isContained(candidate, in: roots) else {
            throw OpenTargetError.pathOutsideAllowedRoots(localPath)
        }
        return normalizedFileURL(candidate)
    }

    func openPath(_ path: String) {
        do {
            let url = try resolveOpenTarget(path)
            NSWorkspace.shared.open(url)
        } catch {
            viewModel.apply(error: error)
        }
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
            onChooseObsidianVaultRoot: { [weak self] in self?.chooseObsidianVaultRoot() },
            onNormalizeObsidianVault: { [weak self] in self?.normalizeObsidianVaultLayout() },
            onProcessObsidianSources: { [weak self] in self?.processObsidianSources() },
            onBuildAllProjectWikis: { [weak self] in self?.buildAllProjectWikis() },
            onExportAgentChatHistoryNow: { [weak self] in self?.exportAgentChatHistoryNow(force: true) },
            onExportAllKnownWorkspaces: { [weak self] in self?.exportAllKnownWorkspaceChatHistory() },
            onResetDefaults: { [weak self] in
                guard let self else { return }
                self.preferences.resetToDefaults(config: self.config)
            }
        )
        let hosting = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 280, y: 280, width: 540, height: 470),
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
        if let projectMemoryWindow {
            projectMemoryWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        loadDetailedSnapshot { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                self.presentProjectMemoryWindow(snapshot: snapshot, initialLane: initialLane)
            case .failure(let error):
                self.viewModel.apply(error: error)
            }
        }
    }

    func openQuestionProfileWindow(scope: String) {
        loadDetailedSnapshot { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                let profile = scope == "workspace"
                    ? snapshot.userQuestionProfile.workspaceProfile
                    : snapshot.userQuestionProfile.globalProfile
                let title = scope == "workspace" ? "Workspace Question Overlay" : "Global Question Profile"
                self.presentQuestionProfileWindow(title: title, profile: profile)
            case .failure(let error):
                self.viewModel.apply(error: error)
            }
        }
    }

    func openUpdateLogWindow() {
        loadDetailedSnapshot { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                self.presentUpdateLogWindow(updateLog: snapshot.projectUpdateLog)
            case .failure(let error):
                self.viewModel.apply(error: error)
            }
        }
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
        refreshTimer = Timer.scheduledTimer(withTimeInterval: effectiveRefreshInterval(), repeats: false) { [weak self] _ in
            self?.refresh()
            self?.resetRefreshTimer()
        }
    }

    private func effectiveRefreshInterval() -> TimeInterval {
        let base = max(1.0, preferences.refreshInterval)
        let isForegroundWindow = (panel?.isVisible ?? false) && !(panel?.isMiniaturized ?? false) && NSApp.isActive
        return isForegroundWindow ? base : max(15.0, base * 6.0)
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

    private func chooseObsidianVaultRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Obsidian Vault"
        if panel.runModal() == .OK, let url = panel.url {
            preferences.obsidianVaultRoot = url.path
        }
    }

    private func closeProjectMemoryWindow() {
        projectMemoryWindow?.close()
        projectMemoryWindow = nil
    }

    private func closeQuestionProfileWindow() {
        questionProfileWindow?.close()
        questionProfileWindow = nil
    }

    private func closeUpdateLogWindow() {
        updateLogWindow?.close()
        updateLogWindow = nil
    }

    func toggleObservePanel() {
        if auxiliaryPanels.showObservePanel {
            closeObservePanel()
        } else {
            closeGeminiPanel()
            auxiliaryPanels.showObservePanel = true
            openAuxiliaryPanel(.observe)
        }
    }

    func showObservePanel() {
        if auxiliaryPanels.showObservePanel {
            observePanelWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        closeGeminiPanel()
        auxiliaryPanels.showObservePanel = true
        openAuxiliaryPanel(.observe)
    }

    func showGeminiPanel() {
        if auxiliaryPanels.showGeminiPanel {
            geminiPanelWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        closeObservePanel()
        auxiliaryPanels.showGeminiPanel = true
        openAuxiliaryPanel(.gemini)
    }

    func toggleGeminiPanel() {
        if auxiliaryPanels.showGeminiPanel {
            closeGeminiPanel()
        } else {
            closeObservePanel()
            auxiliaryPanels.showGeminiPanel = true
            openAuxiliaryPanel(.gemini)
        }
    }

    private func closeObservePanel() {
        auxiliaryPanels.showObservePanel = false
        guard let window = observePanelWindow else { return }
        animateAuxiliaryPanelClose(window) { [weak self] in
            self?.observePanelWindow = nil
        }
    }

    private func closeGeminiPanel() {
        auxiliaryPanels.showGeminiPanel = false
        guard let window = geminiPanelWindow else { return }
        animateAuxiliaryPanelClose(window) { [weak self] in
            self?.geminiPanelWindow = nil
        }
    }

    private func openAuxiliaryPanel(_ kind: AuxiliaryPanelKind) {
        guard let panel else { return }

        let targetWindow: NSPanel
        switch kind {
        case .observe:
            if let existing = observePanelWindow {
                targetWindow = existing
            } else {
                let window = makeAuxiliaryPanel(kind: .observe)
                observePanelWindow = window
                targetWindow = window
            }
        case .gemini:
            ensureShellSessionWorkingDirectory()
            shellSession.startIfNeeded()
            if let existing = geminiPanelWindow {
                targetWindow = existing
            } else {
                let window = makeAuxiliaryPanel(kind: .gemini)
                geminiPanelWindow = window
                targetWindow = window
            }
        }

        syncAuxiliaryPanelFrame(targetWindow, kind: kind)
        if targetWindow.parent == nil {
            panel.addChildWindow(targetWindow, ordered: .above)
        }
        let targetFrame = auxiliaryPanelFrame(kind: kind, height: targetWindow.frame.height)
        var startFrame = targetFrame
        startFrame.origin.y -= 28
        targetWindow.setFrame(startFrame, display: false)
        targetWindow.alphaValue = 0
        targetWindow.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            targetWindow.animator().alphaValue = 1
            targetWindow.animator().setFrame(targetFrame, display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func ensureShellSessionWorkingDirectory() {
        let desired = preferences.effectiveObsidianVaultRoot ?? config.repositoryRoot ?? FileManager.default.currentDirectoryPath
        guard shellSession.workingDirectory != desired else { return }
        shellSession.stop()
        if let existing = geminiPanelWindow {
            if let parent = existing.parent {
                parent.removeChildWindow(existing)
            }
            existing.close()
            geminiPanelWindow = nil
        }
        shellSession = EmbeddedShellSession(workingDirectory: desired)
    }

    private func makeAuxiliaryPanel(kind: AuxiliaryPanelKind) -> NSPanel {
        let frame = auxiliaryPanelFrame(kind: kind, height: kind == .gemini ? 300 : observePanelPreferredHeight(for: max(520, panel.frame.width - 250 - 18 * 2)))
        let window = NSPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.delegate = self
        window.minSize = NSSize(width: kind == .gemini ? 480 : 620, height: kind == .gemini ? 220 : 240)

        let rootView: AnyView
        switch kind {
        case .observe:
            rootView = AnyView(
                ObservePanelWindowView(
                    viewModel: viewModel,
                    preferences: preferences,
                    onOpenProjectMemory: { [weak self] lane in self?.openProjectMemoryWindow(initialLane: lane) },
                    onOpenUpdateLog: { [weak self] in self?.openUpdateLogWindow() },
                    onOpenQuestionProfile: { [weak self] scope in self?.openQuestionProfileWindow(scope: scope) },
                    onOpenLogs: { [weak self] in self?.openOperationLogWindow() },
                    onClose: { [weak self] in self?.closeObservePanel() }
                )
            )
        case .gemini:
            rootView = AnyView(
                GeminiShellPanelView(
                    session: shellSession,
                    workingDirectory: config.repositoryRoot ?? FileManager.default.currentDirectoryPath
                )
            )
        }

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
        window.contentView = contentView
        return window
    }

    private func auxiliaryPanelFrame(kind: AuxiliaryPanelKind, height: CGFloat) -> NSRect {
        let panelFrame = panel.frame
        let railWidth: CGFloat = 250
        let horizontalInset: CGFloat = 18
        let chromeHeight: CGFloat = 58
        let bottomInset: CGFloat = 16
        let width = max(520, panelFrame.width - railWidth - horizontalInset * 2)
        let x = panelFrame.minX + railWidth + horizontalInset
        let availableHeight = max(220, panelFrame.height - chromeHeight - bottomInset - 28)
        let desiredHeight: CGFloat = switch kind {
        case .observe:
            observePanelPreferredHeight(for: width)
        case .gemini:
            height
        }
        let heightCapRatio: CGFloat = kind == .observe ? 0.8 : 0.62
        let clampedHeight = min(desiredHeight, availableHeight * heightCapRatio)
        let y = panelFrame.minY + bottomInset
        return NSRect(x: x, y: y, width: width, height: clampedHeight)
    }

    private func syncAuxiliaryPanelFrames() {
        if let observePanelWindow {
            syncAuxiliaryPanelFrame(observePanelWindow, kind: .observe)
        }
        if let geminiPanelWindow {
            syncAuxiliaryPanelFrame(geminiPanelWindow, kind: .gemini)
        }
    }

    private func syncAuxiliaryPanelFrame(_ window: NSPanel, kind: AuxiliaryPanelKind) {
        let currentHeight = switch kind {
        case .observe:
            observePanelPreferredHeight(for: window.frame.width)
        case .gemini:
            max(window.frame.height, 220)
        }
        window.setFrame(auxiliaryPanelFrame(kind: kind, height: currentHeight), display: true)
    }

    private func observePanelPreferredHeight(for width: CGFloat) -> CGFloat {
        if width >= 1180 {
            return 248
        }
        if width >= 760 {
            return 392
        }
        return 520
    }

    private func animateAuxiliaryPanelClose(_ window: NSPanel, completion: @escaping () -> Void) {
        var endFrame = window.frame
        endFrame.origin.y -= 24
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
            window.animator().setFrame(endFrame, display: true)
        }, completionHandler: {
            window.close()
            completion()
        })
    }

    private func closeSetupWindow() {
        setupWindow?.close()
        setupWindow = nil
        setupViewModel = nil
    }

    private func presentProjectMemoryWindow(snapshot: DashboardSnapshot, initialLane: String?) {
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

    private func presentQuestionProfileWindow(title: String, profile: QuestionProfileDocument) {
        closeQuestionProfileWindow()

        let rootView = QuestionProfileDetailView(
            title: title,
            profile: profile,
            onOpenPath: { [weak self] path in self?.openPath(path) },
            onClose: { [weak self] in self?.closeQuestionProfileWindow() }
        )
        let hosting = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 360, y: 280, width: 660, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        window.delegate = self
        questionProfileWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentUpdateLogWindow(updateLog: ProjectUpdateLog) {
        closeUpdateLogWindow()

        let rootView = UpdateLogDetailView(
            updateLog: updateLog,
            onClose: { [weak self] in self?.closeUpdateLogWindow() }
        )
        let hosting = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 360, y: 280, width: 700, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = updateLog.title
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        window.delegate = self
        updateLogWindow = window
        NSApp.activate(ignoringOtherApps: true)
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
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.delegate = self
        panel.minSize = NSSize(width: 520, height: 420)
        panel.isReleasedWhenClosed = false

        let rootView = DashboardRootView(
            viewModel: viewModel,
            chatModel: chatModel,
            auxiliaryPanels: auxiliaryPanels,
            preferences: preferences,
            relayWorkingDirectory: preferences.effectiveObsidianVaultRoot ?? config.repositoryRoot ?? FileManager.default.currentDirectoryPath,
            onRefresh: { [weak self] in self?.refreshNow() },
            onOpenLogs: { [weak self] in self?.openOperationLogWindow() },
            onOpenCurrentWorkspace: { [weak self] in self?.openCurrentWorkspace() },
            onOpenPath: { [weak self] path in self?.openPath(path) },
            onOpenSettings: { [weak self] in self?.openSettingsWindow() },
            onOpenSetup: { [weak self] in self?.openSetupWindow() },
            onOpenProjectMemory: { [weak self] lane in self?.openProjectMemoryWindow(initialLane: lane) },
            onOpenQuestionProfile: { [weak self] scope in self?.openQuestionProfileWindow(scope: scope) },
            onOpenUpdateLog: { [weak self] in self?.openUpdateLogWindow() },
            onFollowLatestWorkspace: { [weak self] in self?.followLatestWorkspace() },
            onSelectWorkspace: { [weak self] path in self?.selectWorkspace(path) },
            onPreviousWorkspace: { [weak self] in self?.selectPreviousWorkspace() },
            onNextWorkspace: { [weak self] in self?.selectNextWorkspace() },
            onNormalizeVault: { [weak self] in self?.normalizeObsidianVaultLayout() },
            onProcessSources: { [weak self] in self?.processObsidianSources() },
            onBuildAllProjectWikis: { [weak self] in self?.buildAllProjectWikis() },
            onRefreshSelectedScope: { [weak self] in self?.refreshSelectedScope() },
            onExportCurrentChats: { [weak self] in self?.exportAgentChatHistoryNow(force: true) },
            onExportAllChats: { [weak self] in self?.exportAllKnownWorkspaceChatHistory() },
            onSubmitGeminiQuery: { [weak self] in self?.submitGeminiQuery() },
            onClearGeminiChat: { [weak self] in self?.chatModel.clear() },
            onToggleObservePanel: { [weak self] in self?.toggleObservePanel() },
            onToggleGeminiPanel: { [weak self] in self?.toggleGeminiPanel() }
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
        syncAuxiliaryPanelFrames()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refresh(operationID: String? = nil) {
        pendingRefresh = true
        if let operationID {
            pendingRefreshOperationID = operationID
        }
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
        let operationID = pendingRefreshOperationID
        pendingRefreshOperationID = nil

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
                    if let operationID {
                        self.viewModel.finishOperation(
                            operationID,
                            detail: "Fabric snapshot refreshed for \(snapshot.projectName)."
                        )
                    }
                    self.viewModel.apply(snapshot: snapshot)
                    self.onSnapshotUpdate(self)
                case .failure(let error):
                    if let operationID {
                        self.viewModel.failOperation(operationID, error: error)
                    } else {
                        self.viewModel.apply(error: error)
                    }
                    self.onSnapshotUpdate(self)
                }
            }
        }
    }

    private func makeSnapshotRequest(snapshotMode: String = "summary") -> SnapshotRequest {
        SnapshotRequest(
            script: config.snapshotScript,
            workspace: preferences.effectiveWorkspaceArgument,
            globalRoot: preferences.effectiveGlobalRoot,
            geminiSettings: config.geminiSettings?.isEmpty == false ? config.geminiSettings : nil,
            vaultRoot: preferences.effectiveObsidianVaultRoot,
            snapshotMode: snapshotMode
        )
    }

    private func snapshotCommandPreview(for request: SnapshotRequest) -> String {
        var arguments = ["python3", request.script]
        if let workspace = request.workspace {
            arguments += ["--workspace", workspace]
        }
        arguments += ["--global-root", request.globalRoot]
        if let geminiSettings = request.geminiSettings {
            arguments += ["--gemini-settings", geminiSettings]
        }
        if let vaultRoot = request.vaultRoot {
            arguments += ["--vault-root", vaultRoot]
        }
        arguments += ["--snapshot-mode", request.snapshotMode]
        return arguments.joined(separator: " ")
    }

    private func loadDetailedSnapshot(completion: @escaping (Result<DashboardSnapshot, Error>) -> Void) {
        let request = makeSnapshotRequest(snapshotMode: "full")
        Task.detached(priority: .userInitiated) {
            let result = Result { try Self.loadSnapshot(request: request) }
            await MainActor.run {
                completion(result)
            }
        }
    }

    func exportAgentChatHistoryNow(force: Bool) {
        guard dataAcquisitionFeaturesEnabled else {
            viewModel.apply(error: NSError(domain: "FloatingDashboard", code: 0, userInfo: [NSLocalizedDescriptionKey: "Raw acquisition is intentionally handled outside Fabric. Bring prepared inputs in through your external tooling, then return here to normalize, compile, and review the knowledge base."]))
            return
        }
        guard let snapshot = viewModel.snapshot else { return }
        guard let vaultRoot = preferences.effectiveObsidianVaultRoot else { return }
        guard let repoRoot = config.repositoryRoot else { return }
        let script = URL(fileURLWithPath: repoRoot).appendingPathComponent("tools/acquisition/export_agent_chat_history.py").path
        let workspace = snapshot.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty else { return }

        chatHistoryExportTask?.cancel()
        let command = [
            "python3",
            script,
            "--workspace",
            workspace,
            "--vault-root",
            vaultRoot,
            "--output-dir",
            preferences.effectiveObsidianChatHistoryOutputDir,
            "--runtime",
            "both",
        ]
        let operationID = viewModel.beginOperation(
            "Exporting agent chats",
            detail: "Exporting runtime conversations for the selected workspace into the external raw-source lane prepared outside Fabric.",
            commandPreview: command.joined(separator: " "),
            workspace: workspace
        )
        chatHistoryExportTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let result = try await executeExternalCommandAsync(arguments: command, timeout: exportCommandTimeout, commandDescription: "chat history export")
                if result.terminationStatus != 0 {
                    let message = result.stderrText.isEmpty ? "external chat export failed" : result.stderrText
                    await MainActor.run { [weak self] in
                        self?.viewModel.failOperation(operationID, error: NSError(domain: "FloatingDashboard", code: Int(result.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message]))
                    }
                } else {
                    await MainActor.run { [weak self] in
                        self?.viewModel.finishOperation(operationID, detail: "Agent chats exported for \(workspace).")
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.viewModel.failOperation(operationID, error: error)
                }
            }
        }
    }

    func exportAllKnownWorkspaceChatHistory() {
        guard dataAcquisitionFeaturesEnabled else {
            viewModel.apply(error: NSError(domain: "FloatingDashboard", code: 0, userInfo: [NSLocalizedDescriptionKey: "Raw acquisition is intentionally handled outside Fabric. Bring prepared inputs in through your external tooling, then return here to normalize, compile, and review the knowledge base."]))
            return
        }
        guard let snapshot = viewModel.snapshot else { return }
        guard let vaultRoot = preferences.effectiveObsidianVaultRoot else { return }
        guard let repoRoot = config.repositoryRoot else { return }
        let script = URL(fileURLWithPath: repoRoot).appendingPathComponent("tools/acquisition/export_agent_chat_history.py").path

        var workspacePaths = snapshot.availableWorkspaces.map(\.path)
        let currentWorkspace = snapshot.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentWorkspace.isEmpty, !workspacePaths.contains(currentWorkspace) {
            workspacePaths.insert(currentWorkspace, at: 0)
        }
        workspacePaths = Array(NSOrderedSet(array: workspacePaths)) as? [String] ?? workspacePaths
        workspacePaths = workspacePaths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !workspacePaths.isEmpty else { return }
        let workspaceCount = workspacePaths.count

        chatHistoryExportTask?.cancel()
        let workspaceSummary = workspacePaths.prefix(3).joined(separator: ", ")
        let commandPreview = [
            "python3",
            script,
            "--workspace <each-known-workspace>",
            "--vault-root",
            vaultRoot,
            "--output-dir",
            preferences.effectiveObsidianChatHistoryOutputDir,
            "--runtime",
            "both",
        ].joined(separator: " ")
        let operationID = viewModel.beginOperation(
            "Exporting all workspace chats",
            detail: "Batch-exporting conversation history for \(workspacePaths.count) workspace(s).",
            commandPreview: commandPreview,
            workspace: workspaceSummary
        )
        chatHistoryExportTask = Task.detached(priority: .utility) { [weak self] in
            for workspace in workspacePaths {
                guard !Task.isCancelled else { return }
                let command = [
                    "python3",
                    script,
                    "--workspace",
                    workspace,
                    "--vault-root",
                    vaultRoot,
                    "--output-dir",
                    self?.preferences.effectiveObsidianChatHistoryOutputDir ?? "Agent Chat History",
                    "--runtime",
                    "both",
                ]
                do {
                    let result = try await executeExternalCommandAsync(arguments: command, timeout: exportCommandTimeout, commandDescription: "chat history export")
                    if result.terminationStatus != 0 {
                        let message = result.stderrText.isEmpty ? "external chat export failed" : result.stderrText
                        await MainActor.run { [weak self] in
                            self?.viewModel.failOperation(operationID, error: NSError(domain: "FloatingDashboard", code: Int(result.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(workspace): \(message)"]))
                        }
                        return
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.viewModel.failOperation(operationID, error: error)
                    }
                    return
                }
            }
            await MainActor.run { [weak self] in
                self?.viewModel.finishOperation(operationID, detail: "Agent chats exported for \(workspaceCount) workspace(s).")
            }
        }
    }

    func normalizeObsidianVaultLayout() {
        runObsidianWikiTask(mode: "normalize")
    }

    func processObsidianSources() {
        openSourcePromptWindow()
    }

    func buildAllProjectWikis() {
        openBuildAllPromptWindow()
    }

    private func openSourcePromptWindow() {
        guard let document = buildSourcePromptDocument() else { return }
        viewModel.recordOperation(
            title: "Prepared Process Sources prompt",
            detail: "Generated a Gemini CLI prompt for source normalization and semantic-cache extraction.",
            status: .completed,
            workspace: document.workingDirectory,
            category: "Prompt"
        )
        if let existing = sourcePromptWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 260, y: 260, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Process Sources Prompt"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let rootView = SourcePromptDetailView(
            document: document,
            onClose: { [weak self] in
                self?.sourcePromptWindow?.close()
                self?.sourcePromptWindow = nil
            }
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let contentView = NSView()
        contentView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: contentView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        window.contentView = contentView
        sourcePromptWindow = window
        centerWindowOnMainPanel(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openBuildAllPromptWindow() {
        guard let document = buildBuildAllPromptDocument() else { return }
        viewModel.recordOperation(
            title: "Prepared Build All prompt",
            detail: "Generated a Gemini CLI prompt for wiki compilation, graph synthesis, and query-index rebuild.",
            status: .completed,
            workspace: document.workingDirectory,
            category: "Prompt"
        )
        if let existing = buildAllPromptWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 300, y: 300, width: 780, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Build All Prompt"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let rootView = SourcePromptDetailView(
            document: document,
            onClose: { [weak self] in
                self?.buildAllPromptWindow?.close()
                self?.buildAllPromptWindow = nil
            }
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let contentView = NSView()
        contentView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: contentView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        window.contentView = contentView
        buildAllPromptWindow = window
        centerWindowOnMainPanel(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func centerWindowOnMainPanel(_ window: NSWindow) {
        guard let panel else {
            window.center()
            return
        }
        let parentFrame = panel.frame
        let childSize = window.frame.size
        let centeredOrigin = NSPoint(
            x: parentFrame.midX - childSize.width / 2,
            y: parentFrame.midY - childSize.height / 2
        )
        window.setFrameOrigin(centeredOrigin)
    }

    private func buildSourcePromptDocument() -> SourcePromptDocument? {
        let vaultRoot = preferences.effectiveObsidianVaultRoot ?? config.repositoryRoot ?? FileManager.default.currentDirectoryPath
        let snapshot = viewModel.snapshot
        let projectName = currentKnowledgeProjectName(for: snapshot)
        let candidates = topLevelImportCandidates(vaultRoot: vaultRoot)
        let candidatesSection = candidates.isEmpty
            ? "- No non-skeleton top-level roots were detected automatically. Inspect the vault manually for stray knowledge folders."
            : candidates.map { "- \($0)" }.joined(separator: "\n")

        let prompt = """
        You are operating inside the Obsidian vault root:
        `\(vaultRoot)`

        Goal:
        Run one conservative source-standardization pass only.
        This step is strictly for source ingestion and normalization; it is not a wiki compilation run.

        Architecture rules:
        - Treat `00 Raw Sources`, `10 Wiki`, `20 Queries and Reports`, and `90 System` as the managed skeleton.
        - Do not recursively re-ingest generated wiki or system pages as raw sources.
        - Treat `.agents` and `.obsidian` as internal metadata, not knowledge imports.
        - Keep raw imports immutable wherever possible: prefer copying or carefully reorganizing into canonical raw-source lanes instead of destructive rewrites.
        - Shared Fabric remains external canonical system state; do not move it into the vault.

        Current focus project:
        `\(projectName)`

        Top-level non-skeleton candidates detected in the vault:
        \(candidatesSection)

        Your task:
        1. Inventory every top-level knowledge root that is not part of the managed skeleton.
        2. Classify each root into one of these source families:
           - Agent Chats
           - Gemini
           - ChatGPT
           - NotebookLM
           - Notion
           - Shared Fabric Snapshots
           - Other External Imports
        3. Normalize those materials into canonical raw-source lanes under:
           - `00 Raw Sources/Agent Chats`
           - `00 Raw Sources/External Imports/<Family>`
           - `00 Raw Sources/Shared Fabric Snapshots`
        4. Do not treat `10 Wiki` or `90 System` as inputs to be re-normalized.
        5. If a root is ambiguous, leave it in place and record it explicitly instead of guessing.
        6. Refresh or regenerate only source-side managed outputs if your standardization pass changes source structure:
           - `90 System/normalized-sources-manifest.json`
           - `90 System/source-processing-report.md`
        7. Extract source semantics for downstream graph building and cache them under:
           - `90 System/semantic-cache/source-keywords.json`
           - `90 System/semantic-cache/source-entities.json`
           - `90 System/semantic-cache/source-relationships.json`
           - `90 System/semantic-cache/README.md` (fields + schema notes)
        8. Do not rebuild wiki project pages, graph, or knowledge-base manifest in this step.
        9. Summarize whether a follow-up `Build All` run is recommended to compile sources into wiki outputs.

        Required output format:
        - Inventory
        - Proposed family mapping
        - Exact filesystem actions taken
        - Ambiguous roots left untouched
        - Recommended next step

        Safety constraints:
        - Do not delete user data unless there is an obvious duplicate that is already safely represented in canonical raw sources.
        - Prefer conservative reorganization over aggressive cleanup.
        - If you need to choose between preserving provenance and making the folder tree prettier, preserve provenance.
        """

        return SourcePromptDocument(
            title: "Process Sources Prompt",
            workingDirectory: vaultRoot,
            prompt: prompt
        )
    }

    private func buildBuildAllPromptDocument() -> SourcePromptDocument? {
        let vaultRoot = preferences.effectiveObsidianVaultRoot ?? config.repositoryRoot ?? FileManager.default.currentDirectoryPath
        let snapshot = viewModel.snapshot
        let projectName = currentKnowledgeProjectName(for: snapshot)
        let scopeLabel = preferences.scopeMode.title
        let scopeValue = preferences.scopeMode.rawValue

        let prompt = """
        You are operating inside the Obsidian vault root:
        `\(vaultRoot)`

        Goal:
        Run one Build All compilation pass that converts normalized source manifests into maintained wiki and system outputs.
        This step is strictly source -> wiki/system compilation and must not re-organize raw sources.

        Scope:
        - Current focus project: `\(projectName)`
        - Requested scope mode: `\(scopeLabel)` (`\(scopeValue)`)

        Input contracts (read first):
        - `90 System/normalized-sources-manifest.json`
        - `90 System/source-processing-report.md`
        - `90 System/project-source-index.json`
        - `90 System/global-knowledge-pool.json`
        - existing Shared Fabric project memory and registry snapshots

        Your task:
        1. Validate source prerequisites:
           - Confirm `normalized-sources-manifest.json` exists and is parseable.
           - If missing, stop and report that `Process Sources` must run first.
        2. Perform compilation inside a temporary staging workspace first.
           - Use a temp directory under the vault such as `.tmp/build-all/<timestamp>/`.
           - Build draft wiki/system outputs there before copying validated results back.
           - Keep raw sources immutable during compilation.
        3. Compile source-library wiki pages:
           - `10 Wiki/Sources/Overview.md`
           - source-family pages under `10 Wiki/Sources/`
        4. Compile project wiki pages from Shared Fabric state:
           - `10 Wiki/Projects/<project>/Overview.md`
           - `Current Status.md`
           - `Architecture.md`
           - `Decisions.md`
           - `Open Questions.md`
           - `Sources.md`
           - Respect scope explicitly:
             - If scope is vault-wide, rebuild every discovered project.
             - If scope is project/workspace-specific, rebuild the selected project and preserve other project folders unless you are explicitly refreshing them too.
           - Do not silently downgrade `allVault` to `workspace` or `project`.
           - If requested scope mode is `allVault`, the output manifest must declare `compilation_scope` as `all-vault`.
           - Project identity must align to canonical sidebar/workspace projects, not source-family buckets such as `NotebookLM: <folder>` or `Agent Chats: <folder>`.
           - Read `project-source-index.json` and merge raw sources into those canonical projects before compiling wiki pages.
           - Every compiled project entry in `knowledge-base-manifest.json` must include project name, slug, workspace, page_count, page paths, lifecycle/focus summary, and last_updated.
        5. Compile concept-aware deep-wiki pages from semantic cache:
           - `10 Wiki/Concepts/<concept>.md`
           - `10 Wiki/Entities/<entity>.md`
           - `10 Wiki/Global/Overview.md`
           - optional global cluster pages such as `10 Wiki/Global/NotebookLM.md`, `Agent Chats.md`, `Shared Fabric.md` when evidence volume justifies them.
           - topic or relationship indexes when multiple projects share the same concept.
           - Every concept/entity page should be human-readable, include provenance, and link back to related projects, sources, and evidence.
           - When building project-specific concepts/entities/keywords, read both:
             - full text of the mapped project sources from `00 Raw Sources`
             - existing project wiki pages under `10 Wiki/Projects/<project>/`
           - Do not derive project semantics only from folder names, source titles, or index page headings.
           - Read `global-knowledge-pool.json` and preserve a first-class global semantic layer for large unmapped corpora.
           - Global pages should explain important cross-project or unmapped knowledge that still matters at the vault level.
        6. Rebuild system outputs:
           - `90 System/knowledge-base-manifest.json`
           - `90 System/graph.json`
           - `90 System/index.md`
           - `90 System/log.md`
           - `90 System/migration-report.md`
           - `90 System/wiki-query-index.json`
           - `knowledge-base-manifest.json` must be a JSON object with:
             - `generated_at`
             - `version`
             - `compilation_scope`
             - `project_count`
             - `projects`
           - Each `projects` entry must include:
             - `project_name`
             - `slug`
             - `workspace`
             - `page_count`
             - `page_paths`
             - `lifecycle_summary`
             - `last_updated`
        7. Build semantic graph layers from cached source semantics:
           - Read `90 System/semantic-cache/source-keywords.json`, `source-entities.json`, `source-relationships.json`, and `source-concepts.json`.
           - Read `90 System/global-knowledge-pool.json` for all-vault concepts/entities/keywords that do not belong cleanly to one project.
           - Emit `90 System/semantic_metadata.json` with normalized keyword/entity/concept indices and cross-project references.
           - Augment `90 System/graph.json` with semantic nodes/edges (concepts, entities, relationships, references), not only folder/page structure.
           - Every concept and entity node written into `graph.json` must have at least one incident edge.
           - Relationship objects must become explicit graph edges or relationship nodes with provenance links.
           - Do not flood the graph with stopwords or low-information keyword nodes such as `and`, `the`, `for`, `next`, `then`, `with`, `that`, `this`, `still`, or `than`.
           - `graph.json` must be app-readable and use this exact structure:
             - top-level keys: `nodes`, `edges`
             - each node object must include:
               - `id`
               - `label`
               - `kind`
               - `path`
               - `scope`
               - `workspace`
               - `status`
             - each edge object must include:
               - `source`
               - `target`
               - `kind`
           - Do not substitute `type` for `kind`.
           - Do not substitute `relation` for `kind`.
           - `scope` should identify the project slug or `all-vault` umbrella for shared nodes.
           - `workspace` should point to the owning workspace path when applicable.
           - `path` should point to the backing page/source/evidence file when available, otherwise use an empty string rather than inventing a fake filesystem path.
           - Project nodes must represent canonical projects/workspaces, not source-family folder names.
           - Project-specific concept/entity nodes must use the owning project slug in `scope`; reserve `all-vault` for truly shared cross-project nodes only.
           - Include some keyword nodes when they are high-support and materially help navigation; they do not all need to be rendered, but the graph should not collapse keyword coverage to near-zero if the corpus is rich.
           - Global NotebookLM / Agent Chats / Shared Fabric knowledge may appear as shared concept/entity/keyword clusters connected to `all-vault` or `unmapped` hubs.
           - In `allVault` mode, do not emit every raw source file as a graph node by default. Preserve detailed provenance in wiki pages and query indices, but keep graph navigation semantic-first.
           - Source nodes should be representative provenance anchors only: prefer high-support evidence, canonical source family summaries, or cluster representatives instead of one node per imported file.
           - If a large unmapped corpus exists, connect it through global cluster or hub nodes rather than flooding the graph with hundreds of file-name leaves.
           - If raw source evidence would dominate the graph, prefer aggregation. As a rule of thumb, in `allVault` mode raw source nodes should remain a minority of rendered navigation nodes unless you explicitly justify otherwise in the report.
        8. Build query-ready wiki retrieval metadata:
           - `90 System/wiki-query-index.json` should map projects, pages, concepts, entities, and evidence snippets for downstream question-answering.
           - Favor human-readable summaries plus explicit provenance over opaque embeddings-only outputs.
           - `wiki-query-index.json` must be a JSON object with:
             - `generated_at`
             - `scope`
             - `projects` as an array of project objects `{ name, slug, workspace, pages, related_concepts, related_entities }`
             - `pages` as an array of page objects `{ title, path, project, summary, concepts, entities, evidence_snippets }`
             - `concepts` as an array of concept objects `{ name, summary, projects, entities, related_concepts, provenance }`
             - `entities` as an array of entity objects `{ name, type, projects, concepts, provenance }`
             - `snippets` as an array of evidence objects `{ id, source_path, project, page, text, concepts, entities }`
           - Do not replace these arrays with a single summary counter map.
        9. Keep raw source files immutable in this step:
           - Do not move, rename, or reclassify directories under `00 Raw Sources`.
        10. Report exact outputs written and any compile blockers.
        11. Run a compilation self-check before finishing:
           - `knowledge-base-manifest.json` project count must match the actual rebuild scope you chose and your report must state that count.
           - If scope was vault-wide and only one project made it into the manifest, report failure instead of success.
           - If requested scope mode is `allVault` and `compilation_scope` is anything other than `all-vault`, report failure instead of success.
           - `graph.json` must include semantic nodes and edges from concepts/entities/relationships, not only page/source nodes.
           - `graph.json` must validate against the exact dashboard node/edge fields above.
           - `wiki-query-index.json` must include page-level and snippet-level retrieval entries, not only top-level labels.
           - Concept/entity wiki pages must contain evidence/provenance sections, not only a title and one-line description.
           - In `allVault` mode, the manifest project count must be greater than 1 unless the vault truly contains only one project, and your report must justify that claim explicitly.
           - If project labels in the manifest/graph are source-family buckets instead of canonical projects, report failure.
           - If a large corpus like NotebookLM or Agent Chats produces only trivial keyword coverage, report failure or partial completion.
           - If the global unmapped layer is large but absent from graph/wiki/query outputs, report failure or partial completion.
           - If the all-vault graph is still dominated by file-level `source` nodes instead of semantic hubs, clusters, projects, concepts, entities, and high-support keywords, report failure or partial completion.

        Required output format:
        - Prerequisite check
        - Compilation scope
        - Files written
        - Files skipped or unchanged
        - Project count written to manifest
        - Global layer files and nodes written
        - Graph schema validation result
        - Validation checks passed or failed
        - Recommended next step

        Failure conditions:
        - If any required output file is missing or obviously underspecified relative to the contract above, report failure.
        - If semantic graph nodes were generated without meaningful edges, report failure.
        - If you had to fall back to a project-singleton build because the inputs were too weak for a deeper wiki, say that explicitly.
        - If `graph.json` uses a different schema than the exact node/edge contract above, report failure.
        - If requested scope mode is `allVault` but the result only covers a single project without explicit justification, report failure.

        Safety constraints:
        - Do not delete user-authored content.
        - Preserve existing provenance links.
        - If ambiguous, prefer no-op plus explicit note over speculative rewrite.
        """

        return SourcePromptDocument(
            title: "Build All Prompt",
            workingDirectory: vaultRoot,
            prompt: prompt
        )
    }

    private func currentKnowledgeProjectName(for snapshot: DashboardSnapshot?) -> String {
        guard let snapshot else { return "Obsidian Knowledge Base" }
        if preferences.scopeMode == .allVault {
            return "Obsidian Knowledge Base"
        }
        return snapshot.knowledgeProjects.first(where: { $0.workspace == snapshot.workspace })?.name ?? snapshot.projectName
    }

    private func topLevelImportCandidates(vaultRoot: String) -> [String] {
        let root = URL(fileURLWithPath: vaultRoot)
        let excluded = Set([".agents", ".obsidian", "00 Raw Sources", "10 Wiki", "20 Queries and Reports", "90 System"])
        guard let contents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return contents
            .filter { !excluded.contains($0.lastPathComponent) }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                return values?.isDirectory == true ? url.lastPathComponent : nil
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func refreshSelectedScope() {
        switch preferences.scopeMode {
        case .allVault, .project:
            runObsidianWikiTask(mode: "build-all", includeWorkspace: false)
        case .workspace:
            runObsidianWikiTask(mode: "build-workspace", includeWorkspace: true)
        }
    }

    private func runObsidianWikiTask(mode: String, includeWorkspace: Bool = true) {
        guard let vaultRoot = preferences.effectiveObsidianVaultRoot else { return }
        guard let repoRoot = config.repositoryRoot else { return }
        let workspace = viewModel.snapshot?.workspace.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if includeWorkspace && workspace.isEmpty {
            return
        }

        let script = URL(fileURLWithPath: repoRoot).appendingPathComponent("tools/compact_dashboard/export_obsidian_wiki.py").path
        obsidianWikiTask?.cancel()
        let operationLabel: String = switch mode {
        case "normalize":
            "Normalizing vault"
        case "build-all":
            "Building project wikis"
        default:
            "Refreshing selected scope"
        }
        var arguments = [
            "python3",
            script,
            "--global-root",
            preferences.effectiveGlobalRoot,
            "--vault-root",
            vaultRoot,
            "--raw-chat-dir",
            preferences.effectiveObsidianChatHistoryOutputDir,
            "--mode",
            mode,
        ]
        if includeWorkspace {
            arguments.insert(contentsOf: ["--workspace", workspace], at: 2)
        }
        let operationID = viewModel.beginOperation(
            operationLabel,
            detail: includeWorkspace ? "Compiling knowledge artifacts for the selected workspace scope." : "Compiling knowledge artifacts for the current vault-wide selection.",
            commandPreview: arguments.joined(separator: " "),
            workspace: includeWorkspace ? workspace : (preferences.effectiveWorkspaceArgument ?? "")
        )
        obsidianWikiTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let result = try await executeExternalCommandAsync(arguments: arguments, timeout: obsidianTaskTimeout, commandDescription: "obsidian wiki task")
                if result.terminationStatus != 0 {
                    let message = result.stderrText.isEmpty ? "obsidian wiki task failed" : result.stderrText
                    await MainActor.run { [weak self] in
                        self?.viewModel.failOperation(operationID, error: NSError(domain: "FloatingDashboard", code: Int(result.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message]))
                    }
                    return
                }
                await MainActor.run { [weak self] in
                    self?.viewModel.finishOperation(operationID, detail: "Knowledge artifacts rebuilt with mode `\(mode)`.")
                    self?.refresh()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.viewModel.failOperation(operationID, error: error)
                }
            }
        }
    }

    func submitGeminiQuery() {
        let prompt = chatModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard let snapshot = viewModel.snapshot else { return }

        geminiTask?.cancel()
        let scope = preferences.geminiChatScopeMode
        chatModel.begin(scope: scope)
        let operationID = viewModel.beginOperation(
            "Running Gemini relay",
            detail: "Sending the current knowledge-scoped prompt to Gemini CLI and waiting for a grounded response.",
            commandPreview: "gemini --output-format text -p <context>",
            workspace: snapshot.workspace
        )
        let userPrompt = prompt
        geminiTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let contextPrompt = self.buildGeminiPrompt(snapshot: snapshot, scope: scope, question: userPrompt)
            do {
                let currentDirectoryURL = self.config.repositoryRoot.flatMap { root in
                    root.isEmpty ? nil : URL(fileURLWithPath: root)
                }
                let result = try await executeExternalCommandAsync(
                    arguments: ["gemini", "--output-format", "text", "-p", contextPrompt],
                    currentDirectoryURL: currentDirectoryURL,
                    timeout: geminiCommandTimeout,
                    commandDescription: "Gemini CLI relay"
                )
                if result.terminationStatus != 0 {
                    let message = result.stderrText.isEmpty ? "Gemini CLI entrypoint failed." : result.stderrText
                    await MainActor.run {
                        self.viewModel.finishOperation(operationID, outcome: .failed, detail: message)
                        self.chatModel.fail(message)
                    }
                    return
                }
                let text = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    self.viewModel.finishOperation(operationID, detail: "Gemini relay completed for the current \(scope.title.lowercased()) scope.")
                    let command = "$ gemini --output-format text -p <context>"
                    let response = text.isEmpty ? "Gemini returned no visible output." : text
                    self.chatModel.finish(response: "\(command)\n\n\(response)")
                }
            } catch {
                await MainActor.run {
                    self.viewModel.failOperation(operationID, error: error)
                    self.chatModel.fail("Gemini CLI entrypoint is unavailable: \(error.localizedDescription)")
                }
            }
        }
    }

    private func buildGeminiPrompt(snapshot: DashboardSnapshot, scope: KnowledgeScopeMode, question: String) -> String {
        let scopeSummary: String = switch scope {
        case .allVault:
            "All Vault"
        case .project:
            snapshot.selectedScope.projectName.isEmpty ? snapshot.projectName : snapshot.selectedScope.projectName
        case .workspace:
            snapshot.workspace
        }

        var lines = [
            "You are answering a question about an Obsidian knowledge base maintained by Fabric.",
            "Prefer concise, direct answers grounded in the provided scope context.",
            "Current scope: \(scopeSummary)",
            "Vault summary: \(snapshot.knowledgeBaseOverview.summary)",
            "Current workspace: \(snapshot.workspace)",
            "Current project: \(snapshot.projectName)",
            "Current runtime: \(snapshot.runtime)",
        ]

        switch preferences.surfaceMode {
        case .graph, .wiki:
            lines.append("Retrieval priority: prefer Obsidian knowledge pages, wiki links, and explicit note content first. Use broader online knowledge second. Only fall back to the source project workspace if the answer cannot be resolved from the knowledge base.")
        case .sources:
            lines.append("Retrieval priority: explain from source provenance. Prefer the source repository and source-oriented notes, while still using Obsidian context when it clarifies structure.")
        default:
            lines.append("Use the currently selected scope efficiently and prefer the lowest-cost source that can answer the question accurately.")
        }

        if scope == .allVault {
            lines.append("In all-vault mode, do not treat individual project repositories as the primary source of truth unless explicitly required.")
        }

        if scope != .allVault {
            lines.append("Current focus: \(snapshot.lastHandoff)")
            lines.append("Update log summary: \(snapshot.projectUpdateLog.summary)")
            if preferences.showQuestionProfile {
                lines.append("Question profile: \(snapshot.userQuestionProfile.workspaceProfile.summary)")
            }
        }

        if scope == .allVault {
            let rollups = snapshot.observeRollups.prefix(5).map { "- \($0.projectName): \($0.latestFocus)" }
            if !rollups.isEmpty {
                lines.append("Project rollups:")
                lines.append(contentsOf: rollups)
            }
        } else if let project = snapshot.knowledgeProjects.first(where: { $0.workspace == snapshot.workspace || $0.name == snapshot.selectedScope.projectName }) {
            lines.append("Wiki project summary: \(project.name) · pages=\(project.pageCount) · focus=\(project.focus)")
        }

        let memoryPreview = snapshot.projectMemoryRecords.prefix(6).map { "- [\($0.lane)] \($0.summary)" }
        if !memoryPreview.isEmpty {
            lines.append("Relevant project memory:")
            lines.append(contentsOf: memoryPreview)
        }

        let wikiEvidence = retrievedWikiContextBlocksForPrompt(snapshot: snapshot, scope: scope, question: question)
        if !wikiEvidence.isEmpty {
            lines.append("Retrieved wiki evidence:")
            lines.append(contentsOf: wikiEvidence)
            lines.append("Answer from this retrieved wiki evidence first. If it is insufficient, say what is missing instead of inventing unsupported claims.")
        }

        let graphEvidence = retrievedGraphContextBlocksForPrompt(snapshot: snapshot, scope: scope, question: question)
        if !graphEvidence.isEmpty {
            lines.append("Retrieved graph-neighborhood context:")
            lines.append(contentsOf: graphEvidence)
            lines.append("Use graph-neighborhood context to surface related projects, concepts, entities, or evidence even when the wording is not an exact lexical match.")
        }

        lines.append("User question: \(question)")
        return lines.joined(separator: "\n")
    }

    private func retrievedWikiContextBlocksForPrompt(snapshot: DashboardSnapshot, scope: KnowledgeScopeMode, question: String) -> [String] {
        let documents = chatKnowledgeDocumentsForPrompt(snapshot, scope: scope)
        let tokens = retrievalTokensForPrompt(question)
        let scored: [(document: KnowledgeDocument, snippet: String, score: Int)] = documents.compactMap { document in
            let content = document.inlineContent.isEmpty ? loadTextFileForPrompt(document.path) : document.inlineContent
            guard !content.isEmpty else { return nil }

            let haystack = "\(document.title)\n\(document.displayPath)\n\(content.prefix(6000))".lowercased()
            var score = 0
            for token in tokens {
                if document.title.lowercased().contains(token) {
                    score += 4
                }
                if haystack.contains(token) {
                    score += 1
                }
            }
            if score == 0 {
                return nil
            }
            let snippet = relevantSnippetForPrompt(content: content, question: question, tokens: tokens)
            return (document, snippet, score)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.document.title.localizedCaseInsensitiveCompare(rhs.document.title) == .orderedAscending
            }
            .prefix(scope == .allVault ? 6 : 4)
            .map { item in
                let pathLabel = item.document.displayPath.isEmpty ? item.document.path : item.document.displayPath
                return "- \(item.document.title) [`\(pathLabel)`]\n  \(item.snippet)"
            }
    }

    private func chatKnowledgeDocumentsForPrompt(_ snapshot: DashboardSnapshot, scope: KnowledgeScopeMode) -> [KnowledgeDocument] {
        switch scope {
        case .allVault:
            return allVaultKnowledgeDocumentsForPrompt(snapshot)
        case .project, .workspace:
            var documents = projectKnowledgeDocumentsForPrompt(snapshot)
            let sourceDocs = sourceKnowledgeDocumentsForPrompt(snapshot)
            let existingPaths = Set(documents.map(\.path))
            for document in sourceDocs where !existingPaths.contains(document.path) {
                documents.append(document)
            }
            return documents
        }
    }

    private func allVaultKnowledgeDocumentsForPrompt(_ snapshot: DashboardSnapshot) -> [KnowledgeDocument] {
        guard let vaultRoot = preferences.effectiveObsidianVaultRoot else {
            return projectKnowledgeDocumentsForPrompt(snapshot)
        }
        let fileManager = FileManager.default
        let vaultURL = URL(fileURLWithPath: vaultRoot)
        let candidateRoots = [
            vaultURL.appendingPathComponent("90 System"),
            vaultURL.appendingPathComponent("10 Wiki/Sources"),
            vaultURL.appendingPathComponent("10 Wiki/Projects"),
        ]
        var documents: [KnowledgeDocument] = []
        var seen: Set<String> = []

        for root in candidateRoots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension.lowercased() == "md" else { continue }
                let path = fileURL.path
                if seen.contains(path) { continue }
                seen.insert(path)
                documents.append(
                    KnowledgeDocument(
                        title: fileURL.deletingPathExtension().lastPathComponent,
                        path: path
                    )
                )
            }
        }

        return documents.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func projectKnowledgeDocumentsForPrompt(_ snapshot: DashboardSnapshot) -> [KnowledgeDocument] {
        guard let project = selectedKnowledgeProjectForPrompt(snapshot) else { return [] }
        let projectRoot = URL(fileURLWithPath: project.wikiRoot)
        var documents = [
            KnowledgeDocument(title: "Overview", path: projectRoot.appendingPathComponent("Overview.md").path),
            KnowledgeDocument(title: "Current Status", path: projectRoot.appendingPathComponent("Current Status.md").path),
            KnowledgeDocument(title: "Architecture", path: projectRoot.appendingPathComponent("Architecture.md").path),
            KnowledgeDocument(title: "Decisions", path: projectRoot.appendingPathComponent("Decisions.md").path),
            KnowledgeDocument(title: "Open Questions", path: projectRoot.appendingPathComponent("Open Questions.md").path),
            KnowledgeDocument(title: "Sources", path: projectRoot.appendingPathComponent("Sources.md").path),
        ]
        if snapshot.projectUpdateLog.isAvailable {
            documents.insert(
                KnowledgeDocument(
                    title: "Update Log",
                    path: "virtual://\(snapshot.projectName)-update-log",
                    displayPath: "Generated from Project Memory",
                    inlineContent: snapshot.projectUpdateLog.content
                ),
                at: 1
            )
        }
        return documents
    }

    private func sourceKnowledgeDocumentsForPrompt(_ snapshot: DashboardSnapshot) -> [KnowledgeDocument] {
        var documents = projectKnowledgeDocumentsForPrompt(snapshot).filter {
            $0.title == "Sources" || $0.title == "Current Status" || $0.title == "Architecture" || $0.title == "Update Log"
        }
        if let vaultRoot = preferences.effectiveObsidianVaultRoot {
            let sourceOverview = URL(fileURLWithPath: vaultRoot).appendingPathComponent("10 Wiki/Sources/Overview.md").path
            let familyRoot = URL(fileURLWithPath: vaultRoot).appendingPathComponent("10 Wiki/Sources").path
            documents.append(KnowledgeDocument(title: "Sources Overview", path: sourceOverview))
            documents.append(KnowledgeDocument(title: "Source Library", path: familyRoot, displayPath: familyRoot))
        }
        return documents
    }

    private func selectedKnowledgeProjectForPrompt(_ snapshot: DashboardSnapshot) -> KnowledgeProjectSummary? {
        switch preferences.geminiChatScopeMode {
        case .allVault:
            return snapshot.knowledgeProjects.first
        case .project:
            if let match = snapshot.knowledgeProjects.first(where: { $0.workspace == snapshot.workspace || $0.name == snapshot.selectedScope.projectName }) {
                return match
            }
            return snapshot.knowledgeProjects.first
        case .workspace:
            return snapshot.knowledgeProjects.first(where: { $0.workspace == snapshot.workspace }) ?? snapshot.knowledgeProjects.first
        }
    }

    private func retrievalTokensForPrompt(_ text: String) -> [String] {
        let stopwords: Set<String> = [
            "about", "after", "also", "build", "current", "from", "have", "into", "just", "more", "only",
            "page", "project", "should", "source", "status", "that", "their", "there", "these", "this",
            "through", "what", "when", "where", "which", "wiki", "with", "would", "可以", "怎么", "什么",
            "我们", "这个", "那个", "需要", "以及", "现在", "是否", "进行", "构建"
        ]
        let scalars = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        let normalized = String(scalars)
        var seen: Set<String> = []
        var tokens: [String] = []
        for token in normalized.split(separator: " ").map(String.init) {
            guard token.count >= 2, !stopwords.contains(token), !seen.contains(token) else { continue }
            seen.insert(token)
            tokens.append(token)
        }
        return tokens
    }

    private func relevantSnippetForPrompt(content: String, question: String, tokens: [String], limit: Int = 520) -> String {
        let paragraphs = content
            .components(separatedBy: "\n\n")
            .map { block in block.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if paragraphs.isEmpty {
            return String(content.prefix(limit))
        }

        let fallbackToken = question.lowercased()
        let ranked = paragraphs.map { paragraph -> (String, Int) in
            let haystack = paragraph.lowercased()
            var score = 0
            for token in tokens where haystack.contains(token) {
                score += 2
            }
            if !fallbackToken.isEmpty, haystack.contains(fallbackToken) {
                score += 3
            }
            return (paragraph, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.count < rhs.0.count
        }

        let best = ranked.first?.0 ?? paragraphs[0]
        return best.count > limit ? String(best.prefix(limit)) + "..." : best
    }

    private func retrievedGraphContextBlocksForPrompt(snapshot: DashboardSnapshot, scope: KnowledgeScopeMode, question: String) -> [String] {
        let scopedNodes = graphNodesForPrompt(snapshot: snapshot, scope: scope)
        guard !scopedNodes.isEmpty else { return [] }

        let tokens = retrievalTokensForPrompt(question)
        if tokens.isEmpty { return [] }

        let scopedIDs = Set(scopedNodes.map(\.id))
        let adjacency = graphAdjacencyMapForPrompt(edges: snapshot.knowledgeGraphEdges, allowedNodeIDs: scopedIDs)
        let degreeCounts = graphDegreeCountsForPrompt(edges: snapshot.knowledgeGraphEdges, allowedNodeIDs: scopedIDs)
        let nodeByID = Dictionary(uniqueKeysWithValues: scopedNodes.map { ($0.id, $0) })

        let scoredSeeds = scopedNodes.compactMap { node -> (KnowledgeGraphNode, Int)? in
            let haystack = "\(node.label) \(node.kind) \(node.path)".lowercased()
            var score = 0
            for token in tokens {
                if node.label.lowercased().contains(token) {
                    score += 5
                } else if haystack.contains(token) {
                    score += 2
                }
            }
            score += min(3, degreeCounts[node.id] ?? 0)
            return score > 0 ? (node, score) : nil
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.label.localizedCaseInsensitiveCompare(rhs.0.label) == .orderedAscending
        }

        guard !scoredSeeds.isEmpty else { return [] }

        var gathered: [KnowledgeGraphNode] = []
        var seen: Set<String> = []
        for (seed, _) in scoredSeeds.prefix(4) {
            if seen.insert(seed.id).inserted {
                gathered.append(seed)
            }
            for neighborID in (adjacency[seed.id] ?? []).prefix(4) {
                guard let neighbor = nodeByID[neighborID], seen.insert(neighborID).inserted else { continue }
                gathered.append(neighbor)
            }
        }

        return gathered.prefix(8).map { node in
            let neighborLabels = (adjacency[node.id] ?? [])
                .compactMap { nodeByID[$0]?.label }
                .prefix(4)
                .joined(separator: ", ")
            if node.path.lowercased().hasSuffix(".md") || FileManager.default.fileExists(atPath: node.path) {
                let text = loadTextFileForPrompt(node.path)
                if !text.isEmpty {
                    let snippet = relevantSnippetForPrompt(content: text, question: question, tokens: tokens, limit: 340)
                    let pathLabel = node.path.isEmpty ? node.kind : node.path
                    let neighborLine = neighborLabels.isEmpty ? "" : "\n  Related: \(neighborLabels)"
                    return "- \(node.label) [\(node.kind)] [`\(pathLabel)`]\n  \(snippet)\(neighborLine)"
                }
            }
            let relationSummary = neighborLabels.isEmpty ? "No immediate related labels captured." : "Related: \(neighborLabels)"
            return "- \(node.label) [\(node.kind)]\n  \(relationSummary)"
        }
    }

    private func graphNodesForPrompt(snapshot: DashboardSnapshot, scope: KnowledgeScopeMode) -> [KnowledgeGraphNode] {
        switch scope {
        case .allVault:
            return snapshot.knowledgeGraphNodes
        case .project:
            let selectedProject = selectedKnowledgeProjectForPrompt(snapshot)
            let selectedSlug = selectedProject?.slug ?? ""
            return snapshot.knowledgeGraphNodes.filter { node in
                (!selectedSlug.isEmpty && node.scope == selectedSlug) || (!snapshot.workspace.isEmpty && node.workspace == snapshot.workspace)
            }
        case .workspace:
            return snapshot.knowledgeGraphNodes.filter { node in
                node.workspace == snapshot.workspace || node.path == snapshot.workspace
            }
        }
    }

    private func graphAdjacencyMapForPrompt(edges: [KnowledgeGraphEdge], allowedNodeIDs: Set<String>) -> [String: [String]] {
        var adjacency: [String: Set<String>] = [:]
        for edge in edges {
            guard allowedNodeIDs.contains(edge.source), allowedNodeIDs.contains(edge.target) else { continue }
            adjacency[edge.source, default: []].insert(edge.target)
            adjacency[edge.target, default: []].insert(edge.source)
        }
        return adjacency.mapValues { neighbors in
            neighbors.sorted()
        }
    }

    private func graphDegreeCountsForPrompt(edges: [KnowledgeGraphEdge], allowedNodeIDs: Set<String>) -> [String: Int] {
        var counts: [String: Int] = [:]
        for edge in edges {
            guard allowedNodeIDs.contains(edge.source), allowedNodeIDs.contains(edge.target) else { continue }
            counts[edge.source, default: 0] += 1
            counts[edge.target, default: 0] += 1
        }
        return counts
    }

    private func loadTextFileForPrompt(_ path: String) -> String {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
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
        if let vaultRoot = request.vaultRoot {
            arguments += ["--vault-root", vaultRoot]
        }
        arguments += ["--snapshot-mode", request.snapshotMode]
        process.arguments = arguments
        process.environment = processEnvironmentWithoutBytecode()

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
        let stdoutURL = tempRoot.appendingPathComponent("fabric-\(UUID().uuidString)-stdout.json")
        let stderrURL = tempRoot.appendingPathComponent("fabric-\(UUID().uuidString)-stderr.log")
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
        try waitForProcessExit(process, timeout: snapshotCommandTimeout, commandDescription: "dashboard snapshot export")

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
        self.viewModel.recordOperation(
            title: "Running shared fabric storage setup",
            detail: "Bootstrapping the canonical global root from the setup assistant.",
            status: .running,
            commandPreview: command.joined(separator: " "),
            workspace: globalRoot,
            category: "Setup"
        )

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
                self.viewModel.recordOperation(
                    title: "Shared fabric storage ready",
                    detail: "Bootstrap completed for \(globalRootValue). Created \(createdCount) new path(s).",
                    status: .completed,
                    commandPreview: command.joined(separator: " "),
                    workspace: globalRootValue,
                    category: "Setup"
                )
            case .failure(let error):
                viewModel.statusTitle = "Storage setup failed"
                viewModel.statusDetails = error.localizedDescription
                self.viewModel.recordOperation(
                    title: "Shared fabric storage setup failed",
                    detail: error.localizedDescription,
                    status: .failed,
                    commandPreview: command.joined(separator: " "),
                    workspace: globalRoot,
                    category: "Setup"
                )
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
        self.viewModel.recordOperation(
            title: "Running workspace setup",
            detail: "Bootstrapping AGENTS.md and editor tasks for the selected workspace.",
            status: .running,
            commandPreview: command.joined(separator: " "),
            workspace: workspace,
            category: "Setup"
        )

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
                self.viewModel.recordOperation(
                    title: "Workspace setup completed",
                    detail: "Bootstrap completed for \(workspace). AGENTS and VS Code tasks were refreshed.",
                    status: .completed,
                    commandPreview: command.joined(separator: " "),
                    workspace: workspace,
                    category: "Setup"
                )
            case .failure(let error):
                viewModel.statusTitle = "Workspace setup failed"
                viewModel.statusDetails = error.localizedDescription
                self.viewModel.recordOperation(
                    title: "Workspace setup failed",
                    detail: error.localizedDescription,
                    status: .failed,
                    commandPreview: command.joined(separator: " "),
                    workspace: workspace,
                    category: "Setup"
                )
            }
        }
    }

    private func runSetupCommand(_ command: [String], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        Task.detached(priority: .userInitiated) {
            do {
                let payload = try await Self.executeJSONCommandAsync(command)
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

    private static func executeJSONCommandAsync(_ command: [String]) async throws -> [String: Any] {
        let result = try await executeExternalCommandAsync(arguments: command, timeout: setupCommandTimeout, commandDescription: command.joined(separator: " "))
        let stdoutText = result.stdoutText
        let stderrText = result.stderrText

        guard result.terminationStatus == 0 else {
            let message = stderrText.isEmpty ? stdoutText : stderrText
            throw NSError(
                domain: "SharedFabricSetup",
                code: Int(result.terminationStatus),
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
    private var statusItem: NSStatusItem?

    init(config: DashboardConfig) {
        self.config = config
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installAppIcon()
        installMenus()
        installStatusItem()
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

    @objc func showDashboardWindow(_ sender: Any?) {
        guard let controller = ensureController() else { return }
        controller.window?.makeKeyAndOrderFront(nil)
        controllers.compactMap(\.window).forEach { $0.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSettings(_ sender: Any?) {
        ensureController()?.openSettingsWindow()
    }

    @objc func showSetupAssistant(_ sender: Any?) {
        ensureController()?.openSetupWindow()
    }

    @objc func browseProjectMemory(_ sender: Any?) {
        ensureController()?.openProjectMemoryWindow(initialLane: nil)
    }

    @objc func refreshCurrent(_ sender: Any?) {
        ensureController()?.refreshNow()
    }

    @objc func showObservePanel(_ sender: Any?) {
        ensureController()?.showObservePanel()
    }

    @objc func showGeminiPanel(_ sender: Any?) {
        ensureController()?.showGeminiPanel()
    }

    @objc func showRuntimeLogs(_ sender: Any?) {
        ensureController()?.openOperationLogWindow()
    }

    @objc func followLatestWorkspace(_ sender: Any?) {
        ensureController()?.followLatestWorkspace()
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

    @objc func exportAgentChatHistory(_ sender: Any?) {
        ensureController()?.exportAgentChatHistoryNow(force: true)
    }

    @objc func exportAllAgentChatHistory(_ sender: Any?) {
        ensureController()?.exportAllKnownWorkspaceChatHistory()
    }

    @objc func normalizeObsidianVault(_ sender: Any?) {
        ensureController()?.normalizeObsidianVaultLayout()
    }

    @objc func processObsidianSources(_ sender: Any?) {
        ensureController()?.processObsidianSources()
    }

    @objc func buildAllProjectWikis(_ sender: Any?) {
        ensureController()?.buildAllProjectWikis()
    }

    @objc func refreshSelectedScope(_ sender: Any?) {
        ensureController()?.refreshSelectedScope()
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

    private func ensureController() -> FloatingDashboardController? {
        if let controller = activeController() {
            return controller
        }
        openNewWindow()
        return controllers.last
    }

    private func openNewWindow(seed: DashboardPreferences? = nil) {
        let preferences = seed ?? DashboardPreferences(config: config)
        let controller = FloatingDashboardController(
            config: config,
            preferences: preferences,
            onClose: { [weak self] closed in
                self?.controllers.removeAll(where: { $0 === closed })
                self?.refreshStatusItem()
            },
            onSnapshotUpdate: { [weak self] _ in
                self?.refreshStatusItem()
            }
        )
        controllers.append(controller)
        controller.start()
        refreshStatusItem()
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
            bundle.url(forResource: "Fabric", withExtension: "icns"),
            bundle.url(forResource: "Fabric", withExtension: "png"),
        ].compactMap { $0 }

        for url in iconCandidates {
            if let image = NSImage(contentsOf: url) {
                NSApp.applicationIconImage = image
                break
            }
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Fabric") {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageOnly
            } else {
                button.image = nil
            }
            button.title = ""
            button.toolTip = "Fabric"
        }
        statusItem = item
        refreshStatusItem()
    }

    private func refreshStatusItem() {
        guard let statusItem else { return }
        let menu = NSMenu()

        func menuAction(_ title: String, action: Selector, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            return item
        }

        func infoItem(_ title: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }

        func sectionHeader(_ title: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }

        let snapshot = activeController()?.currentSnapshot ?? controllers.last?.currentSnapshot
        if let button = statusItem.button {
            if let snapshot {
                let shortProject = snapshot.projectName == "(no workspace)" ? "Shared Fabric" : snapshot.projectName
                button.toolTip = "\(shortProject) · \(snapshot.runtime.uppercased()) · \(snapshot.lifecyclePhase)"
                button.title = ""
            } else {
                button.toolTip = "Fabric"
                button.title = ""
            }
        }

        menu.addItem(infoItem("Fabric"))
        if let snapshot {
            let phaseTitle = phaseLabels[snapshot.sixStageCurrent] ?? (snapshot.sixStageCurrent.isEmpty ? "Idle" : snapshot.sixStageCurrent.capitalized)
            menu.addItem(infoItem("\(snapshot.projectName) · \(snapshot.lifecyclePhase)"))
            menu.addItem(infoItem("\(snapshot.runtime.uppercased()) · \(phaseTitle)"))
            if !snapshot.workspace.isEmpty {
                menu.addItem(infoItem(snapshot.workspace))
            }
        } else {
            menu.addItem(infoItem("No active Fabric snapshot yet"))
        }
        menu.addItem(.separator())

        menu.addItem(sectionHeader("1. Shared Fabric Setup"))
        menu.addItem(menuAction("Set Up Shared Fabric…", action: #selector(showSetupAssistant(_:))))
        menu.addItem(menuAction("Open Shared Fabric Sync Folder", action: #selector(openSharedFabricSync(_:)), enabled: activeController() != nil))
        menu.addItem(.separator())

        menu.addItem(sectionHeader("2. Fabric Monitor"))
        menu.addItem(menuAction("Open Fabric", action: #selector(showDashboardWindow(_:))))
        menu.addItem(menuAction("Open Activity Panel", action: #selector(showObservePanel(_:)), enabled: activeController() != nil))
        menu.addItem(menuAction("Open Runtime Logs", action: #selector(showRuntimeLogs(_:)), enabled: activeController() != nil))
        menu.addItem(menuAction("Refresh Current Window", action: #selector(refreshCurrent(_:)), enabled: activeController() != nil))
        menu.addItem(menuAction("Browse Project Memory", action: #selector(browseProjectMemory(_:)), enabled: activeController()?.currentSnapshot != nil))
        menu.addItem(.separator())

        menu.addItem(sectionHeader("3. Obsidian Wiki Foundation"))
        menu.addItem(menuAction("Normalize Vault", action: #selector(normalizeObsidianVault(_:)), enabled: activeController()?.currentSnapshot != nil))
        menu.addItem(.separator())

        menu.addItem(sectionHeader("4. Sources + Deep Extraction"))
        menu.addItem(menuAction("Process Sources Prompt", action: #selector(processObsidianSources(_:)), enabled: activeController()?.currentSnapshot != nil))
        menu.addItem(menuAction("Build All Prompt", action: #selector(buildAllProjectWikis(_:)), enabled: activeController()?.currentSnapshot != nil))
        if dataAcquisitionFeaturesEnabled {
            menu.addItem(menuAction("Export Agent Chat History", action: #selector(exportAgentChatHistory(_:)), enabled: activeController()?.currentSnapshot != nil))
            menu.addItem(menuAction("Export All Known Workspaces", action: #selector(exportAllAgentChatHistory(_:)), enabled: activeController()?.currentSnapshot != nil))
        }
        menu.addItem(.separator())

        menu.addItem(sectionHeader("5. Graph + Terminal"))
        menu.addItem(menuAction("Follow Latest Workspace", action: #selector(followLatestWorkspace(_:)), enabled: activeController() != nil))
        menu.addItem(menuAction("Open Terminal Panel", action: #selector(showGeminiPanel(_:)), enabled: activeController() != nil))
        menu.addItem(.separator())

        menu.addItem(menuAction("Quit Fabric", action: #selector(NSApplication.terminate(_:))))

        statusItem.menu = menu
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
        appMenu.addItem(targetedItem("About Fabric", action: #selector(showAbout(_:)), key: "", modifiers: []))
        appMenu.addItem(.separator())
        appMenu.addItem(targetedItem("Settings…", action: #selector(showSettings(_:)), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Fabric", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Fabric", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(quitItem)

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(targetedItem("New Window", action: #selector(newWindow(_:)), key: "n"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(targetedItem("Set Up Shared Fabric…", action: #selector(showSetupAssistant(_:)), key: "", modifiers: []))
        fileMenu.addItem(targetedItem("Open Shared Fabric Sync Folder", action: #selector(openSharedFabricSync(_:)), key: "", modifiers: []))
        fileMenu.addItem(.separator())
        fileMenu.addItem(targetedItem("Open Current Workspace in Finder", action: #selector(openCurrentWorkspace(_:)), key: "o", modifiers: [.command, .shift]))
        fileMenu.addItem(targetedItem("Open Activity Panel", action: #selector(showObservePanel(_:)), key: "a", modifiers: [.command, .shift]))
        fileMenu.addItem(targetedItem("Open Terminal Panel", action: #selector(showGeminiPanel(_:)), key: "t", modifiers: [.command, .shift]))
        fileMenu.addItem(targetedItem("Open Runtime Logs", action: #selector(showRuntimeLogs(_:)), key: "l", modifiers: [.command, .shift]))
        fileMenu.addItem(.separator())
        fileMenu.addItem(targetedItem("Normalize Vault", action: #selector(normalizeObsidianVault(_:)), key: "k", modifiers: [.command, .shift]))
        fileMenu.addItem(targetedItem("Process Sources Prompt", action: #selector(processObsidianSources(_:)), key: "i", modifiers: [.command, .shift]))
        fileMenu.addItem(targetedItem("Build All Prompt", action: #selector(buildAllProjectWikis(_:)), key: "b", modifiers: [.command, .shift]))
        if dataAcquisitionFeaturesEnabled {
            fileMenu.addItem(targetedItem("Export Agent Chat History", action: #selector(exportAgentChatHistory(_:)), key: "e", modifiers: [.command, .shift]))
            fileMenu.addItem(targetedItem("Export All Known Workspaces", action: #selector(exportAllAgentChatHistory(_:)), key: "e", modifiers: [.command, .option, .shift]))
        }
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
        helpMenu.addItem(targetedItem("Open Fabric Docs", action: #selector(openHelp(_:)), key: "?", modifiers: [.command, .shift]))

        NSApp.mainMenu = mainMenu
    }
}

func parseConfig() -> DashboardConfig {
    let environment = ProcessInfo.processInfo.environment
    let fileManager = FileManager.default

    func findWorkspaceRoot(from start: URL) -> String? {
        var current = start.standardizedFileURL.path
        for _ in 0..<16 {
            let snapshot = (current as NSString).appendingPathComponent("tools/compact_dashboard/export_snapshot.py")
            if fileManager.fileExists(atPath: snapshot) {
                return current
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty {
                return nil
            }
            current = parent
        }
        return nil
    }

    func bundledSnapshotScript() -> String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let candidate = resourceURL
            .appendingPathComponent("compact_dashboard")
            .appendingPathComponent("export_snapshot.py")
        return fileManager.fileExists(atPath: candidate.path) ? candidate.path : nil
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

    func defaultVaultRoot() -> String? {
        if let override = environment["SHARED_FABRIC_DASHBOARD_VAULT_ROOT"], !override.isEmpty {
            return override
        }
        if let override = environment["MCP_HUB_DASHBOARD_VAULT_ROOT"], !override.isEmpty {
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
            let candidate = URL(fileURLWithPath: workspace)
                .appendingPathComponent("tools/compact_dashboard/export_snapshot.py")
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }
        if let bundled = bundledSnapshotScript() {
            return bundled
        }

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent(),
            Bundle.main.resourceURL,
            executableURL.deletingLastPathComponent(),
            URL(fileURLWithPath: fileManager.currentDirectoryPath).resolvingSymlinksInPath(),
        ].compactMap { $0 }
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
    var vaultRoot = defaultVaultRoot()
    var geminiSettings: String?
    var snapshotScript = defaultSnapshotScript(workspace: workspace)
    var snapshotScriptWasExplicit = environment["SHARED_FABRIC_DASHBOARD_SNAPSHOT_SCRIPT"]?.isEmpty == false || environment["MCP_HUB_DASHBOARD_SNAPSHOT_SCRIPT"]?.isEmpty == false

    var index = 1
    let args = CommandLine.arguments
    while index < args.count {
        let arg = args[index]
        if arg == "--workspace", index + 1 < args.count {
            workspace = args[index + 1]
            if !snapshotScriptWasExplicit {
                snapshotScript = defaultSnapshotScript(workspace: workspace)
            }
            index += 2
            continue
        }
        if arg == "--global-root", index + 1 < args.count {
            globalRoot = args[index + 1]
            index += 2
            continue
        }
        if arg == "--vault-root", index + 1 < args.count {
            vaultRoot = args[index + 1]
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
            snapshotScriptWasExplicit = true
            index += 2
            continue
        }
        index += 1
    }

    return DashboardConfig(
        initialWorkspace: workspace,
        initialGlobalRoot: globalRoot,
        initialVaultRoot: vaultRoot,
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
