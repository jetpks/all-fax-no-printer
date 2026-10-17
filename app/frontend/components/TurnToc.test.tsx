import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { Message as MessageType, Turn as TurnType } from '@/types'
import TurnToc from '@/components/TurnToc'

function makeMessage(
  id: number,
  blocks: MessageType['blocks'],
  role = 'assistant',
): MessageType {
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

function makeTurn(anchorId: number, prompt: MessageType | null, rounds: TurnType['rounds'] = []): TurnType {
  return { anchor_id: anchorId, prompt, rounds }
}

// A commit-marker message — Bash running `git commit`.
const commitMessage = makeMessage(31, [
  { type: 'tool_use', id: 'tu-1', name: 'Bash', input: { command: 'git commit -m "ship the widget"' } },
])

const ON_JUMP = vi.fn()

function renderToc(turns: TurnType[], active = new Set<number>()) {
  return render(
    <TurnToc turns={turns} active={active} projectRoot={null} onJump={ON_JUMP} />,
  )
}

describe('TurnToc', () => {
  it('renders one entry per turn with the prompt gist and a 1-based number', () => {
    const turns = [
      makeTurn(1, makeMessage(10, [{ type: 'text', text: 'first prompt gist here' }], 'user')),
      makeTurn(2, makeMessage(20, [{ type: 'text', text: 'second prompt gist here' }], 'user')),
    ]
    renderToc(turns)

    expect(screen.getByText('first prompt gist here')).not.toBeNull()
    expect(screen.getByText('second prompt gist here')).not.toBeNull()
    expect(screen.getByText('1')).not.toBeNull()
    expect(screen.getByText('2')).not.toBeNull()
  })

  it('labels a prompt-less turn "preamble"', () => {
    renderToc([makeTurn(1, null)])

    expect(screen.getByText('preamble')).not.toBeNull()
  })

  it('lists marker sub-entries and jumps with target + reveal ids', () => {
    const turn = makeTurn(7, null, [{ anchor_id: 30, messages: [commitMessage] }])
    renderToc([turn])

    const entry = screen.getByText(/commit: ship the widget/)
    fireEvent.click(entry)
    expect(ON_JUMP).toHaveBeenCalledWith(7, 'commit-31', 31)
  })

  it('highlights the active turn entry', () => {
    renderToc([makeTurn(1, makeMessage(10, [{ type: 'text', text: 'gist' }], 'user'))], new Set([1]))

    const button = screen.getByRole('button', { name: /gist/ })
    expect(button.className).toContain('text-foreground')
  })

  it('carries no per-turn hue: no entry sets an inline color style', () => {
    const { container } = renderToc(
      [makeTurn(1, makeMessage(10, [{ type: 'text', text: 'gist' }], 'user'))],
      new Set([1]),
    )

    for (const el of container.querySelectorAll('[style]')) {
      expect(el.getAttribute('style')).not.toContain('hsl')
    }
  })
})
