import { Head, Link } from '@inertiajs/react'
import { Badge } from '@/components/ui/badge'
import AppLayout from '@/layouts/AppLayout'
import Markdown from '@/components/Markdown'
import type {
  Space,
  SpaceArtifact,
  SpaceConversation,
  SpaceIteration,
} from '@/types'
import { KIND_VARIANT, STATUS_VARIANT, VERDICT_VARIANT, formatAbsolute, relativeTime } from './helpers'
import { interleaveTimeline } from './timeline'

type Props = {
  space: Space
  iterations: SpaceIteration[]
  conversations: SpaceConversation[]
  other_artifacts: SpaceArtifact[]
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
    <li className="flex items-center justify-between gap-2 py-1 text-sm">
      <div className="flex min-w-0 items-center gap-2">
        <Link href={`/conversations/${conversation.id}`} className="truncate hover:underline">
          {conversation.title}
        </Link>
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
      </div>
      <span className="shrink-0 text-xs text-muted-foreground">{relativeTime(conversation.updated_at)}</span>
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
}: Props) {
  const timeline = interleaveTimeline(iterations, conversations)
  const sortedIterations = timeline
    .filter(
      (item): item is { type: 'iteration'; data: SpaceIteration } => item.type === 'iteration',
    )
    .map((item) => item.data)

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

      {sortedIterations.length > 1 && (
        <nav className="mb-6 flex flex-wrap gap-x-4 gap-y-1 text-xs">
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

      {timeline.length === 0 ? (
        <p className="text-sm text-muted-foreground">No iterations yet.</p>
      ) : (
        <div data-testid="timeline" className="space-y-4">
          {timeline.map((item) =>
            item.type === 'iteration' ? (
              <IterationSection
                key={`iter-${item.data.id}`}
                space={space}
                iteration={item.data}
              />
            ) : (
              <section
                id={`conversation-${item.data.id}`}
                className="rounded-lg border border-border p-4"
              >
                <ul className="divide-y divide-border">
                  <ConversationRow conversation={item.data} />
                </ul>
              </section>
            ),
          )}
        </div>
      )}

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
