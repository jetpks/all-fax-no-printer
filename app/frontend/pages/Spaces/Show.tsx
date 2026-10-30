import { Head, Link } from '@inertiajs/react'
import { Badge } from '@/components/ui/badge'
import AppLayout from '@/layouts/AppLayout'
import LiveLog from '@/components/LiveLog'
import Markdown from '@/components/Markdown'
import type {
  Space,
  SpaceArtifact,
  SpaceConversation,
  SpaceIteration,
  SpaceNarrator,
} from '@/types'
import { KIND_VARIANT, STATUS_VARIANT, VERDICT_VARIANT, formatAbsolute, relativeTime } from './helpers'

type Props = {
  space: Space
  iterations: SpaceIteration[]
  conversations: SpaceConversation[]
  other_artifacts: SpaceArtifact[]
  // The last qualifying narrator message (server-derived); null → section omitted.
  narrator: SpaceNarrator | null
}

function ArtifactRow({ spaceId, artifact }: { spaceId: number; artifact: SpaceArtifact }) {
  return (
    <li className="flex items-start gap-2 py-1 text-sm">
      <Badge variant={KIND_VARIANT[artifact.kind] ?? 'outline'} className="mt-0.5 shrink-0">
        {artifact.kind}
      </Badge>
      <Markdown text={artifact.title} />
      <Link
        href={`/spaces/${spaceId}/artifacts/${artifact.id}`}
        className="ml-auto text-xs font-medium hover:underline"
      >
        View
      </Link>
    </li>
  )
}

function ConversationRow({ conversation }: { conversation: SpaceConversation }) {
  return (
    <li>
      {/* The anchor IS the row: one block-level, full-width tap target wrapping
          every piece of row content — works at 375px (phone-first). */}
      <Link
        data-testid="conversation-row-link"
        href={`/conversations/${conversation.id}`}
        className="block rounded border border-border px-3 py-2 text-sm hover:bg-muted/30"
      >
        <div className="flex min-w-0 flex-wrap items-center gap-2">
          {/* Raw title from the server; empty or whitespace-only falls back here. */}
          <span className="min-w-0 truncate">{conversation.title?.trim() || 'Untitled conversation'}</span>
          {conversation.agent_role && (
            <Badge variant="outline" className="shrink-0">
              {conversation.agent_role}
            </Badge>
          )}
          <Badge variant={STATUS_VARIANT[conversation.status] ?? 'outline'} className="shrink-0">
            {conversation.status}
          </Badge>
          {conversation.model && (
            <span className="shrink-0 font-mono text-xs text-muted-foreground">{conversation.model}</span>
          )}
          <span className="ml-auto shrink-0 text-xs text-muted-foreground">{relativeTime(conversation.updated_at)}</span>
        </div>
      </Link>
    </li>
  )
}

function DecisionSection({ decision }: { decision: { name: string; body: string } }) {
  return (
    <details className="mb-2 rounded border border-border/50">
      <summary className="cursor-pointer px-3 py-2 text-sm font-medium select-none hover:bg-muted/30">
        {decision.name}
      </summary>
      <div className="overflow-x-auto max-w-full px-3 pb-3 pt-1">
        <Markdown text={decision.body} />
      </div>
    </details>
  )
}

function IterationSection({
  space,
  iteration,
}: {
  space: Space
  iteration: SpaceIteration
}) {
  return (
    <section id={`iteration-${iteration.id}`} className="scroll-mt-20 rounded-lg border border-border p-4">
      <div className="mb-3 flex flex-wrap items-center gap-3">
        <span className="font-mono text-xs text-muted-foreground">
          I{String(iteration.ordinal).padStart(2, '0')}
        </span>
        <h2 className="font-semibold">{iteration.name}</h2>
        {iteration.freeze_sha && (
          <code className="text-xs text-muted-foreground">
            {iteration.freeze_sha.slice(0, 7)}
          </code>
        )}
        {iteration.verdict && (
          <Badge variant={VERDICT_VARIANT[iteration.verdict] ?? 'outline'}>
            {iteration.verdict}
          </Badge>
        )}
        {iteration.phase_kind && (
          <Badge variant="outline" data-testid="phase-chip">
            {iteration.phase_kind}
          </Badge>
        )}
        {iteration.occurred_at && (
          <span className="ml-auto text-xs text-muted-foreground">
            {relativeTime(iteration.occurred_at)}
            {' · '}
            <span className="font-mono">{formatAbsolute(iteration.occurred_at, iteration.occurred_at_utc_offset)}</span>
          </span>
        )}
      </div>

      {(iteration.decisions ?? []).length > 0 && (
        <div className="mb-4">
          <p className="mb-2 text-xs font-medium uppercase tracking-wide text-muted-foreground">
            Decisions
          </p>
          {(iteration.decisions ?? []).map((d) => (
            <DecisionSection key={d.name} decision={d} />
          ))}
        </div>
      )}

      {iteration.artifacts.length > 0 && (
        <div>
          <p className="mb-1 text-xs font-medium uppercase tracking-wide text-muted-foreground">
            Artifacts
          </p>
          <ul className="space-y-0.5">
            {iteration.artifacts.map((a) => (
              <ArtifactRow key={a.id} spaceId={space.id} artifact={a} />
            ))}
          </ul>
        </div>
      )}
    </section>
  )
}

