# Per-Conversation Sandboxing — Design Note

## Problem

When the user switches to a new conversation while the agent is still
processing (thinking, streaming, running tools, or finishing a sub-agent) in
a previous conversation, several categories of state leak from the old
conversation into the currently-visible one:

| Symptom | Root cause |
|---------|-----------|
| "Thinking…" shimmer appears in the wrong chat | `ai_state` set unconditionally |
| Avatar stays in "thinking" animation after switching | `VoiceLoopCoordinator.setState(.thinking)` not scoped |
| Follow-up LLM call uses wrong conversation context | `chatContextMessages` reads from `self.messages`, which now holds the *new* conversation |
| Sub-agent spawned against the wrong parent conversation | `dispatchCall` falls back to `currentConversationEntity?.id`, which has changed |
| Dynamic-skill log lines update shimmer in wrong chat | `DynamicSkillRegistry.logHandler` is a single global closure |

## Architecture Summary

```
MessagingVC (single instance on iOS)
  ├── messages: [MessageStruct]        ← in-memory array for the *displayed* conversation
  ├── currentConversationEntity        ← which conversation is on screen
  ├── activeRequestConversationId      ← captured when user sends; used to route responses
  ├── ai_state: AIState                ← drives the "Thinking…" extra table row
  └── chatContextMessages              ← computed from self.messages for LLM calls

ConversationFileStore (NDJSON on disk / iCloud)
  └── per-conversation message files   ← source of truth for persistence

SubAgentManager (singleton)
  └── agents: [SubAgent]               ← each has parentConversationId
```

Key invariant that was violated: **after the user switches conversations, any
async callbacks from the previous request must not touch `self.messages`,
`ai_state`, `VoiceLoopCoordinator`, or the table view unless they first
confirm `currentConversationEntity?.id` still matches their originating
conversation.**

## Changes Made (this PR)

### 1. Context-correct LLM calls (`contextMessages(for:)`)

Added `storedChatContextMessages(for:)` — rebuilds the LLM message array
from the *persisted store* for a given conversation id. Wrapped by a
convenience `contextMessages(for:)` that uses the fast in-memory path when
the user is still viewing the same conversation, and the store-based path
when they've switched away.

**Call sites fixed:**
- `finishToolBatch` — was using `self.chatContextMessages` which contains the
  wrong conversation after a tab switch.
- `didSendMessageStruct` (function-result → next LLM call) — same issue.
- `didSendMessageText` Apple Intelligence fallback — was re-reading
  `self.chatContextMessages` in the error path.

### 2. Scoped UI state (`ai_state`, `VoiceLoopCoordinator`)

Every location that sets `ai_state` or calls
`VoiceLoopCoordinator.shared.setState(...)` is now guarded by an `isViewing`
check (`currentConversationEntity?.id == requestConversationId`). This
prevents thinking indicators and avatar animations from leaking into the
wrong conversation.

**Locations fixed:**
- `processMessage` — tool-call shimmer, empty-response idle state
- `finishToolBatch` — between-tool thinking state
- `didSendMessageStruct` — function-result thinking state
- `didSendMessageText` — initial response callback `ai_state = .None`

### 3. Correct conversation id on tool calls (`dispatchCall`)

`dispatchCall` now accepts an explicit `conversationId` parameter (captured at
request time by `dispatchAllCalls`). Previously it fell back to
`currentConversationEntity?.id`, which could point to the wrong conversation
if the user switched tabs between the model emitting a tool call and the
dispatch executing. Skills like `SubAgentSkill` read
`call.conversationId` to set `parentConversationId` on spawned agents — a
wrong value here meant the sub-agent's completion summary would post to the
wrong thread.

### 4. Scoped dynamic-skill log handler

`DynamicSkillRegistry.shared.logHandler` now captures the originating
`convId` and only updates `ai_state` + reloads the table when the user is
still viewing that conversation.

## Risks & Limitations

1. **Store-based context is slightly stale.** `storedChatContextMessages`
   reads from the NDJSON files. If a message was appended to `self.messages`
   but not yet flushed to the store (unlikely — `addMessage` writes
   synchronously), the store-based context could miss it. In practice, all
   `addMessage` calls happen before the context is read, so this should not
   be an issue.

2. **Single `MessagingVC` architecture.** iOS runs a single `MessagingVC`
   instance with one `messages` array. The scoping changes here are
   *guardrails* around that single-instance model — they prevent leakage but
   don't eliminate the fundamental tension. A more robust architecture would
   give each conversation its own message controller (or at least its own
   in-memory array), but that's a larger refactor.

3. **VoiceLoopCoordinator is inherently global.** There's one avatar, one
   voice pipeline. If two conversations have concurrent in-flight requests,
   the last one to write wins. This PR prevents writes from *background*
   requests (ones the user has navigated away from), but it doesn't arbitrate
   between two foreground requests (which shouldn't happen in practice on iOS
   since only the visible conversation dispatches).

4. **`ImageGenerationService.shared.host` / `PDFGenerationService.shared.host`**
   are still global singletons pointing at the single `MessagingVC`. If the
   user starts an image generation in conversation A and switches to B, the
   placeholder/ready swap would appear in whichever conversation is visible.
   These are lower-priority since image/PDF generation is relatively rare and
   the result is persisted correctly — it just might not render until the user
   switches back. A follow-up could tag generation requests with a
   conversation id.

## Future Work

- **Per-conversation message controllers**: eliminates the root cause by
  giving each conversation its own in-memory state.
- **Scoped image/PDF host**: tag generation requests with conversation id.
- **Concurrent request arbitration**: if two conversations could both have
  active requests (e.g. background scheduled task + foreground chat), the
  avatar/VoiceLoop state needs a priority model.
- **Mac multi-tab**: the Mac app uses per-tab `MessagingVC` instances, so
  most of these issues don't apply. The `FunctionCallStruct.conversationId`
  fix is still valuable there (the comment block already referenced the Mac
  multi-tab scenario).
