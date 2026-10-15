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
import AppLayout from '@/layouts/AppLayout'
import type { ApiToken } from '@/types'
import { timeLabel } from '@/pages/Spaces/helpers'

type Props = { tokens: ApiToken[] }

export default function Index({ tokens }: Props) {
  return (
    <AppLayout>
      <Head title="API tokens" />

      <div className="mb-4 flex items-center justify-between">
        <h1 className="text-2xl font-bold">API tokens</h1>
        <Button asChild size="sm">
          <Link href="/api_tokens/new">New token</Link>
        </Button>
      </div>

      {tokens.length === 0 ? (
        <p className="text-sm text-muted-foreground">No API tokens yet.</p>
      ) : (
        <ul className="divide-y divide-border">
          {tokens.map((token) => (
            <li key={token.id} className="flex items-center justify-between py-3">
              <div>
                <p className="font-medium">{token.name}</p>
                <p className="text-xs text-muted-foreground">
                  Created {timeLabel(token.created_at, null)}
                  {token.last_used_at && <> · Last used {timeLabel(token.last_used_at, null)}</>}
                </p>
              </div>

              {token.revoked_at ? (
                <Badge variant="outline">Revoked</Badge>
              ) : (
                <AlertDialog>
                  <AlertDialogTrigger asChild>
                    <Button size="sm" variant="destructive">
                      Revoke
                    </Button>
                  </AlertDialogTrigger>
                  <AlertDialogContent>
                    <AlertDialogHeader>
                      <AlertDialogTitle>Revoke this token?</AlertDialogTitle>
                      <AlertDialogDescription>
                        "{token.name}" stops authenticating immediately. This cannot be undone.
                      </AlertDialogDescription>
                    </AlertDialogHeader>
                    <AlertDialogFooter>
                      <AlertDialogCancel>Cancel</AlertDialogCancel>
                      <AlertDialogAction
                        onClick={() => router.post(`/api_tokens/${token.id}/delete`)}
                      >
                        Revoke
                      </AlertDialogAction>
                    </AlertDialogFooter>
                  </AlertDialogContent>
                </AlertDialog>
              )}
            </li>
          ))}
        </ul>
      )}
    </AppLayout>
  )
}
