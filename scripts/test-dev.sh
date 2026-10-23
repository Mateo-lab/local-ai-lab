#!/usr/bin/env bash
# Automated test of scripts/dev.sh (git logic, safeguards, merge). Uses neither Docker nor Hermes:
# the "sandbox" is replaced by a local run in a temporary folder (LAB_DEV_UNSAFE_LOCAL=1).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HERMES_DATA="$T/data" LAB_DEV_UNSAFE_LOCAL=1 GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = Human\n\temail = human@example.org\n' > "$GIT_CONFIG_GLOBAL"
DEV="$HERE/dev.sh"; P="$HERMES_DATA/workspace/projects"
fails=0
ok()  { echo "OK     $1"; }
ko()  { echo "FAILED $1"; fails=$((fails+1)); }
expect_ok()   { local n="$1"; shift; if "$@" >"$T/out" 2>&1; then ok "$n"; else ko "$n"; sed 's/^/     /' "$T/out"; fi; }
expect_fail() { local n="$1"; shift; if "$@" >"$T/out" 2>&1; then ko "$n (should have failed)"; sed 's/^/     /' "$T/out"; else ok "$n"; fi; }
agent() { git -C "$P/$1" -c core.hooksPath=/dev/null "${@:2}"; }

expect_ok   "new creates the project" "$DEV" new demo python
[ -f "$P/demo/AGENTS.md" ] && grep -q 'demo' "$P/demo/AGENTS.md" && ! grep -q '__NAME__\|__LANGUAGE__' "$P/demo/AGENTS.md" && ok "AGENTS.md customised" || ko "AGENTS.md customised"
expect_fail "invalid name refused"  "$DEV" new "../evil" python
expect_fail "unknown language refused" "$DEV" new other2 cobol
expect_ok   "former French type 'autre' still accepted" "$DEV" new legacy autre
grep -q 'main language: other' "$P/legacy/AGENTS.md" && ok "'autre' is stored as 'other'" || ko "'autre' mapping"
expect_fail "existing project refused" "$DEV" new demo python
expect_fail "check without tests fails (on purpose)" "$DEV" check demo

# agent branch: a module + a passing test
agent demo switch -q -c agent/addition
printf 'def add(a, b):\n    return a + b\n' > "$P/demo/calc.py"
printf 'import os\nimport sys\nsys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))\nfrom calc import add\nimport unittest\n\n\nclass T(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(add(1, 2), 3)\n' > "$P/demo/tests/test_calc.py"
mkdir -p "$P/demo/docs/reviews"; printf '# review report\nAll good.\n' > "$P/demo/docs/reviews/addition.md"
agent demo add -A; agent demo -c user.name=bot -c user.email=b@x commit -q -m "feat: addition"
expect_ok   "review lists the branch"  "$DEV" review demo
out_rv="$("$DEV" review demo 2>&1)"; grep -q 'agent/addition' <<<"$out_rv" && ok "review mentions agent/addition" || ko "review mentions agent/addition"
out_rv="$("$DEV" review demo agent/addition 2>&1)"; grep -q 'review report' <<<"$out_rv" && ok "review shows the agent's report" || ko "review shows the agent's report"
expect_ok   "check on the branch passes" "$DEV" check demo agent/addition
expect_ok   "list works" "$DEV" list
expect_ok   "merge --yes merges" "$DEV" merge demo agent/addition --yes
[ -f "$P/demo/calc.py" ] && [ "$(agent demo rev-parse --abbrev-ref HEAD)" = main ] && ok "main contains the code and is the current branch" || ko "main contains the code"
agent demo rev-parse --verify -q refs/heads/agent/addition >/dev/null && ko "branch deleted after merge" || ok "branch deleted after merge"
[ "$(agent demo log -1 --format=%an)" = "Human" ] && ok "merge signed by the human" || ko "merge signed by the human"

# branch whose test fails: refused, main unchanged
agent demo switch -q -c agent/broken
printf 'import unittest\n\n\nclass F(unittest.TestCase):\n    def test_wrong(self):\n        self.assertEqual(1, 2)\n' > "$P/demo/tests/test_wrong.py"
agent demo add -A; agent demo -c user.name=bot -c user.email=b@x commit -q -m "test: wrong"
before="$(agent demo rev-parse main)"
expect_fail "merge refused if the check fails" "$DEV" merge demo agent/broken --yes
[ "$(agent demo rev-parse main)" = "$before" ] && ok "main unchanged after refusal" || ko "main unchanged after refusal"

# uncommitted files: refused
agent demo switch -q main; echo x > "$P/demo/draft.txt"
expect_fail "merge refused with a dirty tree" "$DEV" merge demo agent/broken --yes
rm "$P/demo/draft.txt"

