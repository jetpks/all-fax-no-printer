import { useCallback, useEffect, useMemo, useState } from 'react'
import { Head, Link, router } from '@inertiajs/react'
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from '@/components/ui/alert-dialog'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import LiveLog from '@/components/LiveLog'
import { buildCommandPairs, buildFoldedIndex, buildToolResultIndex } from '@/lib/message-pairing'
import { parseAnchor, turnMessages } from '@/lib/anchors'
import Turn from '@/components/Turn'
import TurnToc from '@/components/TurnToc'
import AppLayout from '@/layouts/AppLayout'
import type { Conversation, Turn as TurnType } from '@/types'

type Props = {
  conversation: Conversation
  turns: TurnType[]
}

type BadgeVariant = 'default' | 'secondary' | 'destructive' | 'outline'

// The four capture statuses from the conversations contract — mirrored by
// Conversations/Index's map for the list rows.
const STATUS_VARIANT: Record<string, BadgeVariant> = {
  pending: 'outline',
  live: 'default',
  completed: 'secondary',
  failed: 'destructive',
}

// The annotation anchors of the old notes tier are gone, so the pairing/fold
// rules see an always-empty set — the same empty set the frozen Spaces pages
// pass. A module constant keeps buildFoldedIndex's memo deps honest.
const NO_ANNOTATED_IDS = new Set<number>()

