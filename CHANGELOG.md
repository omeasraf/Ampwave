# Ampwave — What's New v1.0.0 (Build 23)

## Latest Update

### Player

- **Cover Art Accent** — A new setting tints the player background and controls card with the dominant color extracted from the current song's artwork. Works in both full-artwork and standard layouts.
- **Player Card** — Renamed from "Player Glass Background". The controls panel is now a floating frosted card that can be toggled on or off.
- **Full Artwork Background** — When disabled, the Cover Art Accent tint is applied to the scroll area only, keeping the navigation bar clean and uncluttered.
- Removed the radio button from the player utility bar, which was causing the controls to overflow and push the layout off-screen on smaller devices.

### Word-Synced Lyrics

- **Auto-fetch** — When Word-Synced Lyrics is enabled, Ampwave now automatically upgrades existing line-synced lyrics to word-synced in the background when a song starts playing.
- **Spacing fixed** — Words now render with correct inter-word spacing in both the compact and expanded lyrics views.
- **No more run-on lines** — Phrases embedded as a single word-offset entry by some providers are now split into individual words so they display with proper spacing.
- **Performance** — Rewrote the lyrics rendering pipeline so only the currently active word view re-renders on each timer tick (10×/sec). The full line list now only updates when the current lyric line changes (once every few seconds), eliminating the main source of scroll lag.
- **Apple Music–style animations** — Words now smoothly animate from dim to bright as they become active, with a gentle spring transition. The current word gets a subtle scale pulse. Line changes fade and scale in and out.
- **Credits** — Added Binimum Lyrics API and LyricsPlus to Data Sources in Settings.

### Library & Imports

- **Folder import no longer blocks subsequent imports** — A load-guard bug caused the library to skip UI refresh after the first folder import. Every import batch now forces a fresh reload.
- **Album grouping** — Albums are now grouped using the Album Artist tag (TPE2 for MP3, aART for M4A) as the primary key, matching how Apple Music and Spotify handle multi-artist albums. Songs with featured artists (e.g. "NF; mgk") correctly group with the primary artist's album rather than creating a separate entry.
- **Compilation support** — Albums with the Compilation flag (TCMP/cpil) are grouped under "Various Artists" regardless of individual track artists.
- **Case-insensitive grouping** — Album and artist names are normalised before comparison, preventing the same album from being split by capitalisation differences.
- **Featured artist extraction** — When no Album Artist tag is present, Ampwave extracts the primary artist from compound strings ("Artist feat. Guest" → "Artist") to prevent album fragmentation.

### Onboarding

- **App icon** — The welcome page now shows the real Ampwave app icon instead of a generic SF Symbol.
- **Theme selector** — A new page lets you choose your theme during onboarding. Your choice applies immediately throughout the app.
- **Settings saved** — Choices made in onboarding (gapless playback, metadata, lyrics, theme) are now applied to your existing preferences immediately on completion, so Settings reflects them right away.
- **Color scheme fix** — Selecting a dark theme during onboarding now correctly switches the interface to dark mode immediately, without requiring an app restart.
- **Re-open from Settings** — "View Setup Guide" in Settings → About reopens the full onboarding flow at any time.
- **Reset Library** — Resetting your library now presents the onboarding screen so you can reconfigure your preferences for a fresh start.

### Appearance

- **Visual theme selector** — The Theme picker in Settings → Appearance is now a visual grid showing each theme's colors, matching the onboarding experience. Tap any swatch to apply it instantly.
- **Dark theme text colors** — Nord Dark, Everforest Dark, and Kanagawa Wave themes now correctly force dark-mode text colors regardless of the iOS system light/dark setting.
- **Album cards** — Fixed album cards in search results and artist pages being squished with text overlapping the artwork. Cards now display at a consistent fixed width.
- **Artist cards** — Fixed the image overlapping the artist name due to a padding/overlay conflict. Proper spacing is restored between the circle image and the name.
- **Grid alignment** — Album names are now single-line with ellipsis so artwork aligns horizontally across all cards in a grid row.

### Bug Fixes

- **Library reset** — Completely rewrote the reset logic. Songs, albums, artists, playlists, and synced lyrics are now properly deleted in the correct dependency order. Stats (listening history, play counts) are preserved. The disk scan cache is cleared so the next launch performs a clean index.
- **Artists not deleted on reset** — Artists were previously omitted from the reset operation, leaving ghost data in the library and search views.
- **Import file picker** — Importing songs or folders after a previous import session now works correctly. The single `.fileImporter` binding previously cleared the import-mode state before the result handler ran, silently dropping all selected files.
- **Siri** — "Play [song] on Ampwave" now correctly prompts "What song would you like to play?" instead of the confusing "What's the query?" message.
- **Metadata auto-fetch on restart** — Songs whose metadata fetch was interrupted (app killed mid-import) are now re-queued on the next launch and fetched automatically when online.
- **Word-synced lyrics credits** — Added Binimum Lyrics API, LyricsPlus, and Apple MusicKit to the Data Sources section in Settings.