# safeguards: trapped git configuration and hook
agent demo switch -q main
git -C "$P/demo" config core.fsmonitor "touch $T/PWNED"
expect_fail "trapped git configuration refused" "$DEV" review demo
[ ! -e "$T/PWNED" ] && ok "the trapped command was not run" || ko "the trapped command was run"
git -C "$P/demo" config --unset core.fsmonitor
agent demo switch -q -c agent/hook; echo y > "$P/demo/hook.txt"; agent demo add -A
git -C "$P/demo" -c core.hooksPath=/dev/null -c user.name=b -c user.email=b@x commit -q -m "feat: hook"
printf '#!/bin/sh\ntouch %s/HOOK\n' "$T" > "$P/demo/.git/hooks/post-merge"; chmod +x "$P/demo/.git/hooks/post-merge"
printf '#!/bin/sh\ntouch %s/HOOK2\n' "$T" > "$P/demo/.git/hooks/pre-commit"; chmod +x "$P/demo/.git/hooks/pre-commit"
"$DEV" merge demo agent/hook --yes >"$T/out" 2>&1
[ ! -e "$T/HOOK" ] && [ ! -e "$T/HOOK2" ] && ok "hooks ignored" || ko "hooks run"

[ "$("$DEV" pending | awk -F'\t' '$2=="agent/broken"{print $1":"$3}')" = "demo:1" ] && ok "pending lists project, branch and commits" || ko "pending"

# hostile names: neither the list (pending) nor the menu must propagate them
agent demo switch -q main; agent demo branch 'agent/x;touch-pwned'; agent demo branch 'agent/$(id)'
agent demo switch -q 'agent/x;touch-pwned'; echo z > "$P/demo/z.txt"; agent demo add -A; agent demo -c user.name=b -c user.email=b@x commit -q -m "feat: z"
agent demo switch -q main
out_rv="$("$DEV" pending)"; grep -q -E 'touch|\$\(' <<<"$out_rv" && ko "pending propagates a hostile branch name" || ok "pending drops hostile branch names"
mkdir -p "$P/Bad Name"; git -C "$P/Bad Name" init -q
out_rv="$("$DEV" pending)"; grep -q 'Bad' <<<"$out_rv" && ko "pending propagates a hostile project name" || ok "pending drops hostile project names"
# agent text: escape sequences are removed from the review
agent demo switch -q -c agent/esc; mkdir -p "$P/demo/docs/reviews"; printf 'ok \033[31mRED\033]0;title\007 end\n' > "$P/demo/docs/reviews/esc.md"
agent demo add -A; agent demo -c user.name=b -c user.email=b@x commit -q -m "docs: esc"; agent demo switch -q main
out_rv="$("$DEV" review demo agent/esc 2>&1)"; grep -q $'\033' <<<"$out_rv" && ko "the review lets ESC through" || ok "the review removes escape sequences"

# .git replaced by a link: refused
mkdir -p "$P/link"; ln -s "$P/demo/.git" "$P/link/.git"
expect_fail ".git as a link refused" "$DEV" review link

# model choice: the largest, never the small task model nor an embedding model; the -64k variant wins at equal size
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
[ "$(PATH="$T/bin:$PATH" "$DEV" pick-model)" = "qwen3.8:27b" ] && ok "pick-model: the largest (not qwen2.5:1.5b)" || ko "pick-model: the largest"
[ "$(WITH64=1 PATH="$T/bin:$PATH" "$DEV" pick-model)" = "qwen3.8:27b-64k" ] && ok "pick-model: the -64k variant wins at equal size" || ko "pick-model: -64k variant"
[ "$(LAB_MODEL=other:7b PATH="$T/bin:$PATH" "$DEV" pick-model)" = "other:7b" ] && ok "pick-model: LAB_MODEL takes priority" || ko "pick-model: LAB_MODEL"

# lab config / main-model (copy of `lab` in a temporary folder: .lab/ is isolated there)
mkdir -p "$T/root/ai-stack"; cp "$HERE/../lab" "$T/root/lab"
printf 'OWUI_TASK_MODEL=qwen2.5:1.5b\n' > "$T/root/ai-stack/.env"
mkdir -p "$T/bin2"; cat > "$T/bin2/docker" <<'STUB'
#!/usr/bin/env bash
printf 'NAME ID SIZE MODIFIED\n'
printf 'qwen2.5:1.5b abc 17 GB 2 days ago\n'
printf 'qwen3.8:27b abc 17 GB 3 days ago\n'
printf 'big-embed:latest abc 40 GB 3 days ago\n'
STUB
chmod +x "$T/bin2/docker"
L() { PATH="$T/bin2:$PATH" "$T/root/lab" "$@"; }
[ "$(L main-model)" = "qwen3.8:27b" ] && ok "main-model ignores the task model and embeddings" || ko "default main-model"
expect_ok   "config set MODEL" L config set MODEL qwen3.8:27b
[ "$(L main-model)" = "qwen3.8:27b" ] && [ "$(L config get MODEL)" = "qwen3.8:27b" ] && ok "config get / main-model read the setting" || ko "config get"
expect_fail "config set unknown model refused" L config set MODEL does-not-exist
expect_fail "config set unknown key refused" L config set OTHER x
[ "$(LAB_MODEL=other:7b L main-model)" = "other:7b" ] && ok "LAB_MODEL takes priority over the setting" || ko "LAB_MODEL"
expect_ok   "config unset" L config unset MODEL
[ -z "$(L config get MODEL)" ] && ok "setting removed" || ko "setting removed"
expect_fail "lab tmux unknown action refused" L tmux whatever

echo; [ $fails -eq 0 ] && echo "All dev.sh tests pass." || { echo "$fails failure(s)."; exit 1; }
