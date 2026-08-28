# Ampwave Planned Features

Ampwave's product direction is to make owned music feel more personal,
intelligent, durable, and shareable without requiring an account or internet
connection.

## Available Today

- [x] Import music by copying files into Ampwave or referencing folders in
  Files, with optional live folder monitoring.
- [x] Read embedded metadata and artwork, refresh missing metadata in bulk, and
  optionally enrich the library from online sources.
- [x] Import and export playlists, including M3U and M3U8 playlists, and create
  rule-based smart playlists.
- [x] Play FLAC and other locally supported formats with queue management,
  shuffle, repeat, gapless playback, crossfade, ReplayGain normalization,
  AirPlay, a sleep timer, and reusable queue presets.
- [x] Display plain, line-synced, and word-synced lyrics with offline caching
  and manual online refresh.
- [x] Generate private recommendations and personal radio mixes from local
  metadata, favorites, ratings, listening history, and skip behavior.
- [x] Customize themes, player presentation, library layouts, widgets, and
  playback behavior.
- [x] Support CarPlay, Apple Watch syncing, and Siri/Shortcuts playback intents.
- [x] Export and restore library metadata, playlists, listening statistics,
  preferences, and playback state.
- [x] Keep shareable, rotating session logs for playback troubleshooting.

Sound-based recommendations complement the existing metadata and listening
history engine with a private, cached analysis of the audio signal itself.

## In Progress

- [ ] **Ampwave Capsules** — Create modern offline mixtapes with a title,
  artwork, personal message, intentional song order, and portable sharing.
  - [x] Define the local Capsule data model.
  - [x] Define the versioned `.ampcap` compressed package format.
  - [x] Create Capsules from existing playlists.
  - [x] Save and browse Capsules locally.
  - [x] Play a Capsule in its authored order.
  - [x] Share and import self-contained Capsules without an account.
  - [x] Edit Capsule details, messages, track order, and included songs.
  - [x] Convert a Capsule into a standard playlist.
  - [ ] Add custom Capsule artwork.
  - [ ] Add per-track notes and voice introductions.
  - [ ] Add authored transition settings.
  - [x] Bundle the Capsule manifest and audio files in one compressed archive.
  - [ ] Add export size estimates and clear user-owned-audio confirmation.
  - [ ] Add nearby, accountless delivery and a polished recipient experience.

## High Priority

- [ ] **Album Editions** — Group originals, remasters, deluxe editions, live
  recordings, and duplicate releases.
  - [ ] Add synchronized, loudness-matched A/B playback.
  - [ ] Let listeners choose a preferred edition without deleting alternatives.
- [ ] **Library Time Machine** — Preserve file health, metadata revisions,
  artwork changes, and playlist membership.
  - [x] Export and restore the current library metadata, playlists, listening
    statistics, settings, and playback state.
  - [ ] Undo library cleanup and bulk metadata operations.
  - [ ] Restore playlist references when files move or are replaced.
- [ ] **Perfect-Fit Queue** — Build a session for an exact amount of available
  time with a chosen energy curve and a natural ending.
- [ ] **Nearby Listening Room** — Let nearby Ampwave users suggest songs, vote,
  and manage a shared queue without accounts or internet.
- [ ] **Output Memory** — Remember normalization, EQ, balance, and other playback
  preferences independently for headphones, cars, speakers, and USB DACs.

## Sonic Intelligence

- [x] Build and cache a private, on-device sonic analysis index as songs are
  imported, with automatic backfill for existing libraries.
- [ ] **Song DNA** — Turn the private analysis into an attractive, explainable
  profile for each song.
  - [x] Store loudness, dynamics, zero-crossing activity, brightness, crest
    factor, and stereo width in the on-device analysis database.
  - [ ] Expand analysis with BPM, musical key and mode, energy, danceability,
    acoustic/electronic character, and vocal/instrumental estimates.
  - [ ] Add a polished Song DNA view with friendly descriptions such as Warm,
    Energetic, Wide Stereo, and Highly Dynamic, alongside exact measurements
    only where confidence is high.
  - [ ] Supplement local analysis with Apple Music genre, release, composer,
    Lossless, and Dolby Atmos metadata when a catalog match is available.
