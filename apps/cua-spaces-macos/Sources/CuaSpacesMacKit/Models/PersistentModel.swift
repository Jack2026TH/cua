// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import AppKit
import CuaSDK
import CuaSpacesFFI
import Foundation
import Observation
import UserNotifications

/// Runs one Spaces tool (the daemon's `CallSpaceTool`) and answers its JSON.
public protocol AgentsToolRunning: AnyObject, Sendable {
    func agentsTool(_ tool: String, _ args: [String: Any]) async throws -> Any
}

/// A tool's error, as the daemon worded it.
public struct AgentsToolError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

extension LiveSpacesBackend: AgentsToolRunning {
    public func agentsTool(_ tool: String, _ args: [String: Any]) async throws -> Any {
        let data = try JSONSerialization.data(withJSONObject: args)
        let r = try await cua.spaces().callToolJson(tool: tool, argumentsJson: String(decoding: data, as: UTF8.self))
        if r.isError {
            throw AgentsToolError(message: r.text.hasPrefix("error: ") ? String(r.text.dropFirst(7)) : r.text)
        }
        return (try? JSONSerialization.jsonObject(with: Data(r.text.utf8))) ?? r.text
    }
}

private func json(_ v: Any) -> String {
    (try? JSONSerialization.data(withJSONObject: v)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
}

private extension Dictionary where Key == String, Value == Any {
    func arr(_ k: String) -> [[String: Any]] { (self[k] as? [Any] ?? []).compactMap { $0 as? [String: Any] } }
}

public struct WorkspaceAgent: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let harness: String
    public let space: String
    public let paused: Bool
    public let runId: String?
}

public enum WorkspaceMessageRole: String, Equatable, Sendable {
    case you
    case agent
    case system
}

public struct WorkspaceMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let role: WorkspaceMessageRole
    public let author: String
    public let target: String?
    public let text: String
    public let runId: String?
    public let space: String?
}

public struct WorkspaceRun: Identifiable, Equatable, Sendable {
    public var id: String { runId }
    public let runId: String
    public let agent: String
    public let space: String
    public let status: String
    public let phase: String
}

