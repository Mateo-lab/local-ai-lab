#!/usr/bin/env bash
# Test automatique de scripts/dev.sh (logique git, garde-fous, fusion). N'utilise ni Docker ni Hermes :
# le « bac à sable » est remplacé par une exécution locale dans un dossier temporaire (LAB_DEV_UNSAFE_LOCAL=1).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HERMES_DATA="$T/data" LAB_DEV_UNSAFE_LOCAL=1 GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = Humain\n\temail = humain@example.org\n' > "$GIT_CONFIG_GLOBAL"
DEV="$HERE/dev.sh"; P="$HERMES_DATA/workspace/projects"
fails=0
ok()  { echo "OK   $1"; }
ko()  { echo "ÉCHEC $1"; fails=$((fails+1)); }
expect_ok()   { local n="$1"; shift; if "$@" >"$T/out" 2>&1; then ok "$n"; else ko "$n"; sed 's/^/     /' "$T/out"; fi; }
expect_fail() { local n="$1"; shift; if "$@" >"$T/out" 2>&1; then ko "$n (aurait dû échouer)"; sed 's/^/     /' "$T/out"; else ok "$n"; fi; }
agent() { git -C "$P/$1" -c core.hooksPath=/dev/null "${@:2}"; }

expect_ok   "new crée le projet" "$DEV" new demo python
[ -f "$P/demo/AGENTS.md" ] && grep -q 'demo' "$P/demo/AGENTS.md" && ! grep -q '__NOM__' "$P/demo/AGENTS.md" && ok "AGENTS.md personnalisé" || ko "AGENTS.md personnalisé"
expect_fail "nom invalide refusé"  "$DEV" new "../evil" python
expect_fail "langage inconnu refusé" "$DEV" new autre2 cobol
expect_fail "projet existant refusé" "$DEV" new demo python
expect_fail "check sans test échoue (voulu)" "$DEV" check demo

# branche de l'agent : un module + un test qui passe
agent demo switch -q -c agent/addition
printf 'def add(a, b):\n    return a + b\n' > "$P/demo/calc.py"
printf 'import os\nimport sys\nsys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))\nfrom calc import add\nimport unittest\n\n\nclass T(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(add(1, 2), 3)\n' > "$P/demo/tests/test_calc.py"
mkdir -p "$P/demo/docs/reviews"; printf '# compte rendu\nTout est bon.\n' > "$P/demo/docs/reviews/addition.md"
agent demo add -A; agent demo -c user.name=bot -c user.email=b@x commit -q -m "feat: addition"
expect_ok   "review liste la branche"  "$DEV" review demo
out_rv="$("$DEV" review demo 2>&1)"; grep -q 'agent/addition' <<<"$out_rv" && ok "review mentionne agent/addition" || ko "review mentionne agent/addition"
out_rv="$("$DEV" review demo agent/addition 2>&1)"; grep -q 'compte rendu' <<<"$out_rv" && ok "review affiche le compte rendu" || ko "review affiche le compte rendu"
expect_ok   "check sur la branche passe" "$DEV" check demo agent/addition
expect_ok   "list fonctionne" "$DEV" list
expect_ok   "merge --yes fusionne" "$DEV" merge demo agent/addition --yes
[ -f "$P/demo/calc.py" ] && [ "$(agent demo rev-parse --abbrev-ref HEAD)" = main ] && ok "main contient le code et est la branche courante" || ko "main contient le code"
agent demo rev-parse --verify -q refs/heads/agent/addition >/dev/null && ko "branche supprimée après fusion" || ok "branche supprimée après fusion"
[ "$(agent demo log -1 --format=%an)" = "Humain" ] && ok "fusion signée par l'humain" || ko "fusion signée par l'humain"

# branche dont le test échoue : refus, main inchangé
agent demo switch -q -c agent/casse
printf 'import unittest\n\n\nclass F(unittest.TestCase):\n    def test_faux(self):\n        self.assertEqual(1, 2)\n' > "$P/demo/tests/test_faux.py"
agent demo add -A; agent demo -c user.name=bot -c user.email=b@x commit -q -m "test: faux"
before="$(agent demo rev-parse main)"
expect_fail "merge refusé si le check échoue" "$DEV" merge demo agent/casse --yes
[ "$(agent demo rev-parse main)" = "$before" ] && ok "main inchangé après refus" || ko "main inchangé après refus"

# fichiers non commités : refus
agent demo switch -q main; echo x > "$P/demo/brouillon.txt"
expect_fail "merge refusé avec arbre sale" "$DEV" merge demo agent/casse --yes
rm "$P/demo/brouillon.txt"

# garde-fous : configuration git piégée et hook
agent demo switch -q main
git -C "$P/demo" config core.fsmonitor "touch $T/PWNED"
expect_fail "configuration git piégée refusée" "$DEV" review demo
[ ! -e "$T/PWNED" ] && ok "la commande piégée n'a pas été exécutée" || ko "la commande piégée a été exécutée"
git -C "$P/demo" config --unset core.fsmonitor
agent demo switch -q -c agent/hook; echo y > "$P/demo/hook.txt"; agent demo add -A
git -C "$P/demo" -c core.hooksPath=/dev/null -c user.name=b -c user.email=b@x commit -q -m "feat: hook"
printf '#!/bin/sh\ntouch %s/HOOK\n' "$T" > "$P/demo/.git/hooks/post-merge"; chmod +x "$P/demo/.git/hooks/post-merge"
printf '#!/bin/sh\ntouch %s/HOOK2\n' "$T" > "$P/demo/.git/hooks/pre-commit"; chmod +x "$P/demo/.git/hooks/pre-commit"
"$DEV" merge demo agent/hook --yes >"$T/out" 2>&1
[ ! -e "$T/HOOK" ] && [ ! -e "$T/HOOK2" ] && ok "hooks ignorés" || ko "hooks exécutés"

