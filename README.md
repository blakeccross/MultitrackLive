# Multitrack Live

Universal SwiftUI proof-of-concept for live multitrack stem playback on macOS and iPadOS.

## Features

- Import multiple stem files per song (`.wav`, `.aiff`, `.mp3`, `.m4a`)
- **Edit** view: trim tracks, arrange sections, and adjust mix settings
- **Edit** view: non-destructive trim in/out points with preview
- **Setlists**: order songs and play them sequentially for live use

## Open in Xcode

```bash
open MultitrackLive.xcodeproj
```

Select the **My Mac** or **iPad** simulator destination and run.

## Workflow

1. **Songs** → New Song → import stems
2. Open a song to trim tracks and edit the arrangement
3. **Setlists** → New Setlist → add songs in order
4. **Play Setlist** for live playback with next/previous controls

## Architecture

- SwiftData for song/setlist metadata
- `AVAudioEngine` + `AVAudioPlayerNode` for synced multitrack playback
- Audio files stored in `Documents/Songs/<song-id>/`