- [x] **Sound-based More Like This** — Recommend tracks using similarities in
  the audio itself instead of relying only on artist, album, genre, or history.
  - [x] Extract a compact on-device feature vector for each supported song.
  - [x] Cache analysis by file identity so unchanged songs are never re-scanned.
  - [x] Rank acoustically similar tracks while respecting dislikes and library
    availability.
  - [x] Add a More Like This player section that starts a sound-matched queue
    from the recommendation the listener chooses.
  - [x] Show sound-matched recommendations for playlists with explicit add
    controls.
  - [x] Fall back to the existing private metadata/history radio when a track
    cannot be analyzed.
- [ ] Add intelligent shuffle with warm-up, peak, and cool-down arcs.
- [ ] Add phrase-aware crossfades and transitions.
- [ ] Add search and filtering by tempo, key, energy, instrumentation, and song
  structure.
- [ ] Add a visual map of related music in the local library.
- [ ] Add Flow Mode, an offline personal DJ that sequences compatible songs.
- [ ] Add an optional, clearly labeled Apple Music discovery shelf using
  MusicKit personal recommendations for authorized subscribers, without
  replacing Ampwave's offline recommendations or implying catalog tracks are
  already part of the local library.

## Listening and Practice

- [ ] Expand Vocal Slider into **Sing & Practice Studio**.
  - [x] Ship the current Vocal Slider and remember its playback state.
  - [ ] Loop a detected section, phrase, or custom time range.
  - [ ] Change tempo without changing pitch.
  - [ ] Transpose into the listener's vocal or instrumental range.
  - [ ] Display BPM, key, beats, and song structure.
  - [ ] Save practice settings per song.
  - [ ] Add additional stem controls when local separation is reliable.
- [ ] **Musician's A/B Lab** — Compare recordings with synchronized seeking,
  automatic loudness matching, loops, and blind preference tests.
- [ ] **Concept Album Mode** — Preserve gapless sequences, multi-disc structure,
  movements, liner notes, and intentional album flow.
  - [x] Preserve disc and track-number ordering from embedded metadata.
  - [x] Support gapless album playback.
  - [x] Display reusable expandable album and artist descriptions.
  - [ ] Model movements and authored album-level playback behavior.
- [ ] **Offline Voice Library** — Support natural playback requests through Siri,
  Spotlight, Shortcuts, and on-device library search.
  - [x] Add Siri and Shortcuts playback intents.
  - [ ] Add Spotlight indexing and broader natural-language library requests.

## Ownership and Reliability

- [ ] **Acoustic Library Doctor** — Detect duplicate recordings, distinguish
  editions, find corrupt files, and identify incomplete albums.
- [ ] **Travel Guarantee** — Verify that every song, lyric, artwork asset, and
  analysis result in a trip playlist is truly available offline.
- [ ] **Remaster Inspector** — Explain codec, bit depth, sample rate, dynamic
  range, clipping, ReplayGain, and suspicious upsampling in plain language.
- [ ] **Accountless Device Sync** — Synchronize music and personal library data
  directly between iPhone, iPad, Mac, and Apple Watch.
- [ ] **Private Taste Controls** — Give listeners explicit, explainable control
  over local recommendations and sequencing.

## Personal and Accessible Listening

- [ ] **Music Memory** — Surface forgotten favorites, anniversaries, listening
  stories, notes, and timestamped memories without uploading history.
- [ ] **Beat-Reactive Visuals and Haptics** — Drive visuals and supported haptics
  from musical structure, rhythm, energy, and instrument activity.
- [ ] **Listening Safety** — Estimate exposure, offer an optional safe-volume
  ceiling, and prevent unexpected loudness jumps.

## Interface and Customization

- [x] **Customizable Home** — Let listeners hide the greeting card and choose
  which Home shelves appear and in what order.
- [ ] **Customizable Library Tabs** — Let listeners choose which sections appear
  in the Library picker and in what order, so a library browsed by album and
  artist isn't fronted by sections its owner never opens.
  - [ ] Persist the chosen set and order.
  - [ ] Provide an edit sheet with reordering and per-section visibility.
  - [ ] Keep at least one section enabled, and fall back gracefully when the
    remembered section has since been hidden.
  - [ ] Decide whether the root tab bar (Home, Library, Playlists, Settings,
    Search) should be customizable too.
- [ ] **Consistent Artist Artwork Shape** — Show artists as circles everywhere
  and albums as squares, so the two are distinguishable at a glance.
  - [ ] Audit every surface that renders an artist image — search results,
    context menus, Home shelves, and CarPlay — since the Library grid is
    already circular but other surfaces may not be.
