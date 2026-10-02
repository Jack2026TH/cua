// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import { useEffect, useMemo, useRef, useState, type FormEvent } from 'react';

import type { PersistentAgentInput } from '../../model/persistent';
import type { AgentChatStatus, AgentsBridge } from '../../native/persistent';

type WorkspaceMessage = {
  id: number;
  role: 'you' | 'agent' | 'system';
  author: string;
  text: string;
  target?: string;
  runId?: string;
  space?: string;
};

type RunRow = {
  runId: string;
  agent: string;
  space: string;
  status: string;
  phase: string;
};

const TERMINAL = new Set(['idle', 'failed', 'crashed']);
const DEFAULT_POLL_MS = 1_200;
const DEFAULT_MAX_POLLS = 40;

function resultText(status: AgentChatStatus): string {
  if (status.text.trim()) return status.text.trim();
  if (status.summary.trim()) return status.summary.trim();
  if (status.reason.trim()) return status.reason.trim();
  return status.status === 'idle' ? 'Done.' : `Run ${status.status}.`;
}

function targetFromDraft(
  draft: string,
  agents: PersistentAgentInput[],
  selected: string | null,
): { agent: PersistentAgentInput | null; text: string } {
  const trimmed = draft.trim();
  const named = [...agents]
    .sort((a, b) => b.name.length - a.name.length)
    .find((agent) => trimmed.toLocaleLowerCase().startsWith(`@${agent.name.toLocaleLowerCase()}`));
  if (named) {
    return { agent: named, text: trimmed.slice(named.name.length + 1).trim() };
  }
  return {
    agent: agents.find((agent) => agent.name === selected) ?? null,
    text: trimmed,
  };
}

/**
 * Sila-like collaboration shell over the existing persistent-agent transport.
 *
 * No new backend is introduced: @mentions resume a persistent run with
 * agent_message, or agent_start when that agent has no run yet. Runs stay in
 * their existing Space and this page only reads status while they work.
 */
