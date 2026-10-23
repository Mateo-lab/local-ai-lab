#!/usr/bin/env bash
# Development workshop with Hermes: local git projects, code → test → review loop, merge by the human.
# Called by `lab dev …` (see docs/agent-development.md).
#
#   dev.sh new NAME [python|node|shell|other]  creates a project (git, AGENTS.md, scripts/check)
#   dev.sh list                                projects, current branch, agent branches to review
#   dev.sh start NAME [MODEL]                  opens Hermes INSIDE the project (the sandbox)
#   dev.sh review NAME [BRANCH]                summary of the agent/* branches; with BRANCH: the full diff
#   dev.sh check NAME [BRANCH]                 runs scripts/check in the sandbox
#   dev.sh pending                             (machine) project<TAB>branch<TAB>commits to review
#   dev.sh merge NAME BRANCH [--yes]           check + merge into main (refuses if the check fails)
#   dev.sh setup                               Hermes settings (sub-agents one at a time) + review skill
#   dev.sh ctx64 [MODEL]                       creates a variant of the model with a 65,536 context for Hermes
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
HDIR="$ROOT/hermes"
DATA="${HERMES_DATA:-$HDIR/data}"
PROJ="$DATA/workspace/projects"
TEMPLATE="$HDIR/dev-template"
BOT_NAME="hermes-agent"; BOT_EMAIL="hermes-agent@aibeast.local"

die() { echo "lab dev: $*" >&2; exit 1; }

valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] || die "invalid name \"$1\" (lower case, digits, - and _, 41 characters max)"; }
valid_branch() { [[ "$1" =~ ^agent/[A-Za-z0-9._-]+$ ]] || die "invalid branch \"$1\" (expected: agent/<topic>)"; }

# --- security: the agent can write in the repository, including .git/. Every git command run HERE (on the host)
# ignores hooks and refuses a repository whose configuration contains anything beyond the bare minimum
# (fsmonitor, aliases, filters, ssh commands… would run on the AI machine, outside the sandbox).
guard() { # guard NAME -> repository safe to handle from the host
  local P="$PROJ/$1"
  [ -d "$P/.git" ] && [ ! -L "$P/.git" ] || die "$1: not a valid git repository (.git missing or a link)"
  local bad
  bad="$(git config --file "$P/.git/config" --list 2>/dev/null | grep -v -E \
    '^(core\.(repositoryformatversion|filemode|bare|logallrefupdates|ignorecase|symlinks|precomposeunicode)|user\.(name|email)|branch\.[A-Za-z0-9._/-]+\.(remote|merge)|init\.defaultbranch)=' || true)"
  [ -z "$bad" ] || die "$1: unexpected git configuration in .git/config (refused for safety):
$bad
Fix it by hand if it is legitimate."
  [ ! -e "$P/.git/hooks" ] || [ -z "$(find "$P/.git/hooks" -type f ! -name '*.sample' 2>/dev/null | head -1)" ] \
    || echo "lab dev: ! hooks exist in $1/.git/hooks: this script ignores them." >&2
}
g() { git -C "$PROJ/$PROJECT" -c core.hooksPath=/dev/null -c core.fsmonitor=false -c protocol.ext.allow=never \
        -c core.pager=cat -c color.ui=never "$@"; }
human_name()  { git config --global user.name  2>/dev/null || echo "$USER"; }
human_email() { git config --global user.email 2>/dev/null || echo "$USER@$(hostname)"; }

need_project() { PROJECT="${1:-}"; [ -n "$PROJECT" ] || die "the project name is missing (lab dev list)"; valid_name "$PROJECT"
  [ -d "$PROJ/$PROJECT" ] || die "unknown project: $PROJECT (lab dev list)"; guard "$PROJECT"; }

