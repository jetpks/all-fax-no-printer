import { memo, useEffect, useState } from 'react'
import { ChevronDown, ChevronRight } from 'lucide-react'
import Message from '@/components/Message'
import UserChip from '@/components/UserChip'
import { hasOwnReason, isAbsorbed } from '@/lib/message-pairing'
import {
  gist,
  isActionMessage,
  isCompactSummary,
  isEncryptedThinking,
  MARKER_STYLE,
  markerLabel,
  messageMarker,
  toolLabel,
} from '@/lib/tools'
import type { Marker } from '@/lib/tools'
import type {
  Message as MessageType,
  ToolResultIndex,
  ToolUseBlock,
} from '@/types'

// The annotation anchors of the old notes tier are gone — the pairing/fold
// rules see an always-empty set (the same one the frozen Spaces pages pass).
const NO_ANNOTATED_IDS = new Set<number>()

// The toggle row shape shared by action rows and the /compact summary: a
// borderless, full-width button — chevron + label — that runs flush to the turn
// and only lights a subtle hover wash.
const ROW_CLASS =
  'flex w-full items-center gap-2 rounded px-1 py-1 text-left text-sm transition-colors hover:bg-foreground/5'

// A turn is the pair boundary the server drew: the user's prompt, then the
// reply's beats in stream order — prose as markdown, each tool call as ONE
// collapsed row you expand in place, thinking collapsed by Block, tool results
// shown under the calls that spawned them. Folding is presentation only: every
// folded thing stays reachable behind its expand affordance. There is no round
// layer and no terminal peel — the turn's last content message is just the last
// message in the stream.
// Memoized: Show re-renders on every activeTurns tick while scrolling, but a
// turn's props are all stable across those (Show memoizes the derived data), so
// a turn only re-renders when its own disclosure state or content actually
// changes — keeping fast scroll from redrawing the transcript.
function Turn({
  anchorId,
  prompt,
  absorbedIds,
  reply,
  conversationId,
  toolResults,
  commandStdout,
  folded,
  reveal,
  projectRoot,
  owner,
}: {
  anchorId: number
  // The turn's user message — full markdown, the pair's left side.
  prompt: MessageType | null
  // The message ids whose content is already shown inline elsewhere (a slash
  // command's stdout half, paired in Show across the whole conversation).
  absorbedIds: Set<number>
  // The turn's non-prompt members in stream order (turnMessages(turn) minus the
  // prompt), passed precomputed by Show; visibility is decided here.
  reply: MessageType[]
  conversationId: number
  toolResults: ToolResultIndex
  commandStdout: Record<number, string>
  folded: Record<number, MessageType[]>
  // A message in this turn that a TOC jump or deep link asked us to reveal
  // (else null) — we expand the action row holding it so the buried beat
  // actually shows. Scoped to the owning turn in Show so a jump doesn't churn
  // every turn's memo.
  reveal: number | null
  // The conversation's project root, used to detect memory writes (a /memory/
  // file outside the repo) — highlighted orange like decisions are emerald.
  projectRoot: string | null
  // Who wrote the prompts — stamped on each turn's user message. (One identity
  // per conversation today; per-message authorship would replace this.)
  owner: { username: string; name: string | null; avatar_url: string | null }
}) {
  // Which action rows are expanded (a collapsed tool call is one line; the full
  // call + its paired result open in place).
  const [expandedIds, setExpandedIds] = useState<Set<number>>(new Set())
  // The /compact summary's disclosure is state of its own.
  const [summaryOpen, setSummaryOpen] = useState(false)

  // Visibility — the same filter the page has always applied, applied here as
  // part of the turn's render-time peel (like the summary peel below): a
  // message survives when it has its own reason to stay (a published snippet);
  // else it drops when its content is already shown inline elsewhere (a paired
  // tool result, absorbed command stdout) or is just the model's encrypted
  // chain-of-thought (opaque ciphertext, nothing to read).
  const visible = reply.filter((m) => {
    if (hasOwnReason(m, NO_ANNOTATED_IDS)) return true
    if (absorbedIds.has(m.id)) return false
    if (isEncryptedThinking(m)) return false
    return !isAbsorbed(m, toolResults, NO_ANNOTATED_IDS)
  })

  // A /compact turn carries the continuation summary Claude Code injected before
  // the command — machinery, not work. It renders in its stream slot as a
  // collapsed disclosure of its own instead of a giant fake prompt. See
  // lib/tools isCompactSummary.
  const summary = visible.find((m) => isCompactSummary(m)) ?? null

  // A TOC jump or deep link into a collapsed action row asks us to reveal its
  // target: expand the row holding it so the buried beat actually shows. Keyed
  // only on reveal so a manual collapse isn't undone on the next unrelated
  // render; Show clears the id once the scroll lands, so re-clicking the same
  // marker reveals it again.
  useEffect(() => {
    if (reveal == null || !visible.some((m) => m.id === reveal && isActionMessage(m))) return
    setExpandedIds((prev) => (prev.has(reveal) ? prev : new Set(prev).add(reveal)))
    // `visible` is derived from stable props; intentionally keyed only on reveal.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [reveal])

  const toggleRow = (id: number) =>
    setExpandedIds((prev) => {
      const next = new Set(prev)
      next.has(id) ? next.delete(id) : next.add(id)
      return next
    })

  // The shared Message renderer, menu-less and bare — the flat body is prose
  // and rows, not chrome; the marker (when the message is a decision/memory/
  // commit) tints the tool header glyph.
  const renderBody = (message: MessageType, marker?: Marker) => (
    <Message
      message={message}
      conversationId={conversationId}
      toolResults={toolResults}
      commandStdout={commandStdout[message.id]}
      folded={folded[message.id]}
      bare
      hideMenu
      label=""
      marker={marker}
    />
  )

  // A tool call (an action message) at rest: ONE truncated line — chevron +
  // the marker's glyph and label when marked, else the tool descriptor —
  // keeping the tool's anchor id (`tool-<id>` / `<marker>-<id>`) so deep links
  // and TOC jumps land. Expanding renders the full call body in place, with
  // its paired tool_result inline (buildToolResultIndex semantics).
  const renderActionRow = (message: MessageType) => {
    const marker = messageMarker(message, projectRoot)
    const style = marker ? MARKER_STYLE[marker] : null
    const tool = message.blocks.find((b) => b.type === 'tool_use') as ToolUseBlock | undefined
    const open = expandedIds.has(message.id)

    return (
      <div
        key={message.id}
        id={marker ? `${marker}-${message.id}` : `tool-${message.id}`}
        className="scroll-mt-20"
      >
        <button
          onClick={() => toggleRow(message.id)}
          aria-label={open ? 'Collapse action' : 'Expand action'}
          className={ROW_CLASS}
        >
          {open ? (
            <ChevronDown className="size-3.5 shrink-0 opacity-70" />
          ) : (
            <ChevronRight className="size-3.5 shrink-0 opacity-70" />
          )}
          {style && <span className={`shrink-0 ${style.text}`}>{style.glyph}</span>}
          <span
            className={`min-w-0 flex-1 truncate ${style ? style.text : 'text-muted-foreground'}`}
          >
            {tool ? (marker ? markerLabel(message, marker, projectRoot) : toolLabel(tool)) : gist(message)}
          </span>
        </button>
        {open && <div className="pb-1 pl-3">{renderBody(message, marker ?? undefined)}</div>}
      </div>
    )
  }

  // The injected continuation summary behind its own collapsed disclosure, in
  // its stream slot.
  const renderSummary = () => (
    <div key={summary!.id}>
      <button
        onClick={() => setSummaryOpen((v) => !v)}
        aria-label={summaryOpen ? 'Collapse summary' : 'Expand summary'}
        className={`${ROW_CLASS} text-muted-foreground hover:text-foreground`}
      >
        {summaryOpen ? (
          <ChevronDown className="size-3.5 shrink-0 opacity-70" />
        ) : (
          <ChevronRight className="size-3.5 shrink-0 opacity-70" />
        )}
        <span className="min-w-0 flex-1 truncate">
          continuation summary <span className="text-muted-foreground/70">(compacted)</span>
        </span>
      </button>
      {summaryOpen && renderBody(summary!)}
    </div>
  )

  return (
    <li id={`turn-${anchorId}`} data-turn-id={anchorId} className="scroll-mt-20">
      {prompt ? (
        // The prompt — full markdown through the shared Message renderer, with
        // the owner stamp above it. Its id carries `prompt-<id>` for deep links.
        <div id={`prompt-${prompt.id}`} className="scroll-mt-20">
          <div className="mb-2 flex items-center text-xs text-muted-foreground">
            <UserChip
              name={owner.name || owner.username}
              avatarUrl={owner.avatar_url}
              className="font-medium"
            />
          </div>
          {renderBody(prompt)}
        </div>
      ) : (
        <p className="text-sm italic text-muted-foreground">
          Opening context before the first prompt.
        </p>
      )}

      <div className="mt-3 space-y-2">
        {visible.map((m) =>
          m.id === summary?.id ? (
            renderSummary()
          ) : isActionMessage(m) ? (
            renderActionRow(m)
          ) : (
            // A narrative message — assistant prose (or command pills, task
            // notifications, boilerplate disclosures, as Block renders them).
            <Message
              key={m.id}
              message={m}
              conversationId={conversationId}
              toolResults={toolResults}
              commandStdout={commandStdout[m.id]}
              folded={folded[m.id]}
              bare
              hideMenu
              label=""
            />
          ),
        )}
      </div>
    </li>
  )
}

export default memo(Turn)
