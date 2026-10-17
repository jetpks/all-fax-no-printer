export type FlashData = {
  notice?: string
  alert?: string
}

export type User = {
  id: number
  username: string
  avatar_url: string | null
}

export type SharedProps = {
  current_user: User | null
  flash: FlashData
}

// A transcript content block. The wire data is dynamic (arbitrary tool output),
// so the base type is a loose record; the named shapes below are used for casts
// in the Block renderer once `type` is known.
export type Block = { type: string; [key: string]: unknown }
export type TextBlock = { type: 'text'; text: string }
export type ThinkingBlock = { type: 'thinking'; thinking: string }
// Reasoning that exists only as ciphertext (Codex encrypted chain-of-thought).
export type RedactedThinkingBlock = { type: 'redacted_thinking'; data?: string }
export type ToolUseBlock = {
  type: 'tool_use'
  id?: string
  name: string
  input: unknown
}
export type ToolResultBlock = {
  type: 'tool_result'
  tool_use_id?: string
  content: string | Array<{ text?: string } | string>
  is_error?: boolean
}

// Cross-message pairing of a tool_use to its tool_result (which lands in a later
// user-role turn). Built at render time, threaded down to the Block renderer.
export type ToolResultIndex = {
  byUseId: Record<string, ToolResultBlock>
  useIds: Set<string>
}

// What an annotation is attached to. Every entity in the transcript hierarchy
// reduces to a kind + an anchor message (+ a tool_use id for tool calls), so
// annotations carry a target descriptor instead of a foreign key per entity.
export type TargetKind = 'conversation' | 'turn' | 'prompt' | 'round' | 'tool' | 'message'

// A W3C-style TextQuoteSelector marking a passage of one message's *rendered*
// text: the quoted text plus ~32 chars of context either side, and the char
// offset it sat at when captured (a tie-break hint, not an address).
export type Selector = {
  exact: string
  prefix: string
  suffix: string
  position: number
}

export type Annotation = {
  id: number
  body: string
  author: string
  author_avatar_url: string | null
  can_delete: boolean
  target_kind: TargetKind
  anchor_message_id: number | null
  tool_use_id: string | null
  selector: Selector | null
}

export type Message = {
  id: number
  role: string
  model: string | null
  position: number
  published: boolean
  blocks: Block[]
  can_publish: boolean
}

// A derived sub-grouping of a turn (server-authoritative, see app/models/round.rb):
// one iteration of the agentic loop — a narrative preamble plus the tool calls it
// spawned, with machinery (tool results, stdout halves) riding along. anchor_id is
// the first structural member's id.
export type Round = {
  anchor_id: number
  messages: Message[]
}

// A derived grouping (server-authoritative, see app/models/turn.rb): one prompt
// followed by the agent's response messages, partitioned into rounds. anchor_id
// is the turn's stable identity; prompt is null for a prompt-less preamble turn.
export type Turn = {
  anchor_id: number
  prompt: Message | null
  rounds: Round[]
}

export type ConversationListItem = {
  id: number
  title: string
  status: string
  published: boolean
  turns_count: number
  owned: boolean
  // Role tag stamped at ingest (architect/builder/judge/…); null = interactive.
  agent_role: string | null
  agent_name: string | null
  model: string | null
  original_cwd: string | null
  space_id: number | null
  updated_at: string
}

export type Conversation = {
  id: number
  title: string
  status: string
  published: boolean
  source: string | null
  original_cwd: string | null
  git_branch: string | null
  agent_version: string | null
  can_manage: boolean
  // Whose conversation this is — the identity stamped on every prompt.
  owner: {
    username: string
    name: string | null
    avatar_url: string | null
  }
  // Owner-only: the conversation this one is a subagent transcript of. Absent
  // (not just null) for non-owners and anonymous viewers.
  parent?: { id: number; title: string } | null
  // Owner-only: subagent transcripts synced from this conversation. Absent
  // for non-owners and anonymous viewers; empty array when there are none.
  children?: Array<{ id: number; title: string; session_id: string; agent_role: string | null }>
  // Role tag stamped at ingest (architect/builder/judge/…); null = interactive.
  agent_role: string | null
  agent_name: string | null
  model: string | null
  // The space this capture was filed under via the ingest mouth's space-slug
  // header; null → grouped by working directory instead.
  space_id: number | null
}

// The `?page=N` cursor a list page received alongside its row prop, capped at
// ≤ 50 rows per page. has_more is true iff a further page exists.
export type Pagination = {
  page: number
  has_more: boolean
}

// A per-user machine-auth credential (minted at /api_tokens/new). The
// plaintext secret exists only in the mint response — the server persists its
// SHA-256 hash and never shows it again.
export type ApiToken = {
  id: number
  name: string
  created_at: string
  last_used_at: string | null
  revoked_at: string | null
}

// The once-only mint response: the secret as presented to the owner.
export type MintedApiToken = {
  name: string
  secret: string
}

export type SpaceListItem = {
  id: number
  slug: string
  title: string
  status: string
  iterations_count: number
  conversations_count: number
  // May be null — a space with no captured activity yet.
  last_activity_at: string | null
}

// A viewer's space-less conversations bucketed by original working directory
// (the Spaces index's "Unspaced" section).
export type UnspacedBucket = {
  cwd: string
  conversations_count: number
  last_activity_at: string | null
}

// A conversation row on the Spaces show timeline.
export type SpaceConversation = {
  id: number
  title: string
  agent_role: string | null
  agent_name: string | null
  status: string
  model: string | null
  updated_at: string
}

export type SpaceArtifact = {
  id: number
  kind: string
  path: string
  title: string
}

export type SpaceArtifactDetail = {
  id: number
  kind: string
  path: string
  title: string
  raw: string
}

export type SpaceIteration = {
  id: number
  ordinal: number
  name: string
  freeze_sha: string | null
  verdict: string | null
  created_at?: string
  occurred_at?: string | null
  occurred_at_utc_offset?: number | null
  decisions?: { name: string; body: string }[]
  artifacts: SpaceArtifact[]
}

export type Space = {
  id: number
  slug: string
  title: string
  status: string
  repos: string[]
  git_utc_offset?: number | null
}
