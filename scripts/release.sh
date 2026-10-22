#!/usr/bin/env bash
# Produit l'archive de livraison depuis le dépôt git (fichiers commités uniquement).
#   scripts/release.sh [SORTIE]      défaut : ~/ai-lab.tar.gz
# L'archive contient le dossier ai-lab/ (comme l'attend windows/outils/Deployer-sur-AiBeast.ps1).
# Exclut automatiquement .git, les .env, lab.conf et tout ce qui est ignoré ou non commité.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$HOME/ai-lab.tar.gz}"
cd "$ROOT"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "release : $ROOT n'est pas un dépôt git" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "release : modifications non commitées, commite-les d'abord (git status)" >&2; exit 1; }
git archive --format=tar.gz --prefix=ai-lab/ -o "$OUT" HEAD
bad="$(tar tzf "$OUT" | grep -iE '(^|/)\.env$|client_secret|\.pem$|\.key$|/\.git/|(^|/)lab\.conf$' || true)"
if [ -n "$bad" ]; then echo "release : fichier sensible dans l'archive, archive supprimée :" >&2; echo "$bad" >&2; rm -f "$OUT"; exit 2; fi
echo "Archive : $OUT"
echo "  $(stat -c %s "$OUT") octets, $(tar tzf "$OUT" | grep -vc '/$') fichiers, version $(git rev-parse --short HEAD)"
