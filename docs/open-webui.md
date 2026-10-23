# Open WebUI: everyday comfort

What changes daily use: a small model for background tasks, ready-to-use presets, interface settings, and voice.

## 1. Task model (the biggest gain)

**Problem.** By default Open WebUI uses the conversation's model to produce **titles**, **tags** and suggestions. With
a 27-billion-parameter model (17 GB in VRAM) this is slow, and above all: `OLLAMA_MAX_LOADED_MODELS=1` forces Ollama to
**unload** the big model to load the small one, then reload it at every message. Each answer can then cost several
seconds of reloading.

**Solution.** A small model (1 to 4 billion parameters, ~1-3 GB) dedicated to tasks, kept in VRAM **in addition to**
the big model (24 GB of VRAM: 17 GB + small model + KV cache fit, check with `ollama ps`).

### In one command

```bash
lab task-model qwen3:1.7b      # replace the name with a small model from the Ollama library
```
The command downloads the model, sets `OLLAMA_MAX_LOADED_MODELS=2` and `OWUI_TASK_MODEL=<name>` in `ai-stack/.env`,
restarts Ollama, then reminds you of the manual step below.

### Manual step (required for an existing instance)
Open WebUI **stores its settings in its database**: the environment variable is only used at the very first start. So,
in the interface:
**Admin (profile at the bottom left) → Settings → Interface → Task Model**: pick the small model (the "external task
model" can stay the same).

### Check
```bash
docker exec ollama ollama ps
```
After a few messages, you must see **two lines**: the big model and the small one, both `100% GPU`.
If the big model switches to `xx% CPU`, the VRAM is too tight: reduce the context (`OLLAMA_CONTEXT_LENGTH`) or disable
automatic titles (Admin → Settings → Interface → "Title Generation" off).

### Choosing the small model
Take a recent model with 1 to 4 billion parameters **available in the Ollama library** (https://ollama.com/library).
Exact names change; check that it exists with `ollama pull`. A "thinking" model is a bad idea for titles (it thinks for
a long time for nothing).

**Watch the context cache**: Ollama reserves the cache for the whole context (`OLLAMA_CONTEXT_LENGTH`, 32768 here),
even for a ten-word title. A 3-billion-parameter model therefore costs about 2 GB of weights **plus** its cache
(estimate: 1.5 to 2 GB), which exceeds the margin of about 3.8 GB as soon as there are other consumers. A model with 1 to
1.5 billion parameters fits with room to spare (that is what was chosen).

### Measured on the reference machine (installed: `qwen2.5:1.5b`)

| Measurement | Value |
|---|---|
| `ollama ps`, small model | `qwen2.5:1.5b`, 1.7 GB, **100 % GPU**, context 32768 |
| `ollama ps`, big model | `qwen3.8:27b`, 17 GB, **100 % GPU**, context 65536 |
| `nvidia-smi`, both loaded | **22,620 MiB** used out of 24,576 (≈ 1.9 GB margin) |

Both therefore fit in VRAM at the same time, but **the margin is thin** (≈ 1.9 GB). Consequences:
- do not raise the big model's context without measuring again;
- `lab mode images` (SDXL ≈ 7 GB) unloads the Ollama models; if Open WebUI calls the small model during this mode, it
  reloads (1.7 GB) but the big model will no longer fit: go back to `lab mode normal` to chat;
- if the big model ever switches to `xx% CPU`, revert: empty `OLLAMA_MAX_LOADED_MODELS=1` and `OWUI_TASK_MODEL=` in
  `ai-stack/.env`, `docker compose up -d ollama open-webui`, then set the old task model back in Open WebUI.

Not measured: the real speed gain (time to display titles, no reload of the big model); it is expected but there is no
before/after timing.

## 2. Model presets

A preset = a base model + a system message + parameters, under a simple name in the list.
**Workspace → Models → "+"**, then: name, base model, **System Prompt**, and in "Advanced Params" `temperature` and
`num_ctx` (context length). Paste the texts below.

| Preset | `temperature` | `num_ctx` | Use |
|---|---|---|---|
| Assistant | 0.7 | 32768 | Everyday conversation |
| Coder | 0.2 | 32768 | Code, scripts, review |
| Document analyst | 0.2 | 65536 | PDFs, reports, datasheets |
| Writer | 0.8 | 16384 | Texts, emails |
| Translator | 0.2 | 8192 | Faithful translation |

A larger `num_ctx` uses more VRAM (KV cache): check with `docker exec ollama ollama ps` that the model stays 100 % GPU.
The benchmark measurements (`lab bench`, `context-scaling` experiment) give the real cost.

### System prompts (to copy)

To get answers in another language by default, add a sentence such as "Answer in French unless the user writes in
another language." to the prompt.

**Assistant**
```
You are a clear and concise assistant. Answer in the language the user writes in. Get straight to the point, then go
into detail only if it is useful. If you are not sure about a fact, say so instead of making it up. For calculations or
dates, show the important steps.
```

**Coder**
```
You are an experienced software engineer. Before writing code, restate the need in one sentence if the request is
ambiguous. Give complete, runnable code, state the language in the code blocks, point out assumptions (versions,
dependencies) and risks (security, edge cases). Do not rewrite what does not need to change: only show the necessary
changes, with their location.
```

**Document analyst**
```
You analyse documents provided by the user (reports, datasheets, contracts, articles). Rely only on the content
provided: quote the page or section when possible, and say clearly "not specified in the document" when the
information is missing. Separate what the document says from your interpretation. For numbers, repeat the exact values
and units.
```

**Writer**
```
You help write texts (emails, notes, descriptions). Respect the requested tone (formal, neutral, warm). Offer a version
ready to send, then, if useful, a shorter variant. Do not change the facts provided; point out what is missing to
finalise it.
```

**Translator**
```
You are a translator. Translate faithfully, without summarising or commenting, keeping the meaning, the register and
the formatting (lists, code, headings). If the source language is not given, detect it; the target language is English
unless asked otherwise. Point out ambiguous passages in square brackets.
```

## 3. Recommended interface settings

| Where | Setting | Why |
|---|---|---|
| Admin → Settings → General | Disable "Enable New Sign Ups" (or `ENABLE_SIGNUP=false` in `ai-stack/.env`) | On an existing instance, both the variable and the interface switch are needed |
| Admin → Settings → Interface | Task model (see §1) | Speed |
| Admin → Settings → Interface | Disable automatic tag generation and follow-up suggestions | Fewer background tasks |
| Admin → Settings → Models | Set a default model | Avoids choosing it for every conversation |
| Admin → Settings → Documents | Extraction engine: Tika (already configured) | Better reading of PDF and Office documents |
| Admin → Settings → Web Search | Engine: SearXNG (already configured) | Search without tracking |

Language: `OPEN_WEBUI_LOCALE` in `ai-stack/.env` (default `en`, e.g. `fr`, `de`) sets the interface language at
installation; on an existing instance, change it in Settings → General.

## 4. Voice

Text-to-speech is Kokoro (CPU). Its voices are mostly English (`af_*`, `am_*`, `bf_*`, `bm_*`), with a few other
languages, for example **one French voice, `ff_siwis`** (file `/app/api/src/voices/v1_0/ff_siwis.pt` in the image;
verified: Kokoro generates an mp3 with it). Speech recognition (microphone) is Open WebUI's built-in Whisper, which
understands many languages.

**Settings**: Admin → Settings → Audio (engine "OpenAI", URL `http://kokoro:8880/v1`, model `kokoro`, voice of your
choice, `af_bella` by default); `KOKORO_VOICE=<voice>` in `ai-stack/.env` for a reinstallation.

**The three pitfalls met (with `ff_siwis`)**

| Symptom | Cause | Remedy |
|---|---|---|
| `Voice "ff_siwis" not found. Should be one of: af_heart…` (28 English voices) | Your **personal** setting (Settings → Audio) used the **Kokoro.js** engine, which runs in the browser and only has English voices | Set the engine to the server (OpenAI / default) |
| `Voice name cannot be empty` (400) | After the engine change, the personal Voice field was empty | Type the voice name by hand (the field accepts free input) |
| `External: 400, message='Bad Request'` although the voice is right | The **Model** field contained `Kokoro` with a capital letter; Kokoro compares case-sensitively | `kokoro` (or `tts-1`) in lower case |

Kokoro's logs (`docker logs kokoro`) only show the 400 code, not the reason. To see the reason, send the request by hand
from the Open WebUI container (`docker exec open-webui python3 …` to `http://kokoro:8880/v1/audio/speech`) and print the
error body: that is how "Voice name cannot be empty" showed up.

**Option not built**: Speaches (recognition + Piper synthesis in one service). Useless as long as Kokoro's voices suit
you; it would take VRAM in competition with the language model.

## 5. What is not verified

- The exact menu labels ("Task Model", "Title Generation"…) may differ depending on the Open WebUI version; the general
  path Admin → Settings → Interface is the right starting point.
- The `TASK_MODEL` and `DEFAULT_LOCALE` variables are the ones known from Open WebUI, but the official configuration
  page consulted did not detail them: the interface remains the reference method, the variable is only a nudge at the
  first start.
- Whether the big model and the small one fit together in VRAM depends on the chosen model and context: only
  `ollama ps` on your machine tells.
