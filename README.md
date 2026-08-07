# Ampwave

> **Your music, unlocked.**

Ampwave is a beautiful, modern music player for iOS that puts your music library first. Built with SwiftUI and designed with iOS 26's Liquid Glass aesthetic in mind, Ampwave delivers a premium listening experience while keeping your data private and local.

## Features

- **Beautiful iOS 26 Design** — Liquid Glass floating tab bar and modern UI components
- **Smart Recommendations** — Personalized "For You" suggestions based on your listening history
- **Synced Lyrics** — Karaoke-style lyrics that scroll and highlight in real-time
- **Full Playback Control** — Shuffle, repeat, queue management, and seamless navigation
- **Offline First** — Your music stays on your device. No cloud required.
- **Rich Metadata** — Automatic artwork and metadata enrichment

## Data Sources

Ampwave uses these open-source community databases to enhance your music library with high-quality metadata, artwork, and lyrics:

| Source | Purpose |
|--------|---------|
| [MusicBrainz](https://musicbrainz.org) | Artist, album, and track metadata |
| [Cover Art Archive](https://coverartarchive.org) | High-resolution album artwork |
| [LRCLIB](https://lrclib.net) | Time-synced lyrics |
| [Lyrics.ovh](https://lyrics.ovh) | Plain text lyrics |

## Requirements

- iOS 26.0+
- Xcode 26.0+
- Swift 6.0+

## Building

1. Clone the repository
2. Open `Ampwave.xcodeproj` in Xcode
3. Build and run on your device or simulator

## Privacy

Ampwave is designed with privacy in mind:

- No user data is collected or transmitted
- All metadata requests are anonymous
- Your music library stays local to your device
- No accounts, no tracking, no ads

## Product Direction

Ampwave's opportunity is to become **the music player that understands your
library entirely on your device**. Most offline players already compete on
format support, equalizers, metadata editing, cloud imports, CarPlay, and
listening reports. Ampwave should continue to execute those fundamentals well,
while differentiating itself through private, offline musical intelligence.

Implementation progress is tracked in [Planned Features](PLANNED_FEATURES.md).

### Flagship: Sonic Intelligence

Apple's [Music Understanding framework](https://developer.apple.com/videos/play/wwdc2026/253/)
can analyze key, rhythm, beats, bars, phrases, structure, pace, instrument
activity, and loudness entirely on-device. A cached Sonic Analysis index could
power:

- **Sonic “More Like This”** — Find similar-sounding tracks without relying on
  genres, metadata, an account, or an internet connection.
- **Intelligent Shuffle** — Build sessions that warm up, peak, and cool down
  instead of selecting unrelated tracks randomly.
- **Phrase-Aware Crossfade** — Transition at musical boundaries rather than
  cutting through a vocal line or chorus.
- **Sonic Search** — Find music by qualities such as tempo, instrumentation,
  energy, key, or song shape.
- **Library Map** — Explore clusters of energetic, acoustic, dark, bright,
  vocal, or instrumental music.
- **Set Builder** — Create a mix for a target duration and energy arc, such as
  a workout, drive, focus session, or wind-down.

### Sing & Practice Studio

The Vocal Slider can grow into a broader practice environment for singers,
musicians, dancers, and language learners:

- Loop a detected verse, chorus, phrase, or custom range.
- Slow playback without changing pitch.
- Transpose a song into the listener's range.
- Display BPM, key, beats, and structural markers.
- Save practice settings per song.
- Expand stem controls beyond vocals when reliable native or local models are
  available.

Apple's [`AVAudioUnitTimePitch`](https://developer.apple.com/documentation/avfaudio/avaudiounittimepitch)
provides native independent pitch and playback-rate processing.

### Flow Mode

Flow Mode would act as an offline personal DJ using Sonic Analysis and local
listening history. It should sequence compatible keys, tempos, and energy
levels; avoid repetitive artist ordering; understand intros and endings; and
transition at phrase boundaries. Possible intents include “Keep the energy
rising,” “Late-night drive,” and “Ease me into focus.”

### Acoustic Library Doctor

Extend library maintenance beyond tag comparison:

- Detect the same recording under different filenames or metadata.
- Distinguish remasters, edits, live recordings, and compilation copies.
- Flag truncated, corrupted, or unexpectedly low-quality files.
- Identify incomplete albums.
- Recommend which duplicate to keep while preserving playlist references.

[ShazamKit](https://developer.apple.com/shazamkit/) can generate audio
signatures and match custom catalogs locally, providing a native foundation
for exact recording identification.

### Accountless Device Sync

Allow Ampwave on iPhone, iPad, and Mac to synchronize directly over the local
network without an Ampwave account or hosted server. Syncable data could
include tracks, playlists, play counts, ratings, history, lyrics, metadata,
settings, and playback position. Transfers should be resumable, encrypted, and
user-controlled.

### Music Memory

Turn local listening history into rediscovery rather than just statistics:

- Forgotten favorites and albums that have not been revisited recently.
- “First played” and “On this day” memories.
- Monthly, seasonal, and yearly listening stories.
- Personal notes and timestamped memories attached to songs or albums.
- Shareable cards generated without uploading listening history.

### Beat-Reactive Visuals and Haptics

Use beat, pace, structure, loudness, and instrument activity to drive visuals
that meaningfully follow the song. Ampwave should also support Apple's
[Music Haptics](https://developer.apple.com/documentation/mediaaccessibility/music-haptics)
for recognized tracks as an accessibility feature.

### Suggested Roadmap

1. Build and cache the on-device Sonic Analysis index.
2. Ship Sonic “More Like This,” BPM/key filters, and sound-based recommendations.
3. Add Flow Mode with intelligent sequencing and phrase-aware transitions.
4. Expand the Vocal Slider into Sing & Practice Studio.
5. Add direct, accountless device sync.

## License

Ampwave is released under the MIT License.

## Acknowledgments

Special thanks to the open-source communities behind MusicBrainz, Cover Art Archive, LRCLIB, and Lyrics.ovh for providing the data that makes Ampwave possible.
