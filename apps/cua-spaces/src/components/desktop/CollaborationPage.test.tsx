// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import '@testing-library/jest-dom/vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

afterEach(cleanup);

import type { Space } from '../../model/types';
import { CollaborationPage } from './CollaborationPage';

const SPACE: Space = {
  id: 'local:ops',
  name: 'Ops',
  os: 'linux',
  status: 'running',
  detail: 'Operations',
  lastUsedAt: 1,
  scene: 'linux-terminal',
};

function setup() {
  const sendMessage = vi.fn(async () => {});
  const agentsBridge = {
    agents: async () => [
      {
        name: 'oleg',
        harness: 'hermes',
        space: SPACE.id,
        paused: false,
        runId: 'run-1',
        spaceState: 'running',
      },
    ],
    sendMessage,
  };
  const teleport = {
    listSpaceAgents: async () => [
      {
        runId: 'run-1',
        agent: 'hermes',
        status: 'idle' as const,
        reason: 'waiting for a follow-up',
        summary: 'Review operations',
        createdAt: 100,
      },
    ],
  };
  const onOpenSpace = vi.fn();

  render(
    <CollaborationPage
      spaces={[SPACE]}
      agentsBridge={agentsBridge}
      teleport={teleport}
      onOpenSpace={onOpenSpace}
    />,
  );

  return { sendMessage, onOpenSpace };
}

describe('CollaborationPage', () => {
  it('shows persistent agents, Spaces and real run activity', async () => {
    setup();
    expect(await screen.findByRole('button', { name: '@oleg' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Ops' })).toBeInTheDocument();
    expect(await screen.findByText(/Hermes · Ops/)).toBeInTheDocument();
    expect(screen.getByText('Review operations')).toBeInTheDocument();
  });

  it('sends @agent messages through the canonical persistent-agent bridge', async () => {
    const { sendMessage } = setup();
    const input = await screen.findByRole('textbox', { name: 'Message an agent' });
    fireEvent.change(input, { target: { value: '@oleg Check the payment run' } });
    fireEvent.click(screen.getByRole('button', { name: 'Send' }));

    await waitFor(() => expect(sendMessage).toHaveBeenCalledWith('oleg', 'Check the payment run'));
    expect(await screen.findByText('Sent to @oleg.')).toBeInTheDocument();
  });
});
