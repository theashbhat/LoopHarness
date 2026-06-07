# Music Mini-Player Banner

## Overview

Convert the existing top banner area in the chat view (currently used for running-agent indicators) into a horizontally scrollable collection view. Add a music mini-player item that appears when music is actively playing via the Apple Music integration.

## States

### Minimized (Pill)
A compact horizontal pill showing small album art, track title, artist, and a play/pause icon. Tap to expand.

### Expanded (Card)
A larger square/rounded card with bigger album art, full track info, progress/scrubber, and full controls (play/pause, skip, minimize chevron). Expands inline or as an overlay within the chat view.

## Gestures

- Swipe down on expanded card → collapse to minimized pill
- Swipe away or tap dismiss → hide entirely
- Tap on minimized pill → expand to card

## Data Integration

Wire up to the existing music status system (`get_music_status` / `MusicController.shared.status()`) to feed current track info, artwork, and playback state. Reflect changes from Control Center.

## Controls

- Play/Pause/Skip commands back through `MusicController`
- Tap track/art to deep-link to Apple Music

## Visibility Logic

- Only show when music is playing or paused within last 5 minutes
- Auto-dismiss on stop
- Auto-minimize when voice recording begins
- Persist across conversation tabs if music is still playing

## Design

Feel like iOS Live Activity or Spotify mini-player — glanceable, ambient, lightweight. Should visually complement existing agent indicator pills.

## Key Results

- (A) Music pill appears in top banner alongside running-agent indicators when playing
- (B) Tap expands to full card with controls without leaving chat
- (C) Swipe down collapses back to pill; swipe away dismisses
- (D) Banner area scrolls horizontally when multiple agents + music coexist
- (E) Auto-hides on stop; auto-minimizes on voice record