export default function Show({
  space,
  iterations,
  conversations,
  other_artifacts,
  narrator,
}: Props) {
  // Iterations ascend by ordinal. Conversations render in PROP ORDER — the
  // server sends them newest-first by updated_at; no client re-sort (the old
  // ascending timeline sort is the defect this layout kills).
  const sortedIterations = [...iterations].sort((a, b) => a.ordinal - b.ordinal)

  // Rolled-up "where is the loop now": the highest-ordinal iteration carrying
  // a modeled phase ping. Derived ONLY from phase data — no LiveLog/stream/
  // session-sink coupling, no inference from conversation titles; omitted
  // entirely when no iteration carries a phase.
  const phaseCarrier = [...iterations]
    .filter((iter) => iter.phase_kind != null)
    .sort((a, b) => b.ordinal - a.ordinal)[0]

  return (
    <AppLayout>
      <Head title={space.title} />

      <header className="mb-6 border-b border-border pb-4">
        <h1 className="text-2xl font-bold">{space.title}</h1>
        <p className="mt-1 flex items-center gap-3 text-sm text-muted-foreground">
          {space.slug}
          <Badge variant={STATUS_VARIANT[space.status] ?? 'outline'}>{space.status}</Badge>
        </p>
        {space.repos.length > 0 && (
          <ul className="mt-2 flex flex-wrap gap-3">
            {space.repos.map((repo) => (
              <li key={repo} className="text-xs text-muted-foreground">
                {repo}
              </li>
            ))}
          </ul>
        )}
      </header>

      {/* The deck, top to bottom: rolled-up loop-phase line, live log of the
          whole space, last narrator message, newest-first conversations,
          iterations, other artifacts. */}
      {phaseCarrier && (
        <section
          data-testid="loop-phase-line"
          className="mb-6 flex flex-wrap items-center gap-2 rounded-lg border border-border px-4 py-2.5 text-sm"
        >
          <span className="font-medium">Loop phase</span>
          <a
            href={`#iteration-${phaseCarrier.id}`}
            className="text-muted-foreground hover:text-foreground hover:underline"
          >
            I{String(phaseCarrier.ordinal).padStart(2, '0')} · {phaseCarrier.name}
          </a>
          <Badge variant="outline">{phaseCarrier.phase_kind}</Badge>
          {phaseCarrier.phase_at && (
            <span className="ml-auto text-xs text-muted-foreground">
              {relativeTime(phaseCarrier.phase_at)}
            </span>
          )}
        </section>
      )}

      <section className="mb-6">
        <h2 className="mb-2 text-lg font-semibold">Live</h2>
        <LiveLog spaceId={space.id} />
      </section>

      {narrator && (
        <section data-testid="narrator-section" className="mb-6">
          <h2 className="mb-2 text-lg font-semibold">Narrator</h2>
          <Link
            href={`/conversations/${narrator.conversation_id}`}
            className="block rounded-lg border border-border p-4 hover:bg-muted/30"
          >
            <Markdown text={narrator.text} />
          </Link>
        </section>
      )}

      <section className="mb-6">
        <h2 className="mb-2 text-lg font-semibold">Conversations</h2>
        {conversations.length === 0 ? (
          <p className="text-sm text-muted-foreground">No conversations yet.</p>
        ) : (
          <ul className="space-y-1">
            {conversations.map((conversation) => (
              <ConversationRow key={conversation.id} conversation={conversation} />
            ))}
          </ul>
        )}
      </section>

      <section className="mb-6">
        <h2 className="mb-2 text-lg font-semibold">Iterations</h2>
        {sortedIterations.length > 1 && (
          <nav className="mb-4 flex flex-wrap gap-x-4 gap-y-1 text-xs">
            {sortedIterations.map((iter) => (
              <a
                key={iter.id}
                href={`#iteration-${iter.id}`}
                className="text-muted-foreground hover:text-foreground hover:underline"
              >
                I{String(iter.ordinal).padStart(2, '0')}: {iter.name}
              </a>
            ))}
          </nav>
        )}
        {sortedIterations.length === 0 ? (
          <p className="text-sm text-muted-foreground">No iterations yet.</p>
        ) : (
          <div className="space-y-4">
            {sortedIterations.map((iter) => (
              <IterationSection key={iter.id} space={space} iteration={iter} />
            ))}
          </div>
        )}
      </section>

      {other_artifacts.length > 0 && (
        <section className="mt-8">
          <h2 className="mb-3 text-lg font-semibold">Other Artifacts</h2>
          <ul className="space-y-0.5 rounded-lg border border-border p-4">
            {other_artifacts.map((a) => (
              <ArtifactRow key={a.id} spaceId={space.id} artifact={a} />
            ))}
          </ul>
        </section>
      )}
    </AppLayout>
  )
}
