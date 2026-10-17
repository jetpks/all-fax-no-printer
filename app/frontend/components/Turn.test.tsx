import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import type { Message as MessageType, ToolResultIndex } from '@/types'
import { buildToolResultIndex } from '@/lib/message-pairing'
import Turn from '@/components/Turn'

const OWNER = { username: 'eric', name: 'Eric', avatar_url: null }

function makeMessage(id: number, blocks: MessageType['blocks'], role = 'assistant'): MessageType {
  return {
    id,
    role,
    model: null,
    position: id,
    published: false,
    can_publish: false,
    blocks,
  }
}

function makeTurn(
  reply: MessageType[],
  prompt: MessageType | null = null,
  toolResults: ToolResultIndex = { byUseId: {}, useIds: new Set() },
): {
  anchorId: number
  prompt: MessageType | null
  absorbedIds: Set<number>
  reply: MessageType[]
  conversationId: number
  toolResults: ToolResultIndex
  commandStdout: Record<number, string>
  folded: Record<number, MessageType[]>
  reveal: number | null
  projectRoot: string | null
  owner: typeof OWNER
} {
  return {
    anchorId: 1,
    prompt,
    absorbedIds: new Set<number>(),
    reply,
    conversationId: 42,
    toolResults,
    commandStdout: {},
    folded: {},
    reveal: null,
    projectRoot: null,
    owner: OWNER,
  }
}

const prompt = makeMessage(10, [{ type: 'text', text: 'fix the frobnicator' }], 'user')

// A tool call and its paired result — the pair the flat body folds into one row.
const toolMessage = makeMessage(11, [
  { type: 'tool_use', id: 'tu-1', name: 'Bash', input: { command: 'echo hi' } },
])
const resultMessage = makeMessage(
  12,
  [{ type: 'tool_result', tool_use_id: 'tu-1', content: 'hi out' }],
  'user',
)
const paired = buildToolResultIndex([toolMessage, resultMessage]) as ToolResultIndex

describe('Turn — flat pairs', () => {
  it('renders the prompt with the owner chip', () => {
    render(<Turn {...makeTurn([], prompt)} />)
    expect(screen.getByText('fix the frobnicator')).not.toBeNull()
    expect(screen.getByText('Eric')).not.toBeNull()
    expect(document.querySelector('#prompt-10')).not.toBeNull()
  })

  it('renders a prompt-less turn as a preamble line', () => {
    render(<Turn {...makeTurn([])} />)
    expect(screen.getByText(/Opening context before the first prompt\./)).not.toBeNull()
  })

  it('renders one container with the turn anchor id', () => {
    render(<Turn {...makeTurn([toolMessage, resultMessage], prompt)} toolResults={paired} />)
    const li = document.querySelector('li#turn-1')
    expect(li).not.toBeNull()
    expect(li!.getAttribute('data-turn-id')).toBe('1')
    expect(li!.className).toContain('scroll-mt-20')
  })

  it('an action message renders as ONE collapsed row with the toolLabel one-liner', () => {
    render(<Turn {...makeTurn([toolMessage, resultMessage], prompt)} toolResults={paired} />)

    // Collapsed: the one-liner is visible, the call body and its result are not.
    expect(screen.getByText('→ Bash')).not.toBeNull()
    expect(screen.queryByText('hi out')).toBeNull()
    // Exactly one toggle row for the tool call.
    expect(screen.getAllByRole('button', { name: 'Expand action' })).toHaveLength(1)
  })

  it('expanding the row renders the tool call with its result inline', () => {
    render(<Turn {...makeTurn([toolMessage, resultMessage], prompt)} toolResults={paired} />)

    fireEvent.click(screen.getByRole('button', { name: 'Expand action' }))
    expect(screen.getByText('hi out')).not.toBeNull()
    // The row carries the tool anchor id and it was NOT duplicated.
    expect(document.querySelectorAll('#tool-11')).toHaveLength(1)
  })

  it('an absorbed result-only message is absent', () => {
    render(<Turn {...makeTurn([resultMessage])} toolResults={paired} />)

    expect(screen.queryByText('hi out')).toBeNull()
  })

  it('a published message stays visible even when result-only', () => {
    const published = { ...resultMessage, published: true }
    render(<Turn {...makeTurn([published])} toolResults={paired} />)

    // The message element stays in the tree (its result text is suppressed by
    // Block as an inline duplicate of the paired call's body).
    expect(document.querySelector('#message-12')).not.toBeNull()
  })

  it('encrypted thinking is absent', () => {
    render(<Turn {...makeTurn([makeMessage(13, [{ type: 'redacted_thinking', data: 'x' }])])} />)

    expect(screen.queryByText(/thinking/)).toBeNull()
  })

  it('the /compact summary renders behind a disclosure', () => {
    const summary = makeMessage(
      14,
      [
        {
          type: 'text',
          text: 'This session is being continued from a previous conversation that ran out of context. Earlier we fixed the frobnicator.',
        },
      ],
      'user',
    )
    render(<Turn {...makeTurn([summary])} />)

    // Collapsed: the disclosure row, not the summary prose.
    expect(screen.queryByText(/Earlier we fixed/)).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Expand summary' }))
    expect(screen.getByText(/Earlier we fixed/)).not.toBeNull()
  })

  it('thinking renders behind a collapsed affordance that expands', () => {
    render(
      <Turn {...makeTurn([makeMessage(15, [{ type: 'thinking', thinking: 'pondering deeply' }])])} />,
    )

    expect(screen.queryByText('pondering deeply')).toBeNull()
    fireEvent.click(screen.getByText('thinking'))
    expect(screen.getByText('pondering deeply')).not.toBeNull()
  })

  it('a marker jump (reveal) expands the target action row', () => {
    const decision = makeMessage(16, [
      {
        type: 'tool_use',
        id: 'tu-2',
        name: 'ExitPlanMode',
        input: { plan: [{ step: 'ship it', status: 'pending' }] },
      },
    ])
    render(<Turn {...makeTurn([decision])} toolResults={paired} reveal={16} />)

    // Revealed by the jump: expanded without a click.
    expect(screen.getByText(/ship it/)).not.toBeNull()
    // The marker id anchors the row.
    expect(document.querySelector('#decision-16')).not.toBeNull()
  })

  it('an interrupt marker renders as an ordinary narrative message', () => {
    render(<Turn {...makeTurn([makeMessage(17, [{ type: 'text', text: '<turn_aborted>' }])])} />)

    expect(screen.getByText('[interrupted by user]')).not.toBeNull()
  })
})