/// The Agents, Drive and Notifications pages: the app core's `agents.*`,
/// `drive.*` and `notifications.*` over the daemon's tools. Allowing an agent
/// on a computer and approving a drive request ask for presence in the
/// daemon (Touch ID) first.
@MainActor @Observable
public final class PersistentModel {
    private let tools: AgentsToolRunning?
    /// This machine's Space id when it is set up for access.
    public var thisMachine: String?
    var agentsInput: [String: Any] = ["agents": []]
    public private(set) var agentsState = appAgentsInitial()
    public private(set) var workspaceMessages: [WorkspaceMessage] = []
    public private(set) var workspaceRuns: [WorkspaceRun] = []
    public private(set) var workspaceError: String?
    public private(set) var workspaceSending = false
    var driveInput: [String: Any] = ["requests": [], "grants": [], "home": userHome()]
    public private(set) var driveState = appDriveInitial()
    /// Shows a path in Finder (the mount, a conflict's copy).
    public var reveal: (String) -> Void = { path in
        // The daemon may answer `~/Cua Volume`.
        let full = homeExpanded(path)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)])
    }
    public private(set) var feed: [AppNotificationInput] = []
    /// Cua Volume's sync status (the menu bar's sync line), when read.
    public private(set) var driveSync: AppDriveSyncInput?
    /// `volume_storage`'s backend (the menu hides sync on this Mac's store
    /// with no other device).
    public private(set) var driveBackend: String?
    /// Posts one system notification.
    public var post: ((AppSystemNote) -> Void)?
    /// Reads and writes the last-seen marker (the app settings file).
    public var seenMs: () -> UInt64 = { 0 }
    public var saveSeenMs: (UInt64) -> Void = { _ in }
    /// The clock the pages' relative times read (tests pin it).
    public var now: () -> Date = Date.init

    public init(tools: AgentsToolRunning?) {
        self.tools = tools
    }

    func typedAgents() -> AppAgentsInput {
        var i = agentsInput
        i["thisMachine"] = thisMachine
        return (try? appAgentsInputFromJson(json: json(i))) ?? appAgentsInputFromJsonFallback()
    }

    private func appAgentsInputFromJsonFallback() -> AppAgentsInput {
        try! appAgentsInputFromJson(json: "{\"agents\":[]}")
    }

    public func agentsView() -> AppAgentsView {
        appAgentsView(input: typedAgents(), state: agentsState, nowMs: UInt64(now().timeIntervalSince1970 * 1000))
    }

    public func driveView() -> AppDriveView {
        var i = driveInput
        i["nowMs"] = UInt64(now().timeIntervalSince1970 * 1000)
        return appDriveView(input: (try? appDriveInputFromJson(json: json(i))) ?? (try! appDriveInputFromJson(json: "{}")),
                            state: driveState)
    }

    public func notificationsView() -> AppNotificationsView {
        appNotificationsView(feed: feed, nowMs: UInt64(now().timeIntervalSince1970 * 1000))
    }

    // MARK: - Agents

    private func call(_ tool: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        guard let tools else { throw AgentsToolError(message: "Agents need the cua daemon") }
        return (try await tools.agentsTool(tool, args) as? [String: Any]) ?? [:]
    }

    /// Persistent agents on this machine, once listed.
    public var agentCount: Int { (agentsInput["agents"] as? [Any])?.count ?? 0 }

    public func loadAgents() async {
        guard let r = try? await call("persistent_agent_list") else { return }
        agentsInput["agents"] = r.arr("agents").map { a in
            ["name": a["name"] ?? "", "harness": a["harness"] ?? "", "space": a["space"] ?? "",
             "paused": a["paused"] ?? false, "spaceState": a["space_state"] ?? "running",
             "runId": a["run_id"] ?? NSNull(), "savedMs": a["saved_ms"] ?? 0,
             "lastError": a["last_error"] ?? NSNull()] as [String: Any]
        }
    }

    /// The same persistent-agent roster the Agents page renders, exposed for
    /// the collaborative workspace without creating a second source of truth.
    public var workspaceAgents: [WorkspaceAgent] {
        (agentsInput["agents"] as? [[String: Any]] ?? []).map {
            WorkspaceAgent(name: $0["name"] as? String ?? "",
                           harness: $0["harness"] as? String ?? "",
                           space: $0["space"] as? String ?? "",
                           paused: $0["paused"] as? Bool ?? false,
                           runId: $0["runId"] as? String)
        }
    }

    private func workspaceAgent(named name: String) -> WorkspaceAgent? {
        workspaceAgents.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    private func upsertWorkspaceRun(_ run: WorkspaceRun) {
        if let index = workspaceRuns.firstIndex(where: { $0.runId == run.runId }) {
            workspaceRuns[index] = run
        } else {
            workspaceRuns.insert(run, at: 0)
        }
    }

    /// One collaborative turn over the daemon's existing persistent-agent
    /// transport. A live run is resumed; otherwise the configured persistent
    /// agent is started in its existing Space.
    public func workspaceSend(name: String, text: String, label: String = "You",
                              displayText: String? = nil) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !workspaceSending else { return }
        guard let agent = workspaceAgent(named: name) else {
            workspaceError = "Persistent agent \"\(name)\" was not found"
            return
        }

        workspaceSending = true
        workspaceError = nil
        workspaceMessages.append(WorkspaceMessage(id: UUID(), role: .you, author: label,
                                                  target: agent.name, text: displayText ?? body,
                                                  runId: nil, space: agent.space))
        defer { workspaceSending = false }

        do {
            if agent.paused {
                _ = try await call("agent_resume", ["name": agent.name])
            }

            let receipt: [String: Any]
            if let runId = agent.runId, !runId.isEmpty {
                receipt = try await call("agent_message", [
                    "space": agent.space,
                    "run_id": runId,
                    "text": body,
                ])
            } else {
                receipt = try await call("agent_start", [
                    "space": agent.space,
                    "agent": agent.harness,
                    "prompt": body,
                    "home": agent.name,
                    "show": false,
                ])
            }

            guard let runId = (receipt["run_id"] as? String) ?? agent.runId, !runId.isEmpty else {
                throw AgentsToolError(message: "Agent did not return a run id")
            }
            let space = receipt["space"] as? String ?? agent.space
            upsertWorkspaceRun(WorkspaceRun(runId: runId, agent: agent.name, space: space,
                                            status: receipt["status"] as? String ?? "running",
                                            phase: receipt["phase"] as? String ?? ""))
            try await pollWorkspaceRun(agent: agent.name, space: space, runId: runId)
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    public func workspaceHandoff(to target: String, from selected: String?) async {
        let source = workspaceMessages.reversed().first(where: { $0.role == .agent })?.author
            ?? selected ?? "Workspace"
        let context = workspaceMessages.suffix(8).map { message in
            let arrow = message.target.map { " → \($0)" } ?? ""
            return "\(message.author)\(arrow): \(message.text)"
        }.joined(separator: "\n")
        let prompt = """
        Handoff from \(source).
        Continue the task from the shared workspace context below. Preserve completed work and do not repeat finished steps.

        \(context.isEmpty ? "No prior thread messages." : context)
        """
        await workspaceSend(name: target, text: prompt, label: "Handoff · \(source)",
                            displayText: "Continue from \(source)")
    }

    private func pollWorkspaceRun(agent: String, space: String, runId: String) async throws {
        let terminal: Set<String> = ["idle", "failed", "crashed"]
        var lastStatus = "running"
        var lastPhase = ""

        for _ in 0..<40 {
            if Task.isCancelled { return }
            let status = try await call("agent_status", ["space": space, "run_id": runId, "tail": 20])
            lastStatus = status["status"] as? String ?? "unknown"
            lastPhase = status["phase"] as? String ?? ""
            upsertWorkspaceRun(WorkspaceRun(runId: runId, agent: agent, space: space,
                                            status: lastStatus, phase: lastPhase))

            if terminal.contains(lastStatus) {
                let result = status["result"] as? [String: Any] ?? [:]
                let candidates = [
                    result["text"] as? String,
                    status["summary"] as? String,
                    result["error"] as? String,
                    status["reason"] as? String,
                ]
                let text = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty }) ?? (lastStatus == "idle" ? "Done." : "Run \(lastStatus).")
                workspaceMessages.append(WorkspaceMessage(id: UUID(),
                                                          role: lastStatus == "idle" ? .agent : .system,
                                                          author: lastStatus == "idle" ? agent : "System",
                                                          target: nil, text: text,
                                                          runId: runId, space: space))
                await loadAgents()
                return
            }

            try await Task.sleep(nanoseconds: 1_200_000_000)
        }

        workspaceMessages.append(WorkspaceMessage(id: UUID(), role: .system, author: "System",
                                                  target: nil,
                                                  text: "\(agent) is still \(lastStatus)\(lastPhase.isEmpty ? "" : " · \(lastPhase)").",
                                                  runId: runId, space: space))
    }

    private func loadDetail(_ name: String) async throws {
        var files: [[String: Any]] = []
        var queue = ["agents/\(name)/"]
        var folders = 0
        while !queue.isEmpty, folders < 50, files.count < 500 {
            folders += 1
            let path = queue.removeFirst()
            for e in try await call("volume_ls", ["path": path]).arr("entries") {
                if e["folder"] as? Bool == true { queue.append(e["path"] as? String ?? "") }
                else { files.append(["path": e["path"] ?? "", "name": e["name"] ?? "", "size": e["size"] ?? 0]) }
            }
        }
        let routines = try await call("routine_list", ["agent": name]).arr("routines").map { r in
            ["id": r["id"] ?? "", "title": r["title"] ?? "", "label": r["label"] ?? "",
             "enabled": (r["isEnabled"] as? Bool) ?? true] as [String: Any]
        }
        let access = try await call("computer_access_list", ["audit": 20])
        agentsInput["home"] = files
        agentsInput["routines"] = routines
        agentsInput["grants"] = access.arr("grants").map { ["agent": $0["agent"] ?? "", "machine": $0["machine"] ?? "", "revoked": $0["revoked"] ?? false] }
        agentsInput["audit"] = access.arr("audit").map { ["tsMs": $0["ts_ms"] ?? 0, "action": $0["action"] ?? "", "principal": $0["principal"] ?? "", "path": $0["path"] ?? "", "detail": $0["detail"] ?? ""] }
    }

    public func send(_ action: AppAgentsAction) async {
        let before = agentsState
        agentsState = appAgentsReduce(input: typedAgents(), state: before, action: action)
        guard !before.busy, let request = agentsState.request else { return }
        do {
            switch request {
            case let .load(name): try await loadDetail(name)
            case let .readFile(path):
                async let f = call("volume_read", ["path": path])
                async let h = call("volume_history", ["path": path])
                let (file, history) = try await (f, h)
                let binary = file["encoding"] as? String == "base64"
                agentsInput["file"] = ["path": path, "text": binary ? "" : (file["content"] ?? ""), "binary": binary,
                                       "versions": history.arr("versions").map { ["version": $0["version"] ?? "", "modifiedMs": $0["modified_ms"] ?? 0, "deleted": $0["deleted"] ?? false, "latest": $0["latest"] ?? false] }] as [String: Any]
            case let .pause(name):
                _ = try await call("agent_pause", ["name": name]); await loadAgents()
            case let .resume(name):
                _ = try await call("agent_resume", ["name": name]); await loadAgents()
            case let .restore(path, version):
                _ = try await call("volume_restore", ["path": path, "version": version])
            case let .addRoutine(agent, title, prompt, everyMinutes, dailyAt, weeklyOn):
                var args: [String: Any] = ["agent": agent, "title": title, "prompt": prompt]
                if let m = everyMinutes { args["every_minutes"] = m }
                if let d = dailyAt { args["daily_at"] = d }
                if let w = weeklyOn { args["weekly_on"] = w }
                _ = try await call("routine_add", args)
            case let .setRoutine(id, enabled): _ = try await call("routine_set_enabled", ["id": id, "enabled": enabled])
            case let .removeRoutine(id): _ = try await call("routine_remove", ["id": id])
            case let .allow(agent, machine): _ = try await call("computer_access_grant", ["agent": agent, "machine": machine])
            case let .revoke(agent, machine): _ = try await call("computer_access_revoke", ["agent": agent, "machine": machine])
            }
            switch request {
            case .load, .readFile, .pause, .resume: break
            default: if let n = agentsState.selected { try? await loadDetail(n) }
            }
            agentsState = appAgentsReduce(input: typedAgents(), state: agentsState, action: .done)
        } catch {
            agentsState = appAgentsReduce(input: typedAgents(), state: agentsState,
                                          action: .failed(error: error.localizedDescription))
        }
    }

    // MARK: - Drive

    public func sendDrive(_ action: AppDriveAction?) async {
        let before = driveState
        if let action { driveState = appDriveReduce(state: before, action: action) }
        guard action == nil || !before.busy, let request = driveState.request else { return }
        do {
            switch request {
            case .load: break
            case .mountAndReveal:
                let status = try await call("volume_mount")
                guard status["state"] as? String == "mounted", let path = status["path"] as? String else {
                    throw AgentsToolError(message: status["detail"] as? String ?? "The volume could not be mounted")
                }
                reveal(path)
            case let .approve(id): _ = try await call("volume_approve", ["request_id": id])
            case let .deny(id): _ = try await call("volume_deny", ["request_id": id])
            case let .revoke(id): _ = try await call("volume_revoke", ["grant_id": id])
            case let .reveal(path): reveal(path)
            case let .resolve(path): _ = try await call("volume_sync_resolve", ["path": path])
            }
            async let rq = call("volume_requests")
            async let gr = call("volume_grants")
            let (q, g) = try await (rq, gr)
            await refreshDriveSync()
            let listed: [String: Any] = [
                "requests": q.arr("requests").map { ["id": $0["id"] ?? "", "principal": $0["principal"] ?? "", "prefix": $0["prefix"] ?? "", "mode": $0["mode"] ?? "r", "reason": $0["reason"] ?? ""] },
                "grants": g.arr("grants").map { ["id": $0["id"] ?? "", "principal": $0["principal"] ?? "", "prefix": $0["prefix"] ?? "", "mode": $0["mode"] ?? "r", "revoked": $0["revoked"] ?? false] },
            ]
            for (k, v) in listed { driveInput[k] = v }
            driveState = appDriveReduce(state: driveState, action: .done)
        } catch {
            driveState = appDriveReduce(state: driveState, action: .failed(error: error.localizedDescription))
        }
    }

    /// Reads the mount and the sync status (each on its own: a daemon
    /// without them leaves the page as it was, with no mount and no sync).
    public func refreshDriveSync() async {
        async let m = try? call("volume_mount_status")
        async let s = try? call("volume_sync_status")
        let (mount, sync) = await (m, s)
        driveInput["mount"] = mount ?? NSNull()
        driveInput["sync"] = sync ?? NSNull()
        driveSync = sync.flatMap { try? appDriveSyncFromJson(json: json($0)) }
    }

    /// Reads the sync status alone (the menu bar polls it).
    public func refreshSync() async {
        driveBackend = (try? await call("volume_storage"))?["backend"] as? String
        let sync = try? await call("volume_sync_status")
        driveSync = sync.flatMap { try? appDriveSyncFromJson(json: json($0)) }
    }

    // MARK: - Notifications

    /// One poll of the feed: post what the core says, save the marker.
    public func pollNotifications() async {
        guard let r = try? await call("notifications_list") else { return }
        let rows = r.arr("notifications").map { n in
            ["id": n["id"] ?? "", "atMs": n["at_ms"] ?? 0, "agent": n["agent"] ?? NSNull(), "kind": n["kind"] ?? "",
             "title": n["title"] ?? "", "body": n["body"] ?? "", "read": n["read"] ?? false] as [String: Any]
        }
        guard let typed = try? appNotificationsFromJson(json: json(rows)) else { return }
        feed = typed
        let seen = seenMs()
        let plan = appNotificationsPlan(feed: typed, seenMs: seen)
        plan.post.forEach { post?($0) }
        if plan.seenMs != seen { saveSeenMs(plan.seenMs) }
    }

    public func markAllRead() async {
        _ = try? await call("notifications_ack", ["ids": [String]()])
        await pollNotifications()
    }

    /// Polls every `seconds` while the app runs (the daemon owns the feed).
    public func startPolling(every seconds: Double = 5) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollNotifications()
                await self?.refreshSync()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }
}

/// System notifications for the daemon's feed. Only a bundled app posts
/// them (a test process has no notification identity).
@MainActor
final class AgentNotifier {
    static let shared = AgentNotifier()
    private var authorized: Bool?

    func post(_ note: AppSystemNote) {
        guard DeviceNotifier.available else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        let request = UNNotificationRequest(identifier: "agent-\(note.id)", content: content, trigger: nil)
        Task {
            if authorized == nil {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }
            guard authorized == true else { return }
            try? await center.add(request)
        }
    }
}
