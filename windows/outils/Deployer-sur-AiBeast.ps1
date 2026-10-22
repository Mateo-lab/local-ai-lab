# Livraison d'une nouvelle version du lab sur AiBeast : envoie ai-lab.tar.gz, vérifie, sauvegarde ce qui va être
# remplacé, extrait, contrôle. Utilisation : double-clic sur Deployer-sur-AiBeast.bat (VPN connecté, clé SSH chargée).
#
# - Envoie l'archive par scp vers ~/ai-lab.tar.gz sur AiBeast et compare la taille avec celle du PC.
# - REFUSE de continuer si un banc d'essai (lab bench) tourne : remplacer des fichiers pendant une mesure peut la fausser.
# - Sauvegarde bench, docs, windows, scripts et lab (sans bench/.venv ni bench/results, jamais livres) dans ~/avant-AAAAMMJJ-HHMM.tgz avant d'extraire.
# - Extrait dans ~/Documents (l'archive ajoute et remplace des fichiers, elle n'en supprime pas ; les .env ne sont pas dedans).
# - Contrôle après coup : compare chaque fichier de l'archive avec ce qui est sur disque (contenu, taille, date ; le
#   propriétaire est ignoré : tar ne peut pas le changer sans être root).
param(
    [string]$Archive = (Join-Path $PSScriptRoot "..\..\ai-lab.tar.gz"),   # par défaut : à côté du dossier windows\
    [string]$Hote = "aibeast"
)
$ErrorActionPreference = "Stop"
function Fin($msg, $code) { Write-Host $msg; Read-Host "Appuie sur Entrée pour fermer"; exit $code }

if (-not (Test-Path $Archive)) { Fin "Archive introuvable : $Archive" 1 }
$taille = (Get-Item $Archive).Length
Write-Host "Archive : $Archive ($taille octets)"

Write-Host "Envoi vers AiBeast..."
& scp -o ClearAllForwardings=yes $Archive "${Hote}:ai-lab.tar.gz"
if ($LASTEXITCODE -ne 0) { Fin "L'envoi a échoué (VPN ? clé SSH ? voir : ssh $Hote). Rien n'a été modifié sur AiBeast." 1 }

# Script exécuté sur AiBeast (ASCII seulement : il passe par l'entrée standard de ssh)
$distant = @'
set -u
ARCH="$HOME/ai-lab.tar.gz"
DEST="$HOME/Documents"
got=$(stat -c %s "$ARCH" 2>/dev/null || echo 0)
if [ "$got" != "__TAILLE__" ]; then echo "Taille recue: $got au lieu de __TAILLE__"; exit 11; fi
echo "  taille verifiee: $got octets"
if pgrep -f "[l]abbench" >/dev/null || pgrep -f "[7]-bench.sh" >/dev/null; then
  echo "Un banc d'essai tourne (lab bench). Attends sa fin puis relance. Rien n'a ete extrait."; exit 10
fi
if ! tar tzf "$ARCH" >/dev/null 2>&1; then echo "Archive illisible (corrompue ?). Rien n'a ete extrait."; exit 12; fi
cd "$DEST" || { echo "Dossier $DEST introuvable"; exit 14; }
if [ -d ai-lab/.git ] && [ -n "$(git -C ai-lab status --porcelain 2>/dev/null)" ]; then echo "Le depot git ai-lab a des modifications non commitees (cd ~/Documents/ai-lab ; git status). Commite-les d'abord. Rien n'a ete extrait."; exit 15; fi
L=""
for p in ai-lab/bench ai-lab/docs ai-lab/windows ai-lab/scripts ai-lab/lab; do [ -e "$p" ] && L="$L $p"; done
B="$HOME/avant-$(date +%Y%m%d-%H%M).tgz"
if [ -n "$L" ]; then
  tar czf "$B" --exclude=ai-lab/bench/.venv --exclude=ai-lab/bench/results --exclude=__pycache__ $L 2>/dev/null || { echo "Sauvegarde de securite impossible. Rien n'a ete extrait."; exit 13; }
  echo "  sauvegarde de securite: $B ($(stat -c %s "$B") octets)"
fi
tar xzf "$ARCH" -C "$DEST" 2>"$HOME/.deploiement-erreurs.txt"; rc=$?
diff_out=$(LANGUAGE=C LC_ALL=C tar dzf "$ARCH" -C "$DEST" 2>&1 | grep -v -i -E "Uid differs|Gid differs|UID est diff|GID est diff" | head -20)
if [ $rc -ne 0 ] || [ -n "$diff_out" ]; then
  echo "Extraction avec problemes (code $rc). Premieres erreurs:"; head -10 "$HOME/.deploiement-erreurs.txt"
  echo "Fichiers differents de l'archive:"; echo "$diff_out"
  exit 20
fi
echo "  extraction verifiee: tous les fichiers de l'archive sont identiques sur le disque"
if [ -d ai-lab/.git ]; then echo "  changements apportes par l'archive (git status) :"; git -C ai-lab status --short | head -40; echo "  Verifie puis commite (cd ~/Documents/ai-lab ; git add -A ; git commit), ou annule (git checkout -- .)"; fi
exit 0
'@
$distant = ($distant -replace "`r", "").Replace("__TAILLE__", "$taille")

Write-Host "Contrôle et extraction sur AiBeast..."
$distant | & ssh -o ClearAllForwardings=yes $Hote "bash -s"
$code = $LASTEXITCODE
switch ($code) {
    0  { Fin "OK : nouvelle version en place sur AiBeast. Pour revenir en arrière : la sauvegarde ~/avant-....tgz (voir ci-dessus)." 0 }
    10 { Fin "Un banc d'essai tourne : rien n'a été extrait. Relance quand il est fini." 10 }
    11 { Fin "La taille reçue ne correspond pas : rien n'a été extrait. Relance." 11 }
    12 { Fin "L'archive est illisible : rien n'a été extrait." 12 }
    13 { Fin "Sauvegarde de sécurité impossible : rien n'a été extrait." 13 }
    15 { Fin "Le dépôt git d'AiBeast a des modifications non commitées : rien n'a été extrait. Commite-les ou annule-les, puis relance." 15 }
    20 { Fin "Extraction faite mais avec des différences ou des erreurs (voir ci-dessus). Ne lance pas de mesure avant de les avoir regardées." 20 }
    default { Fin "Échec (code $code). Voir les messages ci-dessus." $code }
}
