# Loop Feed + Cards — v1 Spec

## Overview

A new **Feed tab** in the side drawer surfaces AI-generated visual "cards" the
user can swipe through, keep, or archive. Cards are produced by a new
`generate_card` tool the agent calls during conversation.

## 1. New Tool: `generate_card`

Registered like other Loop tools. Inputs:

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `kind` | `"image"` \| `"markdown"` | yes | Determines renderer |
| `title` | string | yes | Short (≤6 words) |
| `body` | string | yes | Content/subtitle |
| `image_prompt` | string | when kind=image | Vivid image generation prompt |
| `source` | string | no | Attribution |
| `tags` | string[] | no | Lowercase keywords |

Output: a persisted Card (JSON at `workspace://cards/<id>.json`).

## 2. Card Schema

```json
{
  "id": "uuid",
  "kind": "image|markdown",
  "title": "...",
  "body": "...",
  "image_url": "cards/assets/<id>.png",
  "source": "calendar",
  "tags": ["morning", "routine"],
  "created_at": "2026-06-14T05:00:00.000Z",
  "state": "new|kept|archived"
}
```

Image assets: `workspace://cards/assets/<id>.png`

## 3. Pluggable Renderer Interface

`CardRendering` protocol with `render(card:completion:)`.

- **v1 `image` renderer**: pipes `image_prompt` through OpenAI image generation
  at 4:3 landscape (1536×1024).
- **v1 `markdown` renderer**: renders title + body to a 4:3 poster PNG via
  UIKit offscreen render. Dark background, clean typography, Loop-branded.

Future backends (HTML→image, Higgsfield, vectors) conform and register without
changing the tool surface.

## 4. Feed UX (no sidebar tab)

The side drawer stays **Conversations | Files | Skills** — there is *no* Feed
tab. Cards surface in two places instead:

**New-chat swipe stack** (`FeedCardStackView`, shown by `MainVC`):
- On a blank/new chat, the swipe stack *replaces* the hero orb (the orb steps
  back to the nav bar). When the deck empties, the orb returns to the hero slot.
- Tinder-style: drag the top card, swipe **right → Keep**, **left → Archive**,
  **tap → detail**. Cards behind peek out and rise as the top card flies off.
- The deck is dealt from `CardStore.feedCards` (`new` before `kept`, newest
  first); `archived` excluded. A fresh deck is dealt each new chat.

**Card detail** (`CardDetailViewController`): full poster, title, body,
metadata, Keep / Archive buttons. Presented modally (Done button) from the pill
or the stack; pushed when navigated.

## 5. Pill Alert

When `generate_card` completes mid-conversation, a lightweight pill appears:
"✨ new card". It **persists until tapped** (no auto-dismiss); multiple cards
stack downward. Tapping opens that card's **detail view**.

## 6. Out of Scope (v1)

- External sharing/export
- Multi-page/scrolling cards
- Heartbeat-driven proactive card generation

## Key Results

- (A) A new chat with cards opens to the swipe stack (orb in nav bar), not a
  bare input. No Feed tab in the sidebar.
- (B) "Generate a card on my day tomorrow" → markdown card from calendar.
- (C) "Generate a card of teaching Leo loose-leash walking" → image card.
- (D) Swipe to Keep/Archive; kept cards persist + sync via workspace.
- (E) `renderCard` cleanly factored for future kinds.
