# Device log verification

Use a development build on the affected device with its existing library.

Startup diagnostics now distinguish the initial `maintenance=false` library
load from deferred maintenance and the lightweight sonic-analysis index query.
Each reports elapsed seconds. The initial load must finish before any analysis
backfill, and the tabs should appear before deferred maintenance begins.

Audio activation reports `Activation completed success=... elapsed=...s` before
playback begins. On iOS 27 it uses the asynchronous activation API; the iOS 26
fallback runs on a dedicated serial queue. Check Play followed immediately by
Pause, switching songs during activation, and Reset: a late activation must not
restart audio. Repeat while using Bluetooth and after an interruption.

Player-item logs now report `sourceLease`, meaning an owned source-access lease,
not whether a redundant per-file sandbox-extension consume succeeded. Folder
presenters, scans, and player items share that lease. Backgrounding removes
presenters but must preserve playback access. A `Source requires relinking`
message identifies an unreadable source whose permission cannot be restored;
select that source again in Files rather than falling back to a cached copy.

1. Cold-launch twice. Each launch should have one initial database load. A later
   reload is expected only when imports or index repairs change the library.
   Completed sonic analysis must not resolve audio bookmarks just to check the
   analysis database.
2. With duplicate merging enabled, the first scan after this upgrade may merge
   previously forgotten duplicates once. The next launch must not import and
   delete those same files again. Disabling duplicate merging permits them again.
3. With Copy Imported Songs off, delete the retained source of a merged pair.
   Ampwave must remove that entry; another source still present in a linked
   folder can be imported again. No external audio files should be deleted by
   merging or library reset.
4. Reset the library, background/foreground, and relaunch. Previously linked
   folders must stay unlinked until selected explicitly again.

## Capture the remaining concurrency diagnostic

The supplied log's `unsafeForcedSync` warnings have no backtrace. They occur
near backgrounding, but that timing alone does not identify the responsible
code. Apple DTS notes that this diagnostic can originate inside system code:
[Apple Developer Forums discussion](https://developer.apple.com/forums/thread/802423).

In Xcode, attach to the affected development build and enter this in the debug
console before reproducing the warning (Apple DTS's suggested breakpoint):

```lldb
breakpoint set --shlib libswiftos.dylib --name os_log
continue
```

At the diagnostic stop, capture:

```lldb
thread backtrace all
```

This breakpoint can also stop for unrelated logging. Continue to the relevant
warning and retain the surrounding console output, OS version, and backtrace.
Delete the breakpoint by its returned ID when finished. Do not suppress the
warning or change accessibility settings to make a verification log appear clean.
