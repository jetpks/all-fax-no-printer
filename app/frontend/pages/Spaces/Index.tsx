import { Head, Link } from '@inertiajs/react'
import { Badge } from '@/components/ui/badge'
import AppLayout from '@/layouts/AppLayout'
import type { SpaceListItem, UnspacedBucket } from '@/types'
import { STATUS_VARIANT, timeLabel } from './helpers'

type Props = { spaces: SpaceListItem[]; unspaced: UnspacedBucket[] }

// Nil-safe activity label — a bucket/space with no captured activity has none.
function activityLabel(lastActivityAt: string | null): string {
  return lastActivityAt ? timeLabel(lastActivityAt) : 'no activity yet'
}

export default function Index({ spaces, unspaced }: Props) {
  return (
    <AppLayout>
      <Head title="Spaces" />
      <h1 className="mb-4 text-2xl font-bold">Spaces</h1>

      {spaces.length === 0 ? (
        <p className="text-sm text-muted-foreground">No spaces yet.</p>
      ) : (
        <ul className="divide-y divide-border">
          {spaces.map((s) => (
            <li key={s.id} className="flex items-center justify-between py-3">
              <Link href={`/spaces/${s.id}`} className="font-medium hover:underline">
                {s.title}
                <span className="ml-2 text-xs text-muted-foreground">{s.slug}</span>
              </Link>
              <span className="flex items-center gap-2 text-xs text-muted-foreground">
                <Badge variant={STATUS_VARIANT[s.status] ?? 'outline'}>{s.status}</Badge>
                {s.iterations_count}i · {s.conversations_count}c ·{' '}
                {activityLabel(s.last_activity_at)}
              </span>
            </li>
          ))}
        </ul>
      )}

      {unspaced.length > 0 && (
        <section className="mt-8">
          <h2 className="mb-3 text-lg font-semibold">Unspaced</h2>
          <p className="mb-3 text-sm text-muted-foreground">
            Captures filed by working directory — group them into a space via the
            ingest mouth's space-slug header.
          </p>
          <ul className="space-y-0.5 rounded-lg border border-border p-4">
            {unspaced.map((b) => (
              <li key={b.cwd} className="flex items-center justify-between py-1 text-sm">
                <Link
                  href={`/conversations?cwd=${encodeURIComponent(b.cwd)}`}
                  className="font-mono text-sm break-all hover:underline"
                >
                  {b.cwd}
                </Link>
                <span className="ml-4 shrink-0 text-xs text-muted-foreground">
                  {b.conversations_count}c · {activityLabel(b.last_activity_at)}
                </span>
              </li>
            ))}
          </ul>
        </section>
      )}
    </AppLayout>
  )
}