export default function Show({ conversation, turns }: Props) {
  // A capture still landing (ingest mouth not yet terminal) streams into the
  // I12 LiveLog below — the log is the page-level signal; the badge is per-row.
  const isLiveCapture = conversation.status === 'pending' || conversation.status === 'live'

  // Which turns are currently on screen — drives the TOC highlight so you can
  // see your position even color-blind.
  const [activeTurns, setActiveTurns] = useState<Set<number>>(new Set())

  useEffect(() => {
    // We recompute the visible set from element rects on a rAF-throttled scroll,
    // rather than accumulating IntersectionObserver deltas: IO heavily throttles
    // (and some browsers defer) its callbacks during a fast scroll, so exit
    // notifications arrive late or get coalesced away — leaving turns lit after
    // they've scrolled off (a delta you never receive can't be undone). Rebuilding
    // the set from truth each frame can't get stuck; worst case is one frame stale.
    const els = Array.from(document.querySelectorAll<HTMLElement>('[data-turn-id]'))
    let raf = 0
    const reconcile = () => {
      raf = 0
      const vh = window.innerHeight
      const next = new Set<number>()
      for (const el of els) {
        const r = el.getBoundingClientRect()
        if (r.bottom > 0 && r.top < vh) next.add(Number(el.dataset.turnId))
      }
      // Keep the old reference when nothing changed so the TOC doesn't re-render.
      setActiveTurns((prev) =>
        prev.size === next.size && [...next].every((id) => prev.has(id)) ? prev : next,
      )
    }
    const onScroll = () => {
      if (!raf) raf = requestAnimationFrame(reconcile)
    }
    reconcile()
    window.addEventListener('scroll', onScroll, { passive: true })
    window.addEventListener('resize', onScroll, { passive: true })
    return () => {
      if (raf) cancelAnimationFrame(raf)
      window.removeEventListener('scroll', onScroll)
      window.removeEventListener('resize', onScroll)
    }
  }, [turns])
  const [pendingScroll, setPendingScroll] = useState<{
    target: string
    // A deep-linked message id (reveal) — the `#round-…` fallback lives here:
    // rounds no longer render as containers, but a round's anchor id IS a
    // message id (Round#anchor in app/transcript/round.rb), so the same id
    // resolves as `#message-<id>` on the row that holds it.
    messageId: number | null
    turn: number
  } | null>(null)
  // The marker message a TOC jump asked us to reveal — handed to its turn so
  // the action row holding it opens. Cleared once consumed so re-clicking the
  // same marker (after a manual collapse) reveals it again.
  const [revealId, setRevealId] = useState<number | null>(null)

  // Jump from the TOC or a deep link: reveal the target (if it's an action row)
  // and scroll once the DOM has settled (deferred via state so the scroll runs
  // after the re-render that expands a just-revealed row). Stable (useCallback)
  // so it's a steady prop for the memoized TOC without churning it on every
  // scroll-driven re-render.
  const jumpTo = useCallback((anchorId: number, target?: string, reveal?: number) => {
    setRevealId(reveal ?? null)
    setPendingScroll({
      target: target ? `#${target}` : `#turn-${anchorId}`,
      messageId: reveal ?? null,
      turn: anchorId,
    })
  }, [])

  useEffect(() => {
    if (!pendingScroll) return
    // The precise anchor may not be mounted yet — an action row the reveal is
    // expanding in this same commit — so retry a few frames before falling back:
    // first to `#message-<id>` (what a `#round-<id>` fragment degrades to), then
    // to the turn top (a marker that's the turn's terminal renders as a plain
    // message; the click still gets you there).
    let tries = 0
    let raf = 0
    const attempt = () => {
      const el =
        document.querySelector(pendingScroll.target) ??
        (pendingScroll.messageId != null
          ? document.querySelector(`#message-${pendingScroll.messageId}`)
          : null)
      if (!el && tries++ < 5) {
        raf = requestAnimationFrame(attempt)
        return
      }
      const target = el ?? document.querySelector(`#turn-${pendingScroll.turn}`)
      target?.scrollIntoView({ behavior: 'smooth', block: 'start' })
      // A one-shot flash so the eye lands with the scroll; classList (not a
      // prop) so the transient effect doesn't churn the memoized Turn tree.
      if (target) {
        target.classList.add('anchor-flash')
        target.addEventListener('animationend', () => target.classList.remove('anchor-flash'), {
          once: true,
        })
      }
      setPendingScroll(null)
      setRevealId(null)
    }
    attempt()
    return () => cancelAnimationFrame(raf)
  }, [pendingScroll])

  // These indices are a pure function of the props, so memoize them — otherwise
  // every activeTurns tick while scrolling recomputed all of them. They also feed
  // the memoized Turn as stable props: the pairing/fold indices plus each turn's
  // non-prompt message list in stream order (the turn itself decides what's
  // visible when it renders — see Turn's visibility peel).
  const messages = useMemo(() => turns.flatMap(turnMessages), [turns])
  const toolResults = useMemo(() => buildToolResultIndex(messages), [messages])
  const commandPairs = useMemo(() => buildCommandPairs(messages), [messages])
  const folded = useMemo(
    () =>
      buildFoldedIndex(messages, toolResults, commandPairs.foldedByCommandId, NO_ANNOTATED_IDS),
    [messages, toolResults, commandPairs],
  )
  const replyByTurn = useMemo(
    () =>
      new Map(
        turns.map((t) => [t.anchor_id, turnMessages(t).filter((m) => m.id !== t.prompt?.id)]),
      ),
    [turns],
  )

  // Owning turn per message id — how a deep link to a round/tool/message finds
  // the turn that must reveal it.
  const turnByMessageId = useMemo(() => {
    const map = new Map<number, number>()
    for (const turn of turns) for (const m of turnMessages(turn)) map.set(m.id, turn.anchor_id)
    return map
  }, [turns])

  // Honor an entity address arriving in the URL fragment (#turn-12, #round-34,
  // #tool-56, #message-78, or a marker) — on first paint and on later hash
  // changes: scroll to it, expanding the tool row that buries it. The same
  // jumpTo path the TOC uses, so deep links and TOC clicks can't drift apart.
  useEffect(() => {
    const followHash = () => {
      const parsed = parseAnchor(window.location.hash)
      if (!parsed) return
      const turnAnchor =
        parsed.kind === 'turn' ? parsed.messageId : turnByMessageId.get(parsed.messageId)
      if (turnAnchor == null) return
      jumpTo(
        turnAnchor,
        parsed.kind === 'turn' ? undefined : window.location.hash.slice(1),
        parsed.kind === 'turn' ? undefined : parsed.messageId,
      )
    }
    followHash()
    window.addEventListener('hashchange', followHash)
    return () => window.removeEventListener('hashchange', followHash)
  }, [turnByMessageId, jumpTo])
  const meta: [string, string | null][] = [
    ['source', conversation.source],
    ['cwd', conversation.original_cwd],
    ['branch', conversation.git_branch],
    ['version', conversation.agent_version],
  ]

  function togglePublish() {
    router.patch(`/conversations/${conversation.id}/publish`, {}, { preserveScroll: true })
  }

  return (
    <AppLayout mainClassName="max-w-6xl">
      <Head title={conversation.title} />

      <details className="mb-4 lg:hidden">
        <summary className="cursor-pointer text-sm text-muted-foreground">Jump to turn…</summary>
        <div className="mt-3">
          <TurnToc
            turns={turns}
            active={activeTurns}
            projectRoot={conversation.original_cwd}
            onJump={jumpTo}
          />
        </div>
      </details>

      <div className="lg:grid lg:grid-cols-[14rem_minmax(0,1fr)] lg:gap-8">
        <aside className="hidden lg:block">
          <div className="sticky top-6">
            <TurnToc
              turns={turns}
              active={activeTurns}
              projectRoot={conversation.original_cwd}
              onJump={jumpTo}
            />
          </div>
        </aside>

        <div className="min-w-0">
          <header id="conversation" className="mb-4 scroll-mt-20 border-b border-border pb-4">
            <h1 className="text-2xl font-bold">{conversation.title}</h1>
            {conversation.parent && (
              <p className="mt-1 text-sm text-muted-foreground">
                part of{' '}
                <Link href={`/conversations/${conversation.parent.id}`} className="hover:underline">
                  {conversation.parent.title}
                </Link>
              </p>
            )}
            <p className="mt-1 flex items-center gap-2 text-sm text-muted-foreground">
              <Badge variant={STATUS_VARIANT[conversation.status] ?? 'outline'}>
                {conversation.status}
              </Badge>
              {turns.length} turns
              {conversation.published && <Badge variant="secondary">published</Badge>}
            </p>

            <dl className="mt-2 grid grid-cols-[max-content_minmax(0,1fr)] gap-x-3 text-xs text-muted-foreground">
              {meta.map(([label, value]) =>
                value ? (
                  <div key={label} className="contents">
                    <dt className="font-mono">{label}</dt>
                    <dd className="break-all">{value}</dd>
                  </div>
                ) : null,
              )}
            </dl>

            {conversation.can_manage && (
              <div className="mt-3 flex gap-2">
                <Button size="sm" onClick={togglePublish}>
                  {conversation.published ? 'Unpublish' : 'Publish whole conversation'}
                </Button>
                <AlertDialog>
                      <AlertDialogTrigger asChild>
                        <Button size="sm" variant="destructive">
                          Delete
                        </Button>
                      </AlertDialogTrigger>
                      <AlertDialogContent>
                        <AlertDialogHeader>
                          <AlertDialogTitle>Delete this conversation?</AlertDialogTitle>
                          <AlertDialogDescription>
                            This permanently removes the conversation and its {turns.length} turns.
                          </AlertDialogDescription>
                        </AlertDialogHeader>
                        <AlertDialogFooter>
                          <AlertDialogCancel>Cancel</AlertDialogCancel>
                          <AlertDialogAction
                            onClick={() => router.delete(`/conversations/${conversation.id}`)}
                          >
                            Delete
                          </AlertDialogAction>
                        </AlertDialogFooter>
                      </AlertDialogContent>
                    </AlertDialog>
              </div>
            )}
          </header>

          {conversation.children && conversation.children.length > 0 && (
            <section className="mb-4 border-b border-border pb-4">
              <h2 className="text-sm font-semibold text-muted-foreground">Subagent transcripts</h2>
              <ul className="mt-2 divide-y divide-border">
                {conversation.children.map((child) => (
                  <li key={child.id} className="flex items-center gap-2 py-1.5">
                    <Link href={`/conversations/${child.id}`} className="text-sm hover:underline">
                      {child.title}
                    </Link>
                    {child.agent_role && (
                      <Badge variant="outline" className="text-xs">
                        {child.agent_role}
                      </Badge>
                    )}
                  </li>
                ))}
              </ul>
            </section>
          )}

          {isLiveCapture && (
            // The I12 LiveLog (frozen seam) replaces the old streamed-message
            // tree: a looplog-style event log while the capture is landing —
            // conversation mode consumes /conversations/:id/stream unfiltered,
            // closes on conversation_complete, and re-syncs on refocus.
            <div
              data-testid="live-capture"
              className="mb-4 rounded-lg border border-border bg-muted/30 p-4"
            >
              <h2 className="mb-2 text-sm font-semibold text-muted-foreground">Live capture</h2>
              <LiveLog conversationId={conversation.id} />
            </div>
          )}

          <ol className="mt-4 space-y-6">
            {turns.map((turn) => (
              <Turn
                key={turn.anchor_id}
                anchorId={turn.anchor_id}
                prompt={turn.prompt}
                absorbedIds={commandPairs.absorbedIds}
                reply={replyByTurn.get(turn.anchor_id) ?? []}
                conversationId={conversation.id}
                toolResults={toolResults}
                commandStdout={commandPairs.stdoutByMessageId}
                folded={folded}
                reveal={
                  revealId != null && turnByMessageId.get(revealId) === turn.anchor_id
                    ? revealId
                    : null
                }
                projectRoot={conversation.original_cwd}
                owner={conversation.owner}
              />
            ))}
          </ol>
        </div>
      </div>
    </AppLayout>
  )
}
