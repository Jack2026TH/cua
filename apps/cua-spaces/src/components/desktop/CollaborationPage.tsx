// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import { useCallback, useEffect, useMemo, useState } from 'react';

import type { Space } from '../../model/types';

const POLL_MS = 4_000;

type AgentStatus = 'running' | 'idle' | 'failed' | 'crashed' | 'unknown';

interface CollaborationAgent {
  name: string;
  harness: string;
  space: string;
  paused?: boolean;
  spaceState?: string;
  runId?: string | null;
}

interface CollaborationRun {
  runId: string;
  agent: string;
  status: AgentStatus;
  reason: string;
  summary: string;
  createdAt: number | null;
}

interface CollaborationAgentsBridge {
  agents(): Promise<CollaborationAgent[]>;
  sendMessage(name: string, text: string): Promise<void>;
}

interface CollaborationTeleportBridge {
  listSpaceAgents(spaceId: string): Promise<CollaborationRun[]>;
}

const STATUS_LABEL: Record<AgentStatus, string> = {
  running: 'Running',
  idle: 'Idle',
  failed: 'Failed',
  crashed: 'Crashed',
  unknown: 'Unknown',
};

const STATUS_DOT: Record<AgentStatus, string> = {
  running: 'status-provisioning',
  idle: 'status-running',
  failed: 'status-error',
  crashed: 'status-error',
  unknown: 'status-unknown',
};

const AGENT_LABEL: Record<string, string> = {
  'claude-code': 'Claude Code',
  'openai-codex': 'OpenAI Codex',
  'gemini-cli': 'Gemini CLI',
  hermes: 'Hermes',
  openclaw: 'OpenClaw',
};

function agentLabel(agent: string): string {
  return AGENT_LABEL[agent] ?? (agent || 'Unknown');
}

type RunRow = {
  space: Space;
  run: CollaborationRun;
};

function mentionOf(value: string): { name: string; text: string } | null {
  const match = value.trim().match(/^@([a-zA-Z0-9._-]+)\s+([\s\S]+)$/);
  if (!match) return null;
  const text = match[2]!.trim();
  return text ? { name: match[1]!, text } : null;
}

export function CollaborationPage({
  spaces,
  agentsBridge,
  teleport,
  onOpenSpace,
}: {
  spaces: Space[];
  agentsBridge: CollaborationAgentsBridge;
  teleport: CollaborationTeleportBridge;
  onOpenSpace: (id: string) => void;
}) {
  const [agents, setAgents] = useState<CollaborationAgent[]>([]);
  const [runs, setRuns] = useState<RunRow[]>([]);
  const [composer, setComposer] = useState('');
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    const [agentResult, ...runResults] = await Promise.all([
      agentsBridge.agents().then(
        (value) => ({ ok: true as const, value }),
        () => ({ ok: false as const, value: [] as CollaborationAgent[] }),
      ),
      ...spaces.map((space) =>
        teleport.listSpaceAgents(space.id).then(
          (value) => ({ ok: true as const, value, space }),
          () => ({ ok: false as const, value: [] as CollaborationRun[], space }),
        ),
      ),
    ]);

    if (agentResult.ok) setAgents(agentResult.value);
    setRuns(
      runResults
        .flatMap((result) =>
          result.ok ? result.value.map((run) => ({ space: result.space, run })) : [],
        )
        .sort((a, b) => (b.run.createdAt ?? 0) - (a.run.createdAt ?? 0)),
    );
  }, [agentsBridge, spaces, teleport]);

  useEffect(() => {
    void refresh();
    const timer = window.setInterval(() => void refresh(), POLL_MS);
    return () => window.clearInterval(timer);
  }, [refresh]);

  const agentByName = useMemo(
    () => new Map(agents.map((agent) => [agent.name.toLowerCase(), agent])),
    [agents],
  );

  const send = useCallback(async () => {
    const parsed = mentionOf(composer);
    if (!parsed) {
      setError('Use @agent followed by a message.');
      setNotice(null);
      return;
    }
    const agent = agentByName.get(parsed.name.toLowerCase());
    if (!agent) {
      setError(`Unknown agent @${parsed.name}.`);
      setNotice(null);
      return;
    }
    if (agent.paused) {
      setError(`@${agent.name} is paused. Resume it from Agents first.`);
      setNotice(null);
      return;
    }

    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      await agentsBridge.sendMessage(agent.name, parsed.text);
      setComposer('');
      setNotice(`Sent to @${agent.name}.`);
      await refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }, [agentByName, agentsBridge, composer, refresh]);

  return (
    <div className="ag-page collab-page">
      <div className="ag-detail-head">
        <div>
          <h2>Workspace</h2>
          <span className="st-note">Spaces, agents, messages and live runs in one place.</span>
        </div>
      </div>

      <section className="st-group" aria-label="People and agents">
        <div className="st-head">
          <h3 className="st-title">People & agents</h3>
        </div>
        <div className="st-rows">
          <div className="st-row">
            <span className="st-label">You</span>
            <span className="st-value">Operator</span>
          </div>
          {agents.length === 0 ? (
            <p className="st-note">No persistent agents found.</p>
          ) : (
            agents.map((agent) => (
              <div className="st-row" key={agent.name}>
                <button
                  type="button"
                  className="st-label ag-link"
                  onClick={() => setComposer(`@${agent.name} `)}
                >
                  @{agent.name}
                </button>
                <span className="st-value">
                  {agent.harness} · {agent.paused ? 'paused' : agent.runId ? 'active' : agent.spaceState ?? 'ready'}
                </span>
              </div>
            ))
          )}
        </div>
      </section>

      <section className="st-group" aria-label="Message agent">
        <div className="st-head">
          <h3 className="st-title">Message</h3>
        </div>
        <div className="collab-composer">
          <input
            className="dw-input"
            aria-label="Message an agent"
            placeholder="@agent what should happen next?"
            value={composer}
            disabled={busy}
            onChange={(event) => setComposer(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === 'Enter' && !event.shiftKey) {
                event.preventDefault();
                void send();
              }
            }}
          />
          <button
            type="button"
            className="dw-btn dw-btn-primary"
            disabled={busy || !composer.trim()}
            onClick={() => void send()}
          >
            {busy ? 'Sending…' : 'Send'}
          </button>
        </div>
        {notice && <p className="st-note" role="status">{notice}</p>}
        {error && <p className="st-error" role="alert">{error}</p>}
      </section>

      <div className="collab-grid">
        <section className="st-group" aria-label="Spaces">
          <div className="st-head">
            <h3 className="st-title">Spaces</h3>
          </div>
          <div className="st-rows">
            {spaces.length === 0 ? (
              <p className="st-note">No Spaces available.</p>
            ) : (
              spaces.map((space) => (
                <div className="st-row" key={space.id}>
                  <button type="button" className="st-label ag-link" onClick={() => onOpenSpace(space.id)}>
                    {space.name}
                  </button>
                  <span className="st-value">{space.status}</span>
                </div>
              ))
            )}
          </div>
        </section>

        <section className="st-group" aria-label="Runs timeline">
          <div className="st-head">
            <h3 className="st-title">Runs / timeline</h3>
          </div>
          <div className="st-rows">
            {runs.length === 0 ? (
              <p className="st-note">No agent runs found.</p>
            ) : (
              runs.slice(0, 20).map(({ space, run }) => (
                <div className="st-row collab-run" key={`${space.id}:${run.runId}`}>
                  <span className="status-dot-wrap">
                    <span
                      className={`status-dot ${STATUS_DOT[run.status]}`}
                      role="img"
                      aria-label={STATUS_LABEL[run.status]}
                    />
                  </span>
                  <span className="st-label" title={run.summary}>
                    {agentLabel(run.agent)} · {space.name}
                  </span>
                  <span className="st-value">{run.summary || run.reason}</span>
                </div>
              ))
            )}
          </div>
        </section>
      </div>
    </div>
  );
}
