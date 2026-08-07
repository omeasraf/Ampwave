#!/bin/bash
#
# Generates Ampwave/Services/LastFM/LastFMSecrets.swift from .env.
#
# The generated file is gitignored — Last.fm credentials must not be committed.
# Run this after cloning, or whenever .env changes:
#
#   ./Scripts/generate-lastfm-secrets.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env"
OUT="$ROOT/Ampwave/Services/LastFM/LastFMSecrets.swift"

API_KEY=""
SHARED_SECRET=""

if [ -f "$ENV_FILE" ]; then
  API_KEY="$(grep -E '^LAST_FM_API_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '\r\n' || true)"
  SHARED_SECRET="$(grep -E '^LAST_FM_SHARED_SECRET=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '\r\n' || true)"
else
  echo "warning: $ENV_FILE not found — generating empty credentials (Last.fm will be disabled)" >&2
fi

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<EOF
//
//  LastFMSecrets.swift
//  Ampwave
//
//  GENERATED FILE — DO NOT EDIT, DO NOT COMMIT.
//  Regenerate with ./Scripts/generate-lastfm-secrets.sh
//

// The project builds with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so these
// are explicitly nonisolated — LastFMClient is an actor and reads them off the
// main actor, which would otherwise be an error under Swift 6.
enum LastFMSecrets {
  nonisolated static let apiKey = "$API_KEY"
  nonisolated static let sharedSecret = "$SHARED_SECRET"

  /// False when credentials are absent, so the UI can disable the feature
  /// instead of failing every request.
  nonisolated static var isConfigured: Bool { !apiKey.isEmpty && !sharedSecret.isEmpty }
}
EOF

echo "Wrote $OUT"
