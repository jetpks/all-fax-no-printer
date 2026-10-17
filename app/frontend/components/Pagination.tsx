import { router } from '@inertiajs/react'
import { Button } from '@/components/ui/button'
import type { Pagination as PaginationData } from '@/types'

type Props = {
  pagination: PaginationData
  path: string
  // Active filter params (e.g. ?cwd=) carried onto page links so paging
  // doesn't drop the filter. Optional — plain paths stay unfiltered.
  params?: Record<string, string>
}

// Target URL for a page visit: the path plus the active filter params and the
// page param. URLSearchParams handles the encoding and the `?`/`&` join.
function pageUrl(path: string, params: Record<string, string> | undefined, page: number): string {
  const search = new URLSearchParams(params)
  search.set('page', String(page))
  return `${path}?${search.toString()}`
}

// Drives Prev/Next for an index page's `?page=N` prop via an Inertia visit,
// carrying any active filter params forward.
export default function Pagination({ pagination, path, params }: Props) {
  const { page, has_more } = pagination
  if (page === 1 && !has_more) return null

  return (
    <div className="mt-4 flex items-center justify-between">
      <Button
        variant="outline"
        size="sm"
        disabled={page === 1}
        onClick={() => router.visit(pageUrl(path, params, page - 1))}
      >
        Prev
      </Button>
      <Button
        variant="outline"
        size="sm"
        disabled={!has_more}
        onClick={() => router.visit(pageUrl(path, params, page + 1))}
      >
        Next
      </Button>
    </div>
  )
}
