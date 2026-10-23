#!/usr/bin/env bash
# Builds the delivery archive from the git repository (committed files only).
#   scripts/release.sh [OUTPUT]      default: ~/ai-lab.tar.gz
# The archive contains the ai-lab/ folder (as windows/outils/Deployer-sur-AiBeast.ps1 expects).
# Automatically excludes .git, the .env files, lab.conf and everything ignored or uncommitted.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$HOME/ai-lab.tar.gz}"
cd "$ROOT"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "release: $ROOT is not a git repository" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "release: uncommitted changes, commit them first (git status)" >&2; exit 1; }
git archive --format=tar.gz --prefix=ai-lab/ -o "$OUT" HEAD
bad="$(tar tzf "$OUT" | grep -iE '(^|/)\.env$|client_secret|\.pem$|\.key$|/\.git/|(^|/)lab\.conf$' || true)"
if [ -n "$bad" ]; then echo "release: sensitive file in the archive, archive deleted:" >&2; echo "$bad" >&2; rm -f "$OUT"; exit 2; fi
echo "Archive: $OUT"
echo "  $(stat -c %s "$OUT") bytes, $(tar tzf "$OUT" | grep -vc '/$') files, version $(git rev-parse --short HEAD)"
