import { Head, useForm } from '@inertiajs/react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import AppLayout from '@/layouts/AppLayout'
import type { MintedApiToken } from '@/types'

type FormData = { name: string }

const INITIAL_DATA: FormData = { name: '' }

// Best-effort clipboard write, mirroring BarMenu's idiom: the copy is a
// convenience, so a denied permission or an insecure context fails quietly
// rather than throwing into the click handler.
function copy(text: string) {
  void navigator.clipboard?.writeText(text)
}

type Props = { minted?: MintedApiToken }

export default function New({ minted }: Props) {
  const form = useForm<FormData>(INITIAL_DATA)

  function submit(e: React.FormEvent) {
    e.preventDefault()
    form.post('/api_tokens')
  }

  // The once-only mint reveal: create renders this page with the plaintext
  // secret. It is never shown again — a revisit/refresh gets fresh props with
  // no minted token — so store it now.
  if (minted) {
    return (
      <AppLayout>
        <Head title="API token created" />
        <h1 className="text-2xl font-bold">API token created</h1>

        <div className="mt-4 max-w-2xl space-y-4">
          <p className="text-sm text-destructive">
            Store this secret now — it is shown <strong>only once</strong> and cannot be
            recovered. This is the only time you will see it.
          </p>
          <div className="rounded-lg border border-input bg-muted/50 p-3">
            <Label className="text-xs text-muted-foreground">{minted.name}</Label>
            <p className="mt-1 break-all font-mono text-sm">{minted.secret}</p>
          </div>
          <Button type="button" variant="outline" size="sm" onClick={() => copy(minted.secret)}>
            Copy secret
          </Button>
          <p className="text-sm text-muted-foreground">
            Send it as the bearer token on machine pushes:
            <code className="ml-1 font-mono">{'Authorization: Bearer <secret>'}</code>
          </p>
          <Button asChild size="sm">
            <a href="/api_tokens">Back to API tokens</a>
          </Button>
        </div>
      </AppLayout>
    )
  }

  return (
    <AppLayout>
      <Head title="New API token" />
      <h1 className="text-2xl font-bold">New API token</h1>
      <p className="mt-1 text-sm text-muted-foreground">
        Mint a per-user bearer token for machine pushes. The secret is shown once at mint
        time; only its hash is stored.
      </p>

      <form onSubmit={submit} className="mt-4 max-w-2xl space-y-6">
        <div className="space-y-1">
          <Label>Name</Label>
          <Input
            value={form.data.name}
            onChange={(e) => form.setData('name', e.target.value)}
            placeholder="laptop CLI"
            required
          />
          {form.errors.name && <p className="text-sm text-destructive">{form.errors.name}</p>}
        </div>

        <Button type="submit" disabled={form.processing}>
          Create token
        </Button>
      </form>
    </AppLayout>
  )
}
