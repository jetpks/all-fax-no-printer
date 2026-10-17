import { Head, Link } from '@inertiajs/react'
import { Badge } from '@/components/ui/badge'
import AppLayout from '@/layouts/AppLayout'
import Pagination from '@/components/Pagination'
import type { ConversationListItem, Pagination as PaginationData } from '@/types'

type BadgeVariant = 'default' | 'secondary' | 'destructive' | 'outline'

// The four capture statuses from the conversations contract — mirrored by
// Spaces/helpers' map for the space-timeline rows.
const STATUS_VARIANT: Record<string, BadgeVariant> = {
  pending: 'outline',
  live: 'default',
  completed: 'secondary',
  failed: 'destructive',
}

type Props = {
  conversations: ConversationListItem[]
  pagination: PaginationData
  // Context of the active filter — present only when the index was filtered.
  space?: { id: number; slug: string; title: string }
  cwd?: string
}

export default function Index({ conversations, pagination, space, cwd }: Props) {
  // Paging must not drop the active filter param.
  const filterParams: Record<string, string> | undefined = cwd
    ? { cwd }
    : space
      ? { space_id: String(space.id) }
      : undefined

  return (
    <AppLayout>
      <Head title="Conversations" />
      <h1 className="mb-4 text-2xl font-bold">Conversations</h1>

      {space && (
        <p className="mb-4 text-sm text-muted-foreground">
          In space{' '}
          <Link href={`/spaces/${space.id}`} className="font-medium hover:underline">
            {space.title}
          </Link>{' '}
          <span className="font-mono text-xs">({space.slug})</span>
        </p>
      )}
      {cwd && (
        <p className="mb-4 text-sm text-muted-foreground">
          Working directory: <code className="break-all">{cwd}</code>
        </p>
      )}

      {conversations.length === 0 ? (
        <p className="text-sm text-muted-foreground">No conversations yet.</p>
      ) : (
        <ul className="divide-y divide-border">
          {conversations.map((c) => (
            <li key={c.id} className="py-3">
              <div className="flex items-center justify-between gap-3">
                <Link href={`/conversations/${c.id}`} className="font-medium hover:underline">
                  {c.title}
                </Link>
                <span className="flex shrink-0 items-center gap-2 text-xs text-muted-foreground">
                  {c.agent_role && <Badge variant="outline">{c.agent_role}</Badge>}
                  {c.model && <span className="font-mono">{c.model}</span>}
                  {c.turns_count} turns
                  <Badge variant={STATUS_VARIANT[c.status] ?? 'outline'}>{c.status}</Badge>
                  {c.published && <Badge variant="secondary">published</Badge>}
                  {c.owned && !c.published && <Badge variant="outline">private</Badge>}
                </span>
              </div>
              {c.original_cwd && (
                <p className="mt-0.5 truncate font-mono text-xs text-muted-foreground">
                  {c.original_cwd}
                </p>
              )}
            </li>
          ))}
        </ul>
      )}

      <Pagination pagination={pagination} path="/conversations" params={filterParams} />
    </AppLayout>
  )
}
