// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import { describe, expect, it, vi } from 'vitest';

import { createAgentsBridgeOver } from './persistent';

describe('persistent agent chat bridge', () => {
  it('resumes an existing persistent run with agent_message', async () => {
    const call = vi.fn(async (tool: string, args: Record<string, unknown> = {}) => {
      if (tool === 'persistent_agent_list') {
        return { agents: [{ name: 'Oleg', harness: 'hermes', space: 'local:ops', paused: false, run_id: 'run-1' }] };
      }
      if (tool === 'agent_message') {
        expect(args).toEqual({ space: 'local:ops', run_id: 'run-1', text: 'Check leads' });
        return { run_id: 'run-1', status: 'running' };
      }
      throw new Error(`unexpected tool ${tool}`);
    });

    const bridge = createAgentsBridgeOver(call);
    await expect(bridge.chat('oleg', 'Check leads')).resolves.toEqual({
      name: 'Oleg',
      runId: 'run-1',
      space: 'local:ops',
      status: 'running',
    });
    expect(call).not.toHaveBeenCalledWith('agent_start', expect.anything());
  });

  it('starts the configured persistent agent when it has no active run', async () => {
    const call = vi.fn(async (tool: string, args: Record<string, unknown> = {}) => {
      if (tool === 'persistent_agent_list') {
        return { agents: [{ name: 'Nina', harness: 'openai-codex', space: 'local:nina', paused: false, run_id: null }] };
      }
      if (tool === 'agent_start') {
        expect(args).toEqual({
          space: 'local:nina',
          agent: 'openai-codex',
          prompt: 'Continue operations',
          home: 'Nina',
          show: false,
        });
        return { run_id: 'run-2', space: 'local:nina' };
      }
      throw new Error(`unexpected tool ${tool}`);
    });

    const bridge = createAgentsBridgeOver(call);
    await expect(bridge.chat('Nina', 'Continue operations')).resolves.toEqual({
      name: 'Nina',
      runId: 'run-2',
      space: 'local:nina',
      status: 'running',
    });
  });
});