[ "$("$DEV" pending | awk -F'\t' '$2=="agent/casse"{print $1":"$3}')" = "demo:1" ] && ok "pending liste projet, branche et commits" || ko "pending"

# noms hostiles : ni la liste (pending) ni le menu ne doivent les propager
agent demo switch -q main; agent demo branch 'agent/x;touch-pwned'; agent demo branch 'agent/$(id)'
agent demo switch -q 'agent/x;touch-pwned'; echo z > "$P/demo/z.txt"; agent demo add -A; agent demo -c user.name=b -c user.email=b@x commit -q -m "feat: z"
agent demo switch -q main
out_rv="$("$DEV" pending)"; grep -q -E 'touch|\$\(' <<<"$out_rv" && ko "pending propage un nom de branche hostile" || ok "pending écarte les noms de branche hostiles"
mkdir -p "$P/Mauvais Nom"; git -C "$P/Mauvais Nom" init -q
out_rv="$("$DEV" pending)"; grep -q 'Mauvais' <<<"$out_rv" && ko "pending propage un nom de projet hostile" || ok "pending écarte les noms de projet hostiles"
# texte de l'agent : les séquences d'échappement sont retirées de la revue
agent demo switch -q -c agent/esc; mkdir -p "$P/demo/docs/reviews"; printf 'ok \033[31mROUGE\033]0;titre\007 fin\n' > "$P/demo/docs/reviews/esc.md"
agent demo add -A; agent demo -c user.name=b -c user.email=b@x commit -q -m "docs: esc"; agent demo switch -q main
out_rv="$("$DEV" review demo agent/esc 2>&1)"; grep -q $'\033' <<<"$out_rv" && ko "la revue laisse passer ESC" || ok "la revue retire les séquences d'échappement"

# .git remplacé par un lien : refus
mkdir -p "$P/lien"; ln -s "$P/demo/.git" "$P/lien/.git"
expect_fail ".git en lien refusé" "$DEV" review lien

# choix du modèle : le plus gros, jamais le petit modèle de tâches ni un modèle d'embeddings ; la variante -64k gagne à taille égale
mkdir -p "$T/bin"; cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf 'NAME ID SIZE MODIFIED\n'
printf 'qwen2.5:1.5b abc 1.7 GB 2 days ago\n'
printf 'nomic-embed-text:latest abc 274 MB 3 days ago\n'
printf 'qwen3.8:27b abc 17 GB 3 days ago\n'
[ -n "${WITH64:-}" ] && printf 'qwen3.8:27b-64k abc 17 GB 1 minute ago\n'
printf 'tiny:1b abc 900 MB 1 day ago\n'
STUB
chmod +x "$T/bin/docker"
[ "$(PATH="$T/bin:$PATH" "$DEV" pick-model)" = "qwen3.8:27b" ] && ok "pick-model : le plus gros (pas qwen2.5:1.5b)" || ko "pick-model : le plus gros"
[ "$(WITH64=1 PATH="$T/bin:$PATH" "$DEV" pick-model)" = "qwen3.8:27b-64k" ] && ok "pick-model : la variante -64k gagne à taille égale" || ko "pick-model : variante -64k"
[ "$(LAB_MODEL=autre:7b PATH="$T/bin:$PATH" "$DEV" pick-model)" = "autre:7b" ] && ok "pick-model : LAB_MODEL prioritaire" || ko "pick-model : LAB_MODEL"

# lab config / main-model (copie de `lab` dans un dossier temporaire : .lab/ y est isolé)
mkdir -p "$T/root/ai-stack"; cp "$HERE/../lab" "$T/root/lab"
printf 'OWUI_TASK_MODEL=qwen2.5:1.5b\n' > "$T/root/ai-stack/.env"
mkdir -p "$T/bin2"; cat > "$T/bin2/docker" <<'STUB'
#!/usr/bin/env bash
printf 'NAME ID SIZE MODIFIED\n'
printf 'qwen2.5:1.5b abc 17 GB 2 days ago\n'
printf 'qwen3.8:27b abc 17 GB 3 days ago\n'
printf 'gros-embed:latest abc 40 GB 3 days ago\n'
STUB
chmod +x "$T/bin2/docker"
L() { PATH="$T/bin2:$PATH" "$T/root/lab" "$@"; }
[ "$(L main-model)" = "qwen3.8:27b" ] && ok "main-model ignore le modèle de tâches et les embeddings" || ko "main-model par défaut"
expect_ok   "config set MODEL" L config set MODEL qwen3.8:27b
[ "$(L main-model)" = "qwen3.8:27b" ] && [ "$(L config get MODEL)" = "qwen3.8:27b" ] && ok "config get / main-model lisent le réglage" || ko "config get"
expect_fail "config set modèle inconnu refusé" L config set MODEL n-existe-pas
expect_fail "config set clé inconnue refusée" L config set AUTRE x
[ "$(LAB_MODEL=autre:7b L main-model)" = "autre:7b" ] && ok "LAB_MODEL prioritaire sur le réglage" || ko "LAB_MODEL"
expect_ok   "config unset" L config unset MODEL
[ -z "$(L config get MODEL)" ] && ok "réglage retiré" || ko "réglage retiré"
expect_fail "lab tmux action inconnue refusée" L tmux nimporte

echo; [ $fails -eq 0 ] && echo "Tous les tests de dev.sh passent." || { echo "$fails échec(s)."; exit 1; }