# Runs a command INSIDE the sandbox (Hermes container), never on the host.
# LAB_DEV_UNSAFE_LOCAL=1: reserved for this script's automated tests.
in_sandbox() { # in_sandbox NAME command…
  local name="$1"; shift
  if [ "${LAB_DEV_UNSAFE_LOCAL:-}" = 1 ]; then ( cd "$PROJ/$name" && bash -c "$*" ); return; fi
  command -v docker >/dev/null 2>&1 || die "docker not found"
  docker network inspect hermes-net >/dev/null 2>&1 || die "hermes-net network missing: run ./3-demarrer.sh first"
  [ -f "$HDIR/.env" ] || printf 'HERMES_UID=%s\nHERMES_GID=%s\n' "$(id -u)" "$(id -g)" > "$HDIR/.env"
  ( cd "$HDIR" && timeout 900 docker compose run --rm -T --user "$(id -u):$(id -g)" \
      -w "/opt/data/workspace/projects/$name" --entrypoint bash hermes -lc "$*" < /dev/null )   # < /dev/null: the check does not read the keyboard;
  # without it, the command kept waiting after "check: all good" (observed once, exact cause not established)
}

cmd_new() {
  local name="${1:-}" lang="${2:-other}"; valid_name "$name"
  [ "$lang" = autre ] && lang=other   # former French name
  case "$lang" in python|node|shell|other) ;; *) die "unknown language \"$lang\" (python node shell other)";; esac
  [ -d "$TEMPLATE" ] || die "template missing: $TEMPLATE"
  local P="$PROJ/$name"; [ ! -e "$P" ] || die "$name already exists"
  mkdir -p "$PROJ"; cp -r "$TEMPLATE" "$P"
  sed -i "s/__NAME__/$name/g; s/__LANGUAGE__/$lang/g" "$P/AGENTS.md"
  chmod +x "$P/scripts/check"
  git -C "$P" init -q -b main
  git -C "$P" config user.name "$BOT_NAME"; git -C "$P" config user.email "$BOT_EMAIL"
  git -C "$P" -c core.hooksPath=/dev/null add -A
  git -C "$P" -c core.hooksPath=/dev/null commit -q -m "chore: initial structure ($lang)"
  echo "✓ project created: $P"
  echo "  Next step: lab dev start $name   (then describe the feature you want)"
  echo "  Reminder: \`lab dev check $name\` fails as long as there is no test (on purpose)."
}

