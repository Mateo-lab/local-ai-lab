#!/usr/bin/env bash
# Atelier de développement avec Hermes : projets git locaux, boucle code → test → review, fusion par l'humain.
# Appelé par `lab dev …` (voir docs/agent-development.md).
#
#   dev.sh new NOM [python|node|shell|autre]   crée un projet (git, AGENTS.md, scripts/check)
#   dev.sh list                                projets, branche courante, branches de l'agent à relire
#   dev.sh start NOM [MODELE]                  ouvre Hermes DANS le projet (le bac à sable)
#   dev.sh review NOM [BRANCHE]                résumé des branches agent/* ; avec BRANCHE : le diff complet
#   dev.sh check NOM [BRANCHE]                 lance scripts/check dans le bac à sable
#   dev.sh pending                             (machine) projet<TAB>branche<TAB>commits à relire
#   dev.sh merge NOM BRANCHE [--yes]           check + fusion dans main (refuse si le check échoue)
#   dev.sh setup                               réglages Hermes (sous-agents un par un) + compétence de revue
#   dev.sh ctx64 [MODELE]                      crée une variante du modèle avec 65 536 de contexte pour Hermes
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
HDIR="$ROOT/hermes"
DATA="${HERMES_DATA:-$HDIR/data}"
PROJ="$DATA/workspace/projects"
TEMPLATE="$HDIR/dev-template"
BOT_NAME="hermes-agent"; BOT_EMAIL="hermes-agent@aibeast.local"

die() { echo "lab dev : $*" >&2; exit 1; }

valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] || die "nom invalide « $1 » (minuscules, chiffres, - et _, 41 caractères max)"; }
valid_branch() { [[ "$1" =~ ^agent/[A-Za-z0-9._-]+$ ]] || die "branche invalide « $1 » (attendu : agent/<sujet>)"; }

# --- sécurité : l'agent peut écrire dans le dépôt, y compris .git/. Toute commande git lancée ICI (sur l'hôte)
# ignore les hooks et refuse un dépôt dont la configuration contient autre chose que le strict nécessaire
# (fsmonitor, alias, filtres, commandes ssh… s'exécuteraient sur AiBeast, hors du bac à sable).
guard() { # guard NOM -> dépôt sûr à manipuler depuis l'hôte
  local P="$PROJ/$1"
  [ -d "$P/.git" ] && [ ! -L "$P/.git" ] || die "$1 : pas un dépôt git valide (.git absent ou lien)"
  local bad
  bad="$(git config --file "$P/.git/config" --list 2>/dev/null | grep -v -E \
    '^(core\.(repositoryformatversion|filemode|bare|logallrefupdates|ignorecase|symlinks|precomposeunicode)|user\.(name|email)|branch\.[A-Za-z0-9._/-]+\.(remote|merge)|init\.defaultbranch)=' || true)"
  [ -z "$bad" ] || die "$1 : configuration git inattendue dans .git/config (refus par sécurité) :
$bad
Corrige-la à la main si elle est légitime."
  [ ! -e "$P/.git/hooks" ] || [ -z "$(find "$P/.git/hooks" -type f ! -name '*.sample' 2>/dev/null | head -1)" ] \
    || echo "lab dev : ! des hooks existent dans $1/.git/hooks : ils sont ignorés par ce script." >&2
}
g() { git -C "$PROJ/$PROJECT" -c core.hooksPath=/dev/null -c core.fsmonitor=false -c protocol.ext.allow=never \
        -c core.pager=cat -c color.ui=never "$@"; }
human_name()  { git config --global user.name  2>/dev/null || echo "$USER"; }
human_email() { git config --global user.email 2>/dev/null || echo "$USER@$(hostname)"; }

need_project() { PROJECT="${1:-}"; [ -n "$PROJECT" ] || die "il manque le nom du projet (lab dev list)"; valid_name "$PROJECT"
  [ -d "$PROJ/$PROJECT" ] || die "projet inconnu : $PROJECT (lab dev list)"; guard "$PROJECT"; }

