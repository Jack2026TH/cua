// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import SwiftUI

/// Collaborative workspace over the existing persistent-agent transport.
/// No second execution layer: @mentions resume/start the configured agent in
/// its current Space and the run list only reads agent_status.
struct WorkspacePageView: View {
    @Bindable var model: PersistentModel
    let openSpace: (String) -> Void

    @State private var selectedName: String?
    @State private var draft = ""
    @State private var localError: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()
                thread
                if let error = localError ?? model.workspaceError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                Divider()
                composer
            }
            Divider()
            context
                .frame(width: 290)
        }
        .task {
            await model.loadAgents()
            if selectedName == nil {
                selectedName = model.workspaceAgents.first?.name
            }
        }
    }

    private var selectedAgent: WorkspaceAgent? {
        guard let selectedName else { return nil }
        return model.workspaceAgents.first { $0.name == selectedName }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Workspace").font(.headline)
                Text("People, agents and computer runs in one thread.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let agent = selectedAgent {
                Button("Open \(agent.space)") { openSpace(agent.space) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var thread: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if model.workspaceMessages.isEmpty {
                    VStack(spacing: 6) {
                        Text("Start with an @mention").font(.headline)
                        Text("Select an agent or type @name. Existing persistent runs are resumed.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: 420)
                    .padding(.vertical, 80)
                } else {
                    ForEach(model.workspaceMessages) { message in
                        messageRow(message)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func messageRow(_ message: WorkspaceMessage) -> some View {
        HStack {
            if message.role == .you { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(message.author).font(.caption.weight(.semibold))
                    if let target = message.target {
                        Text("→ \(target)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let runId = message.runId {
                        Text(runId)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Text(message.text)
                    .frame(maxWidth: 680, alignment: .leading)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(message.role == .you ? Color.secondary.opacity(0.12) :
                        message.role == .system ? Color.clear : Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(message.role == .system ? Color.secondary.opacity(0.35) : Color.clear)
            }
            if message.role != .you { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            TextField(selectedName.map { "Message @\($0)…" } ?? "Message @agent…",
                      text: $draft, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit { send() }
            HStack {
                Text(selectedName.map { "Routing to \($0) unless @name overrides it" } ?? "Choose a participant")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(model.workspaceSending ? "Sending…" : "Send") { send() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.workspaceSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
    }

    private var context: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sectionTitle("Participants")
                if model.workspaceAgents.isEmpty {
                    Text("No persistent agents configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(model.workspaceAgents) { agent in
                            participant(agent)
                        }
                    }
                }

                sectionTitle("Runs")
                if model.workspaceRuns.isEmpty {
                    Text("No runs in this workspace yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(model.workspaceRuns) { run in
                            Button {
                                openSpace(run.space)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(run.agent).fontWeight(.semibold)
                                        Spacer()
                                        Text(run.status).foregroundStyle(.secondary)
                                    }
                                    Text(run.runId)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                    Text(run.phase.isEmpty ? run.space : "\(run.space) · \(run.phase)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(7)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(Color.secondary.opacity(0.04))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func participant(_ agent: WorkspaceAgent) -> some View {
        HStack(spacing: 6) {
            Button {
                selectedName = agent.name
                localError = nil
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("@\(agent.name)").fontWeight(.semibold)
                    Text("\(agent.harness) · \(agent.space)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(selectedName == agent.name ? Color.accentColor.opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)

            Button("Handoff") {
                localError = nil
                Task { await model.workspaceHandoff(to: agent.name, from: selectedName) }
            }
            .controlSize(.mini)
            .disabled(model.workspaceMessages.isEmpty || model.workspaceSending)
        }
    }

    private func send() {
        guard let (agent, text) = routedDraft else {
            localError = model.workspaceAgents.isEmpty
                ? "No persistent agents configured."
                : "Choose an agent or start the message with @name."
            return
        }
        localError = nil
        draft = ""
        selectedName = agent.name
        Task { await model.workspaceSend(name: agent.name, text: text) }
    }

    private var routedDraft: (WorkspaceAgent, String)? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        for agent in model.workspaceAgents.sorted(by: { $0.name.count > $1.name.count }) {
            let mention = "@\(agent.name)".lowercased()
            if lower == mention || lower.hasPrefix(mention + " ") || lower.hasPrefix(mention + "\n") {
                let offset = min(trimmed.count, agent.name.count + 1)
                let index = trimmed.index(trimmed.startIndex, offsetBy: offset)
                let body = String(trimmed[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return body.isEmpty ? nil : (agent, body)
            }
        }

        guard let agent = selectedAgent else { return nil }
        return (agent, trimmed)
    }
}
