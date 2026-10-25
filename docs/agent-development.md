# Developing code with Hermes: code → test → review → merge

Goal: Hermes writes code **and tests it itself**, another sub-agent reviews it, and **you alone** decide on the merge.
Everything is local on AiBeast (local git, nothing on GitHub), for any language.

## 1. The principle in one picture

```
you ── lab dev start PROJECT ──▶ Hermes (in the sandbox container, project folder)
                                  │ branch agent/<topic>
                                  │ for each small task: failing test → code → ./scripts/check → commit
                                  │ FRESH sub-agent: review "matches the plan?" then "quality?"
                                  │ report docs/reviews/<topic>.md  (+ BLOCKED.md if blocked)
you ◀── lab dev review PROJECT ───┘
you ── lab dev merge PROJECT agent/<topic> ──▶ check run again in the sandbox → you confirm → --no-ff merge into main
```

Two separate safeguards: **the agent does not touch `main`** (rule written in `AGENTS.md`, which Hermes reads), and
**`lab dev merge` refuses to merge if `scripts/check` fails**, whatever the agent claims in its report.

## 2. Getting started (once)

```bash
lab dev ctx64        # variant of the model with a 65,536 context (see §5) and Hermes config pointed at it
lab dev setup        # sub-agents one at a time + two-pass review skill
lab dev new trial python     # python | node | shell | other
lab dev start trial          # opens Hermes INSIDE the project
```
Suggested first message: *"Read AGENTS.md. Add a slugify(text) function with its tests, following the workflow in the
file."* Then `/exit`, and: `lab dev review trial`.

## 3. Commands

