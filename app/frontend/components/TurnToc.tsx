import { gist, markerLabel, MARKER_STYLE, turnMarkers } from '@/lib/tools'
import { turnMessages } from '@/lib/anchors'
import type { Turn as TurnType } from '@/types'

// A jump-nav for the transcript: one lean entry per turn (its 1-based number +
// the prompt gist, or "preamble"), with decision/memory/commit markers listed
// as sub-entries beneath their turn. Decisions are jump targets, not turn
// boundaries — see memory chat-share-decisions-not-boundaries. onJump opens the
// target turn (state lives in Show) and scrolls to the turn, or to the marker's
// action row within it. No per-turn hue and no own scroll container: the
// highlight is a subtle neutral wash, and the page's scroll reconcile drives it.
export default function TurnToc({
  turns,
  active,
  projectRoot,
  onJump,
}: {
  turns: TurnType[]
  active: Set<number>
  projectRoot: string | null
  // Jump to a turn, or to a marked beat within it (target = `${marker}-${id}`);
  // revealId names the marker's message so its turn can expand the row.
  onJump: (anchorId: number, target?: string, revealId?: number) => void
}) {
  return (
    <nav aria-label="Turns">
      <ol className="space-y-1.5">
        {turns.map((turn, i) => {
          const prompt = turn.prompt
          const markers = turnMarkers(turnMessages(turn), projectRoot)
          const isActive = active.has(turn.anchor_id)
          return (
            <li key={turn.anchor_id}>
              <button
                onClick={() => onJump(turn.anchor_id)}
                className={`block w-full truncate rounded px-1.5 py-1 text-left text-sm ${
                  isActive
                    ? 'bg-muted/60 text-foreground'
                    : 'text-muted-foreground hover:text-foreground'
                }`}
              >
                {/* The 1-based turn number, matching the stream below so the
                    sidebar ties to what's on screen. */}
                <span className="mr-1.5 tabular-nums text-xs text-muted-foreground/60">
                  {i + 1}
                </span>
                {prompt ? gist(prompt, 60) : <span className="italic">preamble</span>}
              </button>
              {markers.length > 0 && (
                <ul className="ml-2 mt-0.5 space-y-0.5 border-l border-border/40 pl-2">
                  {markers.map(({ message, marker }) => {
                    const style = MARKER_STYLE[marker]
                    return (
                      <li key={message.id}>
                        <button
                          onClick={() =>
                            onJump(turn.anchor_id, `${marker}-${message.id}`, message.id)
                          }
                          className={`block w-full truncate text-left text-xs ${style.subtle} ${style.textHover}`}
                        >
                          {style.glyph} {markerLabel(message, marker, projectRoot)}
                        </button>
                      </li>
                    )
                  })}
                </ul>
              )}
            </li>
          )
        })}
      </ol>
    </nav>
  )
}