cmd_list() {
  [ -d "$PROJ" ] || { echo "no project (lab dev new NAME)"; return 0; }
  local d n any=0
  for d in "$PROJ"/*/; do
    n="$(basename "$d")"; [ -d "$d/.git" ] || continue; any=1
    ( PROJECT="$n"; guard "$n" 2>/dev/null || { echo "$n: ! suspicious git configuration (lab dev review $n)"; exit 0; }
      local br dirty ahead
      br="$(g rev-parse --abbrev-ref HEAD 2>/dev/null)"; dirty="$(g status --porcelain 2>/dev/null | wc -l)"
      ahead="$(g for-each-ref --format='%(refname:short)' refs/heads/agent/ 2>/dev/null | while read -r b; do
                 [ "$(g rev-list --count "main..$b" 2>/dev/null)" -gt 0 ] && echo "$b"; done | wc -l)"
      printf '%-24s branch %-26s %s modified file(s)   %s agent branch(es) to review\n' "$n" "$br" "$dirty" "$ahead" )
  done
  [ $any = 1 ] || echo "no project (lab dev new NAME)"
}

# Main model: same rule as `lab main-model` (LAB_MODEL, otherwise `lab config set MODEL`, otherwise the largest installed model,
# never Open WebUI's small task model nor an embedding model; at equal size the -64k variant).
pick_model() { "$ROOT/lab" main-model; }
set_config_model() { # set_config_model MODEL: aligns model.default in the Hermes config
  local cfg="$DATA/config.yaml"
  [ -f "$cfg" ] || return 0
  local cur; cur="$(awk '/^  default:/{print $2; exit}' "$cfg")"
  if [ "$cur" != "$1" ]; then
    cp "$cfg" "$cfg.avant-modele"; sed -i "s|^  default:.*|  default: $1|" "$cfg"
    echo "→ Hermes model: ${cur:-?} → $1 (copy: config.yaml.avant-modele)"
  fi
}

cmd_pending() { # project<TAB>branch<TAB>commits ahead (one line per agent/* branch to review); for the Windows menu
  [ -d "$PROJ" ] || return 0
  local d n b
  for d in "$PROJ"/*/; do
    n="$(basename "$d")"; [ -d "$d/.git" ] || continue
    [[ "$n" =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] || continue          # names chosen by the agent: only safe names are output
    ( PROJECT="$n"; guard "$n" 2>/dev/null || exit 0
      for b in $(g for-each-ref --format='%(refname:short)' refs/heads/agent/); do
        [[ "$b" =~ ^agent/[A-Za-z0-9._-]+$ ]] || continue
        c="$(g rev-list --count "main..$b" 2>/dev/null)"; [ "${c:-0}" -gt 0 ] && printf '%s\t%s\t%s\n' "$n" "$b" "$c"
      done )
  done
  return 0
}

cmd_names() { # safe project names, one per line (for the Windows menu)
  [ -d "$PROJ" ] || return 0
  local d n
  for d in "$PROJ"/*/; do n="$(basename "$d")"; [ -d "$d/.git" ] && [[ "$n" =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] && echo "$n"; done
  return 0
}

cmd_start() {
  need_project "${1:-}"; shift || true
  local model="${1:-}"
  [ -n "$model" ] || model="$(pick_model)"
  [ -n "$model" ] || die "model not found: lab dev start $PROJECT MODEL_NAME (models: lab models)"
  docker exec ollama ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$model" || die "model \"$model\" not found in Ollama (lab models)"
  set_config_model "$model"
  echo "Project $PROJECT — model $model — branch $(g rev-parse --abbrev-ref HEAD)"
  HERMES_WORKDIR="/opt/data/workspace/projects/$PROJECT" exec "$ROOT/5-hermes.sh" "$model"
}

clean() { tr -d '\000-\010\013-\037\177'; }   # keeps \t and \n: removes escape sequences coming from the agent

cmd_review() {
  need_project "${1:-}"; local br="${2:-}"
  if [ -n "$br" ]; then
    valid_branch "$br"; g rev-parse --verify -q "refs/heads/$br" >/dev/null || die "unknown branch: $br"
    echo "=== $br: commits"; g log --oneline "main..$br" | clean
    echo; echo "=== files"; g diff --stat "main...$br" | clean
    local rv; rv="$(g show "$br:docs/reviews/${br#agent/}.md" 2>/dev/null || true)"
    [ -n "$rv" ] && { echo; echo "=== agent report (docs/reviews/${br#agent/}.md) — read it with suspicion, the agent wrote it"; echo "$rv" | clean; }
    echo; echo "=== full diff: lab dev review $PROJECT $br --diff"; [ "${3:-}" = "--diff" ] && g diff "main...$br" | clean
    return 0
  fi
  local b any=0
  for b in $(g for-each-ref --format='%(refname:short)' refs/heads/agent/); do
    any=1; printf '%-34s %s commit(s) ahead of main\n' "$b" "$(g rev-list --count "main..$b")"
  done
  [ $any = 1 ] || echo "no agent/* branch in $PROJECT"
  local dirty; dirty="$(g status --porcelain | wc -l)"; [ "$dirty" -eq 0 ] || echo "! $dirty uncommitted file(s) in the working folder (the agent may have a task in progress)"
  [ -e "$PROJ/$PROJECT/BLOCKED.md" ] && echo "! BLOCKED.md present: the agent stopped (cat $PROJ/$PROJECT/BLOCKED.md)"
  return 0
}

require_clean() { [ -z "$(g status --porcelain)" ] || die "$PROJECT: some files are not committed. Let the agent finish (or discard them yourself) before continuing."; }

cmd_check() {
  need_project "${1:-}"; local br="${2:-}"
  if [ -n "$br" ]; then valid_branch "$br"; require_clean; g switch -q "$br" || die "cannot switch to $br"; fi
  echo "Check of $PROJECT on branch $(g rev-parse --abbrev-ref HEAD) (in the sandbox)…"
  in_sandbox "$PROJECT" './scripts/check'
}

cmd_merge() {
  need_project "${1:-}"; local br="${2:-}" yes=0; [ "${3:-}" = "--yes" ] && yes=1
  valid_branch "$br"; g rev-parse --verify -q "refs/heads/$br" >/dev/null || die "unknown branch: $br"
  require_clean
  [ "$(g rev-list --count "main..$br")" -gt 0 ] || die "$br has no commit ahead of main"
  g merge-base --is-ancestor main "$br" || echo "! $br is not based on the current main: a conflict is possible."
  g switch -q "$br" || die "cannot switch to $br"
  if ! in_sandbox "$PROJECT" './scripts/check'; then
    echo; echo "✗ check failed: nothing is merged. You are still on $br; ask the agent to fix it (lab dev start $PROJECT)."; exit 1
  fi
  echo; g diff --stat "main...$br"
  if [ $yes = 0 ]; then
    read -r -p "Merge $br into main? Have you reviewed the diff (lab dev review $PROJECT $br --diff)? [y/N] " a
    case "$a" in y|Y|yes|o|O|oui) ;; *) echo "cancelled (you are on $br)"; exit 1;; esac
  fi
  g switch -q main || die "cannot go back to main"
  if ! g -c user.name="$(human_name)" -c user.email="$(human_email)" merge --no-ff -q -m "merge: $br" "$br"; then
    g merge --abort 2>/dev/null; die "conflict: merge aborted, main is unchanged."
  fi
  g branch -d "$br" >/dev/null 2>&1 || true
  echo "✓ $br merged into main ($(g rev-parse --short HEAD))."
}

cmd_setup() {
  local cfg="$DATA/config.yaml"
  [ -f "$cfg" ] || die "$cfg missing: run ./5-hermes.sh MODEL once first"
  if grep -q '^delegation:' "$cfg"; then echo "= delegation block already present in $cfg (unchanged)"
  else
    cp "$cfg" "$cfg.avant-dev"
    cat >> "$cfg" <<'EOF'

# Added by `lab dev setup`: sub-agents one at a time (Ollama handles one request at a time, measured).
delegation:
  max_concurrent_children: 1
  max_spawn_depth: 1
  max_iterations: 60
EOF
    echo "✓ delegation block added to $cfg (copy: config.yaml.avant-dev)"
  fi
  if ( cd "$HDIR" && docker compose run --rm hermes skills list 2>/dev/null | grep -q subagent-driven-development ); then
    echo "= subagent-driven-development skill already installed"
  else
    echo "→ installing the two-pass review skill (confirm if Hermes asks)"
    ( cd "$HDIR" && docker compose run --rm hermes skills install official/software-development/subagent-driven-development )
  fi
  echo "Then check: lab dev start NAME, then ask Hermes to list its skills."
}

cmd_ctx64() {
  local base="${1:-}"
  [ -n "$base" ] || { base="$(pick_model)"; base="${base%-64k}"; }
  [ -n "$base" ] || die "model not found: lab dev ctx64 MODEL_NAME"
  local variant="${base}-64k"
  printf 'FROM %s\nPARAMETER num_ctx 65536\n' "$base" | docker exec -i ollama sh -c 'cat > /tmp/Modelfile.64k' || die "cannot write the Modelfile"
  docker exec ollama ollama create "$variant" -f /tmp/Modelfile.64k || die "cannot create $variant"
  echo "Base model: $base → variant: $variant"
  set_config_model "$variant"
  echo "Check with: lab dev start NAME, one sentence, /exit, then \"docker exec ollama ollama ps\": the CONTEXT column must show 65536."
}

c="${1:-help}"; shift || true
case "$c" in
  new) cmd_new "$@" ;; list) cmd_list ;; start) cmd_start "$@" ;; review) cmd_review "$@" ;;
  check) cmd_check "$@" ;; pending) cmd_pending ;; names) cmd_names ;; pick-model) pick_model "$@" ;; merge) cmd_merge "$@" ;; setup) cmd_setup ;; ctx64) cmd_ctx64 "$@" ;;
  help|-h|--help|"") sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) echo "lab dev: unknown command \"$c\"" >&2; exit 1 ;;
esac