export function WorkspacePage({
  bridge,
  onOpenSpace,
  pollMs = DEFAULT_POLL_MS,
  maxPolls = DEFAULT_MAX_POLLS,
}: {
  bridge: AgentsBridge;
  onOpenSpace?: (spaceId: string) => void;
  pollMs?: number;
  maxPolls?: number;
}) {
  const [agents, setAgents] = useState<PersistentAgentInput[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [messages, setMessages] = useState<WorkspaceMessage[]>([]);
  const [runs, setRuns] = useState<RunRow[]>([]);
  const [draft, setDraft] = useState('');
  const [loading, setLoading] = useState(true);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const nextId = useRef(1);
  const alive = useRef(true);

  const refreshAgents = async () => {
    const rows = await bridge.agents();
    if (!alive.current) return;
    setAgents(rows);
    setSelected((current) => current ?? rows[0]?.name ?? null);
  };

  useEffect(() => {
    alive.current = true;
    setLoading(true);
    void refreshAgents()
      .catch((e: unknown) => {
        if (alive.current) setError(e instanceof Error ? e.message : String(e));
      })
      .finally(() => {
        if (alive.current) setLoading(false);
      });
    return () => {
      alive.current = false;
    };
  }, [bridge]);

  const selectedAgent = useMemo(
    () => agents.find((agent) => agent.name === selected) ?? null,
    [agents, selected],
  );

  const append = (message: Omit<WorkspaceMessage, 'id'>) => {
    const id = nextId.current++;
    setMessages((current) => [...current, { ...message, id }]);
    return id;
  };

  const updateRun = (next: RunRow) => {
    setRuns((current) => {
      const index = current.findIndex((row) => row.runId === next.runId);
      if (index < 0) return [next, ...current];
      const copy = [...current];
      copy[index] = next;
      return copy;
    });
  };

  const pollRun = async (agent: string, space: string, runId: string) => {
    let last: AgentChatStatus | null = null;
    for (let attempt = 0; attempt < maxPolls && alive.current; attempt += 1) {
      const status = await bridge.agentStatus(space, runId);
      last = status;
      if (!alive.current) return;
      updateRun({
        runId,
        agent,
        space,
        status: status.status,
        phase: status.phase,
      });
      if (TERMINAL.has(status.status)) {
        append({
          role: status.status === 'idle' ? 'agent' : 'system',
          author: status.status === 'idle' ? agent : 'System',
          text: resultText(status),
          runId,
          space,
        });
        await refreshAgents().catch(() => {});
        return;
      }
      await new Promise((resolve) => window.setTimeout(resolve, pollMs));
    }
    if (alive.current && last) {
      append({
        role: 'system',
        author: 'System',
        text: `${agent} is still ${last.status}${last.phase ? ` · ${last.phase}` : ''}.`,
        runId,
        space,
      });
    }
  };

  const send = async (agent: PersistentAgentInput, text: string, label = 'You') => {
    const body = text.trim();
    if (!body || sending) return;
    setSending(true);
    setError(null);
    append({ role: 'you', author: label, target: agent.name, text: body });
    try {
      const receipt = await bridge.chat(agent.name, body);
      updateRun({
        runId: receipt.runId,
        agent: agent.name,
        space: receipt.space,
        status: receipt.status,
        phase: '',
      });
      setDraft('');
      void pollRun(agent.name, receipt.space, receipt.runId).catch((e: unknown) => {
        if (!alive.current) return;
        setError(e instanceof Error ? e.message : String(e));
      });
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      if (alive.current) setSending(false);
    }
  };

  const submit = (event: FormEvent) => {
    event.preventDefault();
    const target = targetFromDraft(draft, agents, selected);
    if (!target.agent) {
      setError('Choose an agent or start the message with @name.');
      return;
    }
    if (!target.text) {
      setError('Message is empty.');
      return;
    }
    void send(target.agent, target.text);
  };

  const handoff = (target: PersistentAgentInput) => {
    const source =
      [...messages].reverse().find((message) => message.role === 'agent')?.author ??
      selectedAgent?.name ??
      'Workspace';
    const context = messages
      .slice(-8)
      .map((message) => `${message.author}${message.target ? ` → ${message.target}` : ''}: ${message.text}`)
      .join('\n');
    const prompt = [
      `Handoff from ${source}.`,
      'Continue the task from the shared workspace context below. Preserve completed work and do not repeat finished steps.',
      '',
      context || 'No prior thread messages.',
    ].join('\n');
    void send(target, prompt, `Handoff · ${source}`);
  };

  return (
    <div className="cw-page">
      <section className="cw-thread" aria-label="Workspace conversation">
        <header className="cw-head">
          <div>
            <h1>Workspace</h1>
            <p>People, agents and computer runs in one thread.</p>
          </div>
          {selectedAgent && (
            <button
              type="button"
              className="dw-btn"
              onClick={() => onOpenSpace?.(selectedAgent.space)}
              disabled={!onOpenSpace}
            >
              Open {selectedAgent.space}
            </button>
          )}
        </header>

        <div className="cw-messages" aria-live="polite">
          {messages.length === 0 ? (
            <div className="cw-empty">
              <h2>Start with an @mention</h2>
              <p>Select an agent or type @name, then send a task. Existing persistent runs are resumed.</p>
            </div>
          ) : (
            messages.map((message) => (
              <article key={message.id} className="cw-message" data-role={message.role}>
                <div className="cw-message-meta">
                  <strong>{message.author}</strong>
                  {message.target && <span>→ {message.target}</span>}
                  {message.runId && <code>{message.runId}</code>}
                </div>
                <div className="cw-message-body">{message.text}</div>
              </article>
            ))
          )}
        </div>

        {error && (
          <div className="cw-error" role="alert">
            {error}
          </div>
        )}

        <form className="cw-composer" onSubmit={submit}>
          <textarea
            className="dw-input cw-input"
            aria-label="Message"
            placeholder={selected ? `Message @${selected}…` : 'Message @agent…'}
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            rows={3}
          />
          <div className="cw-composer-foot">
            <span>{selected ? `Routing to ${selected} unless @name overrides it` : 'Choose a participant'}</span>
            <button type="submit" className="dw-btn dw-btn-primary" disabled={sending || loading || agents.length === 0}>
              {sending ? 'Sending…' : 'Send'}
            </button>
          </div>
        </form>
      </section>

      <aside className="cw-side" aria-label="Workspace context">
        <section className="cw-side-section">
          <h2>Participants</h2>
          {loading ? (
            <p className="st-note">Loading agents…</p>
          ) : agents.length === 0 ? (
            <p className="st-note">No persistent agents configured.</p>
          ) : (
            <div className="cw-participants">
              {agents.map((agent) => (
                <div key={agent.name} className="cw-participant" data-selected={selected === agent.name || undefined}>
                  <button type="button" className="cw-participant-main" onClick={() => setSelected(agent.name)}>
                    <strong>@{agent.name}</strong>
                    <span>{agent.harness}</span>
                    <span>{agent.space}</span>
                  </button>
                  <button
                    type="button"
                    className="dw-btn cw-handoff"
                    disabled={messages.length === 0 || sending}
                    onClick={() => handoff(agent)}
                  >
                    Handoff
                  </button>
                </div>
              ))}
            </div>
          )}
        </section>

        <section className="cw-side-section">
          <h2>Runs</h2>
          {runs.length === 0 ? (
            <p className="st-note">No runs in this workspace yet.</p>
          ) : (
            <div className="cw-runs">
              {runs.map((run) => (
                <button
                  key={run.runId}
                  type="button"
                  className="cw-run"
                  onClick={() => onOpenSpace?.(run.space)}
                  disabled={!onOpenSpace}
                >
                  <span>
                    <strong>{run.agent}</strong>
                    <code>{run.runId}</code>
                  </span>
                  <span>{run.status}{run.phase ? ` · ${run.phase}` : ''}</span>
                  <span>{run.space}</span>
                </button>
              ))}
            </div>
          )}
        </section>
      </aside>
    </div>
  );
}
