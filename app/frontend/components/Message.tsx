import { useState } from 'react'
import { Badge } from '@/components/ui/badge'
import Block from '@/components/Block'
import SourceView from '@/components/SourceView'
import BarMenu from '@/components/BarMenu'
import { SECTION_HEADER } from '@/lib/tools'
import type { Marker } from '@/lib/tools'
import type { Message as MessageType, ToolResultIndex } from '@/types'

export default function Message({
  message,
  toolResults,
  commandStdout,
  folded,
  bare = false,
  headerHighlight = false,
  label,
  marker,
  hideMenu = false,
  showSource: showSourceProp,
}: {
  message: MessageType
  // Frozen callers still pass this; the annotation seam it once scoped is gone,
  // but the prop stays declared for their sake.
  conversationId: number
  toolResults?: ToolResultIndex
  commandStdout?: string
  // A marked beat (decision/memory/commit): its tool header shows the glyph + color.
  marker?: Marker
  // Turns folded into this one (paired tool results), shown in the source view.
  folded?: MessageType[]
  // Drop the card chrome (border/bg/padding) — used when the message renders
  // inside another surface that already provides it (e.g. an expanded action
  // row's pressed-in panel), so we don't double up the border.
  bare?: boolean
  // Render the header as a tinted section band (matching Turn's prompt/thought
  // headers) — used when this message *is* a turn section (the terminal), not a
  // nested beat. Off for leads and tool details, which are just plain headers.
  headerHighlight?: boolean
  // What this message *is* in its context — "round" for a round lead, "tool" for a
  // tool detail. Defaults to the raw role. We stopped labeling every nested beat
  // "assistant" (it was noise on every lead and tool); the structural name is clearer.
  label?: string
  // Suppress this message's own ⋯ menu — used when an owning bar (a round or tool
  // row) already carries one for it, so the two don't stack side by side. The bar
  // then drives the source view through the controlled prop.
  hideMenu?: boolean
  // Controlled source-view open-state. When omitted it falls back to local state —
  // the standalone terminal message keeps its menu and owns this itself; a body
  // message reads it from its bar (which toggles source).
  showSource?: boolean
}) {
  const [showSourceSelf, setShowSourceSelf] = useState(false)
  const showSource = showSourceProp ?? showSourceSelf

  // With the menu gone and no title/badge to show (a bare lead or tool detail), the
  // header row would be an empty strip — drop it and let the content sit flush.
  const title = label ?? message.role
  const showHeader = !hideMenu || !!title || message.published

  return (
    <div
      id={`message-${message.id}`}
      // scroll-mt clears the sticky turn bar when a deep link jumps here
      // (block: 'start') — same offset every other anchor row uses.
      className={bare ? 'scroll-mt-20' : 'scroll-mt-20 rounded-lg border border-border bg-card p-4'}
    >
      {showHeader && (
        <div
          className={
            headerHighlight
              ? SECTION_HEADER
              : 'mb-2 flex items-center gap-2 text-xs uppercase tracking-wide text-muted-foreground'
          }
        >
          <span className="font-bold text-foreground">{title}</span>
          {message.published && <Badge variant="secondary">turn published</Badge>}
          {!hideMenu && (
            // Every action for this message — source, copy source, permalink —
            // collapses into one ⋯ menu pinned to the header's right edge.
            <div className="ml-auto">
              <BarMenu
                label="Message actions"
                anchor={`message-${message.id}`}
                source={{ shown: showSource, onToggle: () => setShowSourceSelf((v) => !v) }}
                copySource={() => JSON.stringify(message.blocks, null, 2)}
              />
            </div>
          )}
        </div>
      )}

      {showSource ? (
        <SourceView blocks={message.blocks} folded={folded} />
      ) : (
        <div className="space-y-2">
          {message.blocks.map((block, i) => (
            <Block
              key={i}
              block={block}
              toolResults={toolResults}
              commandStdout={commandStdout}
              marker={marker}
            />
          ))}
        </div>
      )}
    </div>
  )
}