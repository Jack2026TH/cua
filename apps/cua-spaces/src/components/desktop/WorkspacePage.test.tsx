// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import type { AgentsBridge } from '../../native/persistent';
import { WorkspacePage } from './WorkspacePage';

function bridge(): AgentsBridge {
  return {
    agents: vi.fn(async () => [
      {
        name: 'Oleg',
        harness: 'hermes',
        space: 'local:rent-ops',
        paused: false,
        runId: 'run-oleg-1',
      },
    ]),
    chat: vi.fn(async () => ({
      name: 'Oleg',
      runId: 'run-oleg-1',
      space: 'local:rent-ops',
      status: 'running',
    })),
    agentStatus: vi.fn(async () => ({
      runId: 'run-oleg-1',
      space: 'local:rent-ops',
      status: 'idle',
      phase: 'done',
      reason: '',
      acceptsMessage: true,
      text: 'Bookings checked.',
      summary: '',
    })),
    home: vi.fn(async () => []),
    routines: vi.fn(async () => []),
    access: vi.fn(async () => ({ grants: [], audit: [] })),
    readFile: vi.fn(async () => ({ path: '', text: '', versions: [] })),
    run: vi.fn(async () => undefined),
    drive: vi.fn(async () => ({ requests: [], grants: [] })),
    runDrive: vi.fn(async () => undefined),
    userHome: vi.fn(async () => null),
    mountStatus: vi.fn(async () => null),
    syncStatus: vi.fn(async () => null),
    notifications: vi.fn(async () => []),
    markAllRead: vi.fn(async () => undefined),
  };
}

describe('WorkspacePage', () => {
  it('routes an @mention to the existing persistent agent run and renders its reply', async () => {
    const api = bridge();
    render(<WorkspacePage bridge={api} pollMs={0} maxPolls={2} />);

    const input = await screen.findByRole('textbox', { name: 'Message' });
    fireEvent.change(input, { target: { value: '@Oleg check bookings' } });
    fireEvent.click(screen.getByRole('button', { name: 'Send' }));

    await waitFor(() => expect(api.chat).toHaveBeenCalledWith('Oleg', 'check bookings'));
    expect(await screen.findByText('Bookings checked.')).toBeTruthy();
    expect(api.agentStatus).toHaveBeenCalledWith('local:rent-ops', 'run-oleg-1');
  });

  it('hands the recent thread to another persistent agent', async () => {
    const api = bridge();
    vi.mocked(api.agents).mockResolvedValue([
      {
        name: 'Oleg',
        harness: 'hermes',
        space: 'local:rent-ops',
        paused: false,
        runId: 'run-oleg-1',
      },
      {
        name: 'Nina',
        harness: 'openai-codex',
        space: 'local:ops',
        paused: false,
        runId: 'run-nina-1',
      },
    ]);
    vi.mocked(api.chat)
      .mockResolvedValueOnce({
        name: 'Oleg',
        runId: 'run-oleg-1',
        space: 'local:rent-ops',
        status: 'running',
      })
      .mockResolvedValueOnce({
        name: 'Nina',
        runId: 'run-nina-1',
        space: 'local:ops',
        status: 'running',
      });
    vi.mocked(api.agentStatus)
      .mockResolvedValueOnce({
        runId: 'run-oleg-1',
        space: 'local:rent-ops',
        status: 'idle',
        phase: 'done',
        reason: '',
        acceptsMessage: true,
        text: 'Guest issue identified.',
        summary: '',
      })
      .mockResolvedValueOnce({
        runId: 'run-nina-1',
        space: 'local:ops',
        status: 'idle',
        phase: 'done',
        reason: '',
        acceptsMessage: true,
        text: 'Accepted.',
        summary: '',
      });

    render(<WorkspacePage bridge={api} pollMs={0} maxPolls={2} />);
    const input = await screen.findByRole('textbox', { name: 'Message' });
    fireEvent.change(input, { target: { value: '@Oleg inspect guest issue' } });
    fireEvent.click(screen.getByRole('button', { name: 'Send' }));
    expect(await screen.findByText('Guest issue identified.')).toBeTruthy();

    const handoffButtons = screen.getAllByRole('button', { name: 'Handoff' });
    const ninaHandoff = handoffButtons[1];
    expect(ninaHandoff).toBeTruthy();
    if (!ninaHandoff) throw new Error('Nina handoff button was not rendered');
    fireEvent.click(ninaHandoff);

    await waitFor(() => expect(api.chat).toHaveBeenCalledTimes(2));
    const handoff = vi.mocked(api.chat).mock.calls[1];
    expect(handoff).toBeTruthy();
    if (!handoff) throw new Error('Handoff call was not recorded');
    expect(handoff[0]).toBe('Nina');
    expect(handoff[1]).toContain('Handoff from Oleg.');
    expect(handoff[1]).toContain('Guest issue identified.');
  });
});