# Exécute une commande DANS le bac à sable (conteneur Hermes), jamais sur l'hôte.
# LAB_DEV_UNSAFE_LOCAL=1 : réservé aux tests automatiques de ce script.
in_sandbox() { # in_sandbox NOM commande…
  local name="$1"; shift
  if [ "${LAB_DEV_UNSAFE_LOCAL:-}" = 1 ]; then ( cd "$PROJ/$name" && bash -c "$*" ); return; fi
  command -v docker >/dev/null 2>&1 || die "docker introuvable"
  docker network inspect hermes-net >/dev/null 2>&1 || die "réseau hermes-net absent : lance d'abord ./3-demarrer.sh"
  [ -f "$HDIR/.env" ] || printf 'HERMES_UID=%s\nHERMES_GID=%s\n' "$(id -u)" "$(id -g)" > "$HDIR/.env"
  ( cd "$HDIR" && timeout 900 docker compose run --rm -T --user "$(id -u):$(id -g)" \
      -w "/opt/data/workspace/projects/$name" --entrypoint bash hermes -lc "$*" < /dev/null )   # < /dev/null : le check ne lit pas le clavier ;
  # sans cela, la commande restait en attente après « check : tout est bon » (observé le 2026-10-19, cause exacte non établie)
}

cmd_new() {
  local name="${1:-}" lang="${2:-autre}"; valid_name "$name"
  case "$lang" in python|node|shell|autre) ;; *) die "langage « $lang » inconnu (python node shell autre)";; esac
  [ -d "$TEMPLATE" ] || die "modèle absent : $TEMPLATE"
  local P="$PROJ/$name"; [ ! -e "$P" ] || die "$name existe déjà"
  mkdir -p "$PROJ"; cp -r "$TEMPLATE" "$P"
  sed -i "s/__NOM__/$name/g; s/__LANGAGE__/$lang/g" "$P/AGENTS.md"
  chmod +x "$P/scripts/check"
  git -C "$P" init -q -b main
  git -C "$P" config user.name "$BOT_NAME"; git -C "$P" config user.email "$BOT_EMAIL"
  git -C "$P" -c core.hooksPath=/dev/null add -A
  git -C "$P" -c core.hooksPath=/dev/null commit -q -m "chore: structure initiale ($lang)"
  echo "✓ projet créé : $P"
  echo "  Étape suivante : lab dev start $name   (puis décris la fonctionnalité voulue)"
  echo "  Rappel : \`lab dev check $name\` échoue tant qu'il n'y a aucun test (voulu)."
}

