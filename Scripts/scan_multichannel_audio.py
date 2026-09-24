#!/usr/bin/env python3
"""Find audio files with more than two channels without changing any files.

Requires ffprobe (part of FFmpeg). By default, scans ~/Downloads/Songs.
Usage: python3 scripts/scan_multichannel_audio.py [directory] [--workers 8]
"""

import argparse
import concurrent.futures
import json
import shutil
import subprocess
import sys
from pathlib import Path


AUDIO_EXTENSIONS = {
    ".aac", ".ac3", ".aif", ".aifc", ".aiff", ".alac", ".ape",
    ".caf", ".dff", ".dsf", ".eac3", ".flac", ".m4a", ".m4b",
    ".mka", ".mkv", ".mp3", ".mp4", ".oga", ".ogg", ".opus",
    ".wav", ".wma", ".wv",
}


def inspect(path: Path, ffprobe: str) -> tuple[Path, list[dict], str | None]:
    command = [
        ffprobe, "-v", "error", "-select_streams", "a",
        "-show_entries", "stream=index,codec_name,channels,channel_layout",
        "-of", "json", str(path),
    ]
    try:
        completed = subprocess.run(
            command, capture_output=True, text=True, timeout=20, check=False
        )
        if completed.returncode:
            return path, [], completed.stderr.strip() or "ffprobe failed"
        streams = json.loads(completed.stdout).get("streams", [])
        if not streams:
            return path, [], "no audio stream found"
        return path, streams, None
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
        return path, [], str(error)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "directory", nargs="?", type=Path,
        default=Path.home() / "Downloads" / "Songs",
        help="directory to scan recursively (default: ~/Downloads/Songs)",
    )
    parser.add_argument("--workers", type=int, default=8)
    args = parser.parse_args()

    root = args.directory.expanduser().resolve()
    ffprobe = shutil.which("ffprobe")
    if not root.is_dir():
        parser.error(f"not a directory: {root}")
    if ffprobe is None:
        parser.error("ffprobe not found; install FFmpeg and retry")
    if not 1 <= args.workers <= 16:
        parser.error("--workers must be between 1 and 16")

    files = sorted(
        path for path in root.rglob("*")
        if path.is_file() and path.suffix.lower() in AUDIO_EXTENSIONS
        and not path.name.startswith("._")
    )
    if not files:
        print(f"No recognized audio files found in {root}")
        return 0

    results: list[tuple[Path, list[dict], str | None]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(inspect, path, ffprobe) for path in files]
        for completed_count, future in enumerate(
            concurrent.futures.as_completed(futures), start=1
        ):
            results.append(future.result())
            if completed_count % 100 == 0:
                print(f"Inspected {completed_count}/{len(files)} files...", file=sys.stderr)

    multichannel = []
    ordinary = 0
    unknown = []
    errors = []
    for path, streams, error in sorted(results, key=lambda result: result[0]):
        if error:
            errors.append((path, error))
            continue
        qualifying = [stream for stream in streams if (stream.get("channels") or 0) > 2]
        if qualifying:
            multichannel.append((path, qualifying))
        elif any(stream.get("channels") for stream in streams):
            ordinary += 1
        else:
            unknown.append(path)

    print(f"Scanned {len(files)} audio files in {root}")
    print(f"Multichannel (>2 channels): {len(multichannel)}")
    print(f"Mono/stereo: {ordinary}")
    print(f"Channel count unknown: {len(unknown)}")
    print(f"Could not inspect: {len(errors)}")
    for path, streams in multichannel:
        for stream in streams:
            channels = stream["channels"]
            layout = stream.get("channel_layout") or "layout unknown"
            codec = stream.get("codec_name") or "codec unknown"
            print(f"  {channels}ch | {layout} | {codec} | {path.relative_to(root)}")
    for path in unknown:
        print(f"  UNKNOWN | {path.relative_to(root)}")
    for path, error in errors:
        print(f"  ERROR | {path.relative_to(root)} | {error}")
    return 1 if errors or unknown else 0


if __name__ == "__main__":
    raise SystemExit(main())