| Command | Effect |
|---|---|
| `lab dev new NAME [python\|node\|shell\|other]` | Folder `hermes/data/workspace/projects/NAME`: git repository (`main`), `AGENTS.md`, `scripts/check`, `tests/`, `docs/plans/`, `docs/reviews/` |
| `lab dev list` | Projects, current branch, uncommitted files, `agent/*` branches to review |
| `lab dev start NAME [MODEL]` | Hermes opened in the project. Model: the one given, otherwise `LAB_MODEL`, otherwise **the largest installed model** (never Open WebUI's small task model nor an embedding model; at equal size the `-64k` variant). Hermes's config (`model.default`) is aligned with this choice, copy `config.yaml.avant-modele` |
| `lab dev review NAME [BRANCH [--diff]]` | Without a branch: list. With one: commits, files, agent report; `--diff`: full diff |
| `lab dev check NAME [BRANCH]` | `scripts/check` **in the sandbox** (switches to the branch if given, clean tree required) |
| `lab dev merge NAME BRANCH [--yes]` | Check → diffstat → confirmation → `merge --no-ff` into `main` → branch deleted. Conflict: merge aborted |
| `lab dev setup` | Adds the `delegation` block to `hermes/data/config.yaml` (copy `.avant-dev`) and installs the `subagent-driven-development` skill |
| `lab dev ctx64 [MODEL]` | Creates `MODEL-64k` (`num_ctx 65536`) and sets it as Hermes's model (copy `.avant-ctx64`) |

## 4. What `scripts/check` does (a single entry point, all languages)

It detects what exists and **fails if no test ran** (a project without tests does not pass):
Python (syntax, `pytest` if installed, otherwise `unittest`, `ruff` if installed), Node (`npm test`, `npm run lint` if it
exists), shell (`bash -n`, `shellcheck` if installed, `tests/*.sh`). Other language: write `tests/run.sh`. Adapt the file
to your project, but **do not weaken it to make a test pass** (this is written in `AGENTS.md`).
Without `pytest`, Python tests must be `unittest.TestCase` classes; otherwise no test is found and the check fails.

## 5. Design choices and why

- **Sub-agents one at a time** (`max_concurrent_children: 1`). Measured on the reference machine (`concurrency`): Ollama
  handles one request at a time for this model, whatever `NUM_PARALLEL` is. By default Hermes starts up to 10
  sub-agents in parallel; they would queue, and Hermes abandons a sub-agent with no progress for 450 s (value from its
  documentation, not tested here). There is therefore no speed gain in parallelising them. *Unmeasured hypothesis:*
  alternating sub-agents with different contexts forces Ollama to recompute the start of the prompt at each switch,
  which costs time (the prefix cache only helps for an identical start).
- **Review by a fresh sub-agent**: a sub-agent starts with no memory, so it judges the code without the bias of whoever
  wrote it. It is the same model on both sides: the review catches omissions, **not every reasoning error of the
  model**. Hence your final review of the diff and the check run again by `lab dev merge`.
- **65,536 context.** Hermes requires at least 64,000 tokens, whereas Ollama serves 32,768 by default
  (`OLLAMA_CONTEXT_LENGTH`). The OpenAI-compatible API (`/v1`) that Hermes uses cannot request `num_ctx`; the
  `MODEL-64k` variant therefore sets the size in the model itself. Measured (`ctx-window`, `q8_0` cache): 21,147 MiB of
  VRAM at 65,536 with the `qwen3.8:27b` model alone on the card; the combination "65,536 + small task model + Open
  WebUI" was not measured.
- **Agent code never runs on AiBeast outside the sandbox.** Tests run in the Hermes container. The git commands run by
  `lab dev` on the host ignore hooks, and refuse a repository whose `.git/config` contains anything beyond the minimum
  (the agent can write in `.git/`: an option such as `core.fsmonitor` or an alias would run a command on the host).
  Tested by `scripts/test-dev.sh`.
- **Local git, no GitHub**: no token to protect. To publish later: `git push` done by you, from `main`, after review.

## 6. When the agent is stuck or wrong

- `BLOCKED.md` in the project: the agent stopped after 3 failures (rule in `AGENTS.md`); `lab dev review` reports it.
- Branch failing the check: `lab dev merge` stops and leaves you on the branch; run `lab dev start` again and ask for
  the fix.
- Over-optimistic report: `lab dev check NAME agent/…` contradicts it in one command. Read the diff, not only the
  report.
- Project gone wrong: `git -C hermes/data/workspace/projects/NAME log --oneline --all`; everything is in git, nothing is
  lost. The backup (`lab backup run`) includes the projects (they are in `hermes/data`).

## 7. Tests of this setup

`bash scripts/test-dev.sh` (without Docker or Hermes): creation, invalid name, review, passing check, merge and
signature, refusal when the check fails, refusal with uncommitted files, trapped git configuration (command not run),
hooks ignored, `.git` as a link. It found two defects in `scripts/check` before delivery (Python detection, `pytest`
tests without `pytest`).

## First real trial (reference machine, project `essai`, task "slugify")

Verified:
- `lab dev new`, `lab dev start` (right model after a fix), `lab dev review` and `lab dev check` work. The check runs in
  the Hermes container (`bash`, `python3` 3.14 and `unittest` present): **10 tests, OK**, run again by `lab dev check`,
  not only announced by the agent.
- Hermes produced an `agent/slugify` branch (4 commits: feature + tests, completed test, docstring, report) and a report
  that follows the plan in `AGENTS.md` (compliance PASS, quality APPROVED, "what was not verified" section). The content
  of the code was not reviewed in detail.
- In the sandbox: `pytest`, `ruff` and `shellcheck` are **missing** (Python tests must therefore be `unittest` classes,
  and ruff/shellcheck do not run).

Not measured: duration of the task, number of review rounds, code quality on a less simple task.

## What is not verified

- **Hang observed once:** `lab dev check` printed "check: all good" then did not return (Ctrl+C needed; no orphan
  container afterwards). Fix applied: the container's standard input is cut (`< /dev/null`). **Not confirmed** that this
  solves the problem; if the command keeps waiting, open a second terminal and run `docker ps` then
  `docker top CONTAINER_NAME` while it waits.
- The choice of the "largest installed model" is based on the SIZE column of `ollama list`; tested with a simulated list
  only. If you have several large models, give the name: `lab dev start NAME MODEL`. An earlier version picked
  `qwen2.5:1.5b` (the small task model): defect fixed.
- Not confirmed so far: `lab dev merge` (real merge), `lab dev setup` (the command
  `skills install official/software-development/subagent-driven-development` comes from Hermes's documentation; it may
  ask for a confirmation) and `lab dev ctx64` (the variant must appear with `CONTEXT 65536` in `ollama ps`).
- Hermes seems to read `AGENTS.md` (its report quotes the merge rule and follows the workflow), but the mechanism was not
  verified; the `-w` working folder works.
- The sandbox has neither `node` nor `pytest` confirmed: only Python 3.14 + `unittest` is. A Node project will fail the
  check if `node`/`npm` are missing.
- The exact keys `delegation.max_iterations` / `max_concurrent_children` / `max_spawn_depth` come from Hermes's
  documentation (current version); the installed `:stable` image version was not compared.
- Real quality of a local model's work on coding tasks: not measured. Evaluate it on 2 or 3 real tasks before trusting
  it with anything serious.
- Hermes has never run the full loop (plan → tests → two-pass review) here; the duration of a task is not known.
- `scripts/check`: tested for Python (`unittest`), Node (`npm test`) and shell; `pytest`, `ruff` and `shellcheck` were
  not (absent from the test environment).

## Appendix: OpenCode for Hermes (23 October 2026)

OpenCode (command-line coding agent, version 1.19.4) is installed in Hermes's volume, `hermes/data/opencode/`, seen as `/opt/data/opencode/` by Hermes. Hermes runs it with `/opt/data/opencode/opencode run "task"` (bounded task). Sources: [installation](https://opencode.ai/en/docs), [providers](https://opencode.ai/docs/providers), [configuration](https://opencode.ai/docs/config).

**Why this installation.** The Hermes container has no Internet (see `agent-isolation.md`): `npm` or `curl | bash` fail there. `hermes/install-opencode.sh` downloads `opencode-ai` in a throwaway copy of the Hermes image (`bridge` network, same Node and glibc) into the volume. The image's `npm` 12 blocks install scripts: the script therefore runs the package's `postinstall.mjs` by hand, which puts the platform binary in place.

**Files** (in `hermes/data/opencode/`, ignored by git): `opencode.json` (provider `ollama` at `http://ollama:11434/v1`, model `qwen3.8:27b-64k`, context 65536, output 8192, `autoupdate` disabled); `opencode`, a wrapper that sets `OPENCODE_CONFIG` and the XDG folders in the same volume, so it depends neither on `HOME` nor on a project folder.

**Commands.** Install or reinstall: `cd hermes && ./install-opencode.sh [VERSION] [MODEL]` (keeps an existing `opencode.json`). Update: run it again with the new version, after reading its release notes. Change model: edit `hermes/data/opencode/opencode.json`.

**Verified (23 October 2026, reference machine).** `opencode --version` returns 1.19.4 in the Hermes image; `opencode run "Create a file bonjour.txt containing the word salut, then answer only OK"` run as user 1000 on `hermes-net`: model `qwen3.8:27b-64k`, file-write tool call succeeded, answer `OK`, exit code 0; `install-opencode.sh` run again: version 1.19.4, config kept.

**Not verified.** A first installation from scratch with the script; OpenCode on a real project (several files, tests, long tasks); quality of results compared with Hermes alone; duration of a task; its behaviour when Hermes launches it from its own session (no terminal, unknown `HOME`); possible network requests from OpenCode (model list, updates) blocked by the isolation — no error appeared during the test, but the logs were not searched; the case where Hermes and OpenCode query Ollama at the same time (one model served at a time).