cmd_list() {
  [ -d "$PROJ" ] || { echo "aucun projet (lab dev new NOM)"; return 0; }
  local d n any=0
  for d in "$PROJ"/*/; do
    n="$(basename "$d")"; [ -d "$d/.git" ] || continue; any=1
    ( PROJECT="$n"; guard "$n" 2>/dev/null || { echo "$n : ! configuration git suspecte (lab dev review $n)"; exit 0; }
      local br dirty ahead
      br="$(g rev-parse --abbrev-ref HEAD 2>/dev/null)"; dirty="$(g status --porcelain 2>/dev/null | wc -l)"
      ahead="$(g for-each-ref --format='%(refname:short)' refs/heads/agent/ 2>/dev/null | while read -r b; do
                 [ "$(g rev-list --count "main..$b" 2>/dev/null)" -gt 0 ] && echo "$b"; done | wc -l)"
      printf '%-24s branche %-26s %s fichier(s) modifié(s)   %s branche(s) agent à relire\n' "$n" "$br" "$dirty" "$ahead" )
  done
  [ $any = 1 ] || echo "aucun projet (lab dev new NOM)"
}

# Modèle principal : même règle que `lab main-model` (LAB_MODEL, sinon `lab config set MODEL`, sinon le plus gros modèle installé,
# jamais le petit modèle de tâches d'Open WebUI ni un modèle d'embeddings ; à taille égale la variante -64k).
pick_model() { "$ROOT/lab" main-model; }
set_config_model() { # set_config_model MODELE : aligne model.default de la config Hermes
  local cfg="$DATA/config.yaml"
  [ -f "$cfg" ] || return 0
  local cur; cur="$(awk '/^  default:/{print $2; exit}' "$cfg")"
  if [ "$cur" != "$1" ]; then
    cp "$cfg" "$cfg.avant-modele"; sed -i "s|^  default:.*|  default: $1|" "$cfg"
    echo "→ modèle de Hermes : ${cur:-?} → $1 (copie : config.yaml.avant-modele)"
  fi
}

cmd_pending() { # projet<TAB>branche<TAB>commits en avance (une ligne par branche agent/* à relire) ; pour le menu Windows
  [ -d "$PROJ" ] || return 0
  local d n b
  for d in "$PROJ"/*/; do
    n="$(basename "$d")"; [ -d "$d/.git" ] || continue
    [[ "$n" =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] || continue          # noms choisis par l'agent : seuls les noms sûrs sont émis
    ( PROJECT="$n"; guard "$n" 2>/dev/null || exit 0
      for b in $(g for-each-ref --format='%(refname:short)' refs/heads/agent/); do
        [[ "$b" =~ ^agent/[A-Za-z0-9._-]+$ ]] || continue
        c="$(g rev-list --count "main..$b" 2>/dev/null)"; [ "${c:-0}" -gt 0 ] && printf '%s\t%s\t%s\n' "$n" "$b" "$c"
      done )
  done
  return 0
}

cmd_names() { # noms de projets sûrs, un par ligne (pour le menu Windows)
  [ -d "$PROJ" ] || return 0
  local d n
  for d in "$PROJ"/*/; do n="$(basename "$d")"; [ -d "$d/.git" ] && [[ "$n" =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] && echo "$n"; done
  return 0
}

cmd_start() {
  need_project "${1:-}"; shift || true
  local model="${1:-}"
  [ -n "$model" ] || model="$(pick_model)"
  [ -n "$model" ] || die "modèle introuvable : lab dev start $PROJECT NOM_DU_MODELE (modèles : lab models)"
  docker exec ollama ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$model" || die "modèle « $model » absent d'Ollama (lab models)"
  set_config_model "$model"
  echo "Projet $PROJECT — modèle $model — branche $(g rev-parse --abbrev-ref HEAD)"
  HERMES_WORKDIR="/opt/data/workspace/projects/$PROJECT" exec "$ROOT/5-hermes.sh" "$model"
}

clean() { tr -d '\000-\010\013-\037\177'; }   # garde \t et \n : retire les séquences d'échappement venues de l'agent

cmd_review() {
  need_project "${1:-}"; local br="${2:-}"
  if [ -n "$br" ]; then
    valid_branch "$br"; g rev-parse --verify -q "refs/heads/$br" >/dev/null || die "branche inconnue : $br"
    echo "=== $br : commits"; g log --oneline "main..$br" | clean
    echo; echo "=== fichiers"; g diff --stat "main...$br" | clean
    local rv; rv="$(g show "$br:docs/reviews/${br#agent/}.md" 2>/dev/null || true)"
    [ -n "$rv" ] && { echo; echo "=== compte rendu de l'agent (docs/reviews/${br#agent/}.md) — à lire avec méfiance, c'est l'agent qui l'écrit"; echo "$rv" | clean; }
    echo; echo "=== diff complet : lab dev review $PROJECT $br --diff"; [ "${3:-}" = "--diff" ] && g diff "main...$br" | clean
    return 0
  fi
  local b any=0
  for b in $(g for-each-ref --format='%(refname:short)' refs/heads/agent/); do
    any=1; printf '%-34s %s commit(s) en avance sur main\n' "$b" "$(g rev-list --count "main..$b")"
  done
  [ $any = 1 ] || echo "aucune branche agent/* dans $PROJECT"
  local dirty; dirty="$(g status --porcelain | wc -l)"; [ "$dirty" -eq 0 ] || echo "! $dirty fichier(s) non commités dans le dossier de travail (l'agent a peut-être une tâche en cours)"
  [ -e "$PROJ/$PROJECT/BLOCKED.md" ] && echo "! BLOCKED.md présent : l'agent s'est arrêté (cat $PROJ/$PROJECT/BLOCKED.md)"
  return 0
}

require_clean() { [ -z "$(g status --porcelain)" ] || die "$PROJECT : des fichiers ne sont pas commités. Laisse l'agent finir (ou jette-les toi-même) avant de continuer."; }

cmd_check() {
  need_project "${1:-}"; local br="${2:-}"
  if [ -n "$br" ]; then valid_branch "$br"; require_clean; g switch -q "$br" || die "impossible de passer sur $br"; fi
  echo "Check de $PROJECT sur la branche $(g rev-parse --abbrev-ref HEAD) (dans le bac à sable)…"
  in_sandbox "$PROJECT" './scripts/check'
}

cmd_merge() {
  need_project "${1:-}"; local br="${2:-}" yes=0; [ "${3:-}" = "--yes" ] && yes=1
  valid_branch "$br"; g rev-parse --verify -q "refs/heads/$br" >/dev/null || die "branche inconnue : $br"
  require_clean
  [ "$(g rev-list --count "main..$br")" -gt 0 ] || die "$br n'a aucun commit en avance sur main"
  g merge-base --is-ancestor main "$br" || echo "! $br n'est pas basée sur le main actuel : un conflit est possible."
  g switch -q "$br" || die "impossible de passer sur $br"
  if ! in_sandbox "$PROJECT" './scripts/check'; then
    echo; echo "✗ check en échec : rien n'est fusionné. Tu es resté sur $br ; demande à l'agent de corriger (lab dev start $PROJECT)."; exit 1
  fi
  echo; g diff --stat "main...$br"
  if [ $yes = 0 ]; then
    read -r -p "Fusionner $br dans main ? Tu as relu le diff (lab dev review $PROJECT $br --diff) ? [o/N] " a
    case "$a" in o|O|oui|y|Y) ;; *) echo "annulé (tu es sur $br)"; exit 1;; esac
  fi
  g switch -q main || die "impossible de revenir sur main"
  if ! g -c user.name="$(human_name)" -c user.email="$(human_email)" merge --no-ff -q -m "merge: $br" "$br"; then
    g merge --abort 2>/dev/null; die "conflit : fusion annulée, main est inchangé."
  fi
  g branch -d "$br" >/dev/null 2>&1 || true
  echo "✓ $br fusionnée dans main ($(g rev-parse --short HEAD))."
}

cmd_setup() {
  local cfg="$DATA/config.yaml"
  [ -f "$cfg" ] || die "$cfg absent : lance d'abord ./5-hermes.sh MODELE une fois"
  if grep -q '^delegation:' "$cfg"; then echo "= bloc delegation déjà présent dans $cfg (non modifié)"
  else
    cp "$cfg" "$cfg.avant-dev"
    cat >> "$cfg" <<'EOF'

# Ajouté par `lab dev setup` : sous-agents un par un (Ollama ne traite qu'une requête à la fois, mesuré le 2026-10-19).
delegation:
  max_concurrent_children: 1
  max_spawn_depth: 1
  max_iterations: 60
EOF
    echo "✓ bloc delegation ajouté à $cfg (copie : config.yaml.avant-dev)"
  fi
  if ( cd "$HDIR" && docker compose run --rm hermes skills list 2>/dev/null | grep -q subagent-driven-development ); then
    echo "= compétence subagent-driven-development déjà installée"
  else
    echo "→ installation de la compétence de relecture en deux passes (confirme si Hermes le demande)"
    ( cd "$HDIR" && docker compose run --rm hermes skills install official/software-development/subagent-driven-development )
  fi
  echo "Vérifie ensuite : lab dev start NOM, puis demande à Hermes de lister ses compétences."
}

cmd_ctx64() {
  local base="${1:-}"
  [ -n "$base" ] || { base="$(pick_model)"; base="${base%-64k}"; }
  [ -n "$base" ] || die "modèle introuvable : lab dev ctx64 NOM_DU_MODELE"
  local variant="${base}-64k"
  printf 'FROM %s\nPARAMETER num_ctx 65536\n' "$base" | docker exec -i ollama sh -c 'cat > /tmp/Modelfile.64k' || die "écriture du Modelfile impossible"
  docker exec ollama ollama create "$variant" -f /tmp/Modelfile.64k || die "création de $variant impossible"
  echo "Modèle de base : $base → variante : $variant"
  set_config_model "$variant"
  echo "Vérifie avec : lab dev start NOM, une phrase, /exit, puis « docker exec ollama ollama ps » : la colonne CONTEXT doit afficher 65536."
}

c="${1:-help}"; shift || true
case "$c" in
  new) cmd_new "$@" ;; list) cmd_list ;; start) cmd_start "$@" ;; review) cmd_review "$@" ;;
  check) cmd_check "$@" ;; pending) cmd_pending ;; names) cmd_names ;; pick-model) pick_model "$@" ;; merge) cmd_merge "$@" ;; setup) cmd_setup ;; ctx64) cmd_ctx64 "$@" ;;
  help|-h|--help|"") sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) echo "lab dev : commande inconnue « $c »" >&2; exit 1 ;;
esac
