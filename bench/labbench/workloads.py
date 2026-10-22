"""Charges de travail. Chaque prompt commence par un nonce unique : sans lui, Ollama réutilise le cache de
préfixe (KV) d'une exécution précédente et la mesure du prefill serait faussée (sauf pour 'prefix_cache', où
c'est justement l'objet de la mesure)."""
from __future__ import annotations

import math
import random
import re
import threading
import time
import uuid

import numpy as np

from .ollama import GenResult, OllamaClient

_WORDS = ("cadre signal fenêtre moteur rivière tableau lumière chapitre horizon vitesse matrice courbe "
          "mémoire réseau capteur batterie tension fréquence couche modèle entrée sortie segment tampon "
          "latence débit jeton vecteur noyau registre canal phase seuil mesure erreur balance").split()


def filler(n_tokens: int, rng: random.Random, chars_per_token: float) -> str:
    """Texte pseudo-aléatoire reproductible d'environ n_tokens tokens."""
    target = int(max(0, n_tokens) * chars_per_token)
    out, size = [], 0
    while size < target:
        s = " ".join(rng.choice(_WORDS) for _ in range(rng.randint(6, 14))).capitalize() + ". "
        out.append(s)
        size += len(s)
    return "".join(out)[:target]


def calibrate(client: OllamaClient, model: str, num_ctx: int) -> float:
    """Estime caractères/token pour ce modèle avec une requête courte (num_predict=1)."""
    rng = random.Random(7)
    text = filler(400, rng, 4.0)
    r = client.generate(model, f"[{uuid.uuid4().hex}] {text}\nOK ?", num_ctx=max(num_ctx, 2048), num_predict=1)
    if not r.ok or r.prompt_tokens <= 20:
        return 3.2
    return max(1.5, min(8.0, (len(text) + 40) / r.prompt_tokens))


def _nonce() -> str:
    return f"[run {uuid.uuid4().hex}]"


def _pct(x: list[float], q: float) -> float:
    return float(np.percentile(x, q)) if x else math.nan


def _common(results: list[GenResult]) -> dict:
    ok = [r for r in results if r.ok]
    itl = [v for r in ok for v in r.itl_ms]
    return {
        "n_ok": len(ok), "n_err": len(results) - len(ok),
        "error": next((r.error for r in results if not r.ok), ""),
        "prompt_tokens": sum(r.prompt_tokens for r in ok),
        "gen_tokens": sum(r.gen_tokens for r in ok),
        "ttft_s": float(np.mean([r.ttft_s for r in ok])) if ok else math.nan,
        "prefill_tps": float(np.nanmean([r.prefill_tps for r in ok])) if ok else math.nan,
        "decode_tps": float(np.nanmean([r.decode_tps for r in ok])) if ok else math.nan,
        "itl_p50_ms": _pct(itl, 50), "itl_p95_ms": _pct(itl, 95), "itl_p99_ms": _pct(itl, 99),
        "load_s": float(np.mean([r.load_s for r in ok])) if ok else math.nan,
    }


def _gen_kwargs(v: dict, num_predict: int | None = None) -> dict:
    return dict(num_ctx=int(v["num_ctx"]), num_predict=int(num_predict or v["gen_tokens"]),
                think=bool(v.get("think", False)), temperature=float(v.get("temperature", 0.0)),
                keep_alive=str(v.get("keep_alive", "30m")))


def check_fits(v: dict) -> str | None:
    need = int(v["ctx_depth"]) + int(v["gen_tokens"]) + 64
    if need > int(v["num_ctx"]):
        return f"ctx_depth({v['ctx_depth']}) + gen_tokens({v['gen_tokens']}) dépasse num_ctx({v['num_ctx']})"
    return None


def run_mixed(c: OllamaClient, model: str, v: dict, seed: int, cpt: float) -> dict:
    rng = random.Random(seed)
    prompt = (f"{_nonce()}\nVoici un texte de remplissage :\n{filler(int(v['ctx_depth']), rng, cpt)}\n\n"
              "Écris maintenant un long texte descriptif et détaillé sur le fonctionnement d'un processeur graphique.")
    r = c.generate(model, prompt, seed=seed, **_gen_kwargs(v))
    return _common([r])


def run_needle(c: OllamaClient, model: str, v: dict, seed: int, cpt: float) -> dict:
    rng = random.Random(seed)
    code = "".join(rng.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(6))
    depth = float(v.get("needle_depth", 0.5))
    total = int(v["ctx_depth"])
    before = filler(int(total * depth), rng, cpt)
    after = filler(int(total * (1 - depth)), rng, cpt)
    prompt = (f"{_nonce()}\nLis le texte suivant.\n\n{before}\nINFORMATION IMPORTANTE : le code secret est {code}.\n"
              f"{after}\n\nQuestion : quel est le code secret ? Réponds uniquement par le code.")
    # si "think" est actif, il faut laisser de la place au raisonnement
    r = c.generate(model, prompt, seed=seed, **_gen_kwargs(v, num_predict=int(v["gen_tokens"])))
    out = _common([r])
    found = code in (r.text or "").upper().replace(" ", "") if r.ok else False
    out["quality"] = 1.0 if found else 0.0
    return out


def run_prefix_cache(c: OllamaClient, model: str, v: dict, seed: int, cpt: float) -> dict:
    rng = random.Random(seed)
    prefix = f"{_nonce()}\n{filler(int(v['ctx_depth']), rng, cpt)}\n\n"
    kw = _gen_kwargs(v, num_predict=min(32, int(v["gen_tokens"])))
    cold = c.generate(model, prefix + "Résume en une phrase.", seed=seed, **kw)
    warm = c.generate(model, prefix + "Résume en deux mots.", seed=seed, **kw)
    out = _common([cold])
    out.update({
        "cold_prompt_eval_s": cold.prompt_eval_s, "warm_prompt_eval_s": warm.prompt_eval_s,
        "cold_prompt_tokens": cold.prompt_tokens, "warm_prompt_tokens": warm.prompt_tokens,
        "cold_ttft_s": cold.ttft_s, "warm_ttft_s": warm.ttft_s,
        "cache_ttft_speedup": (cold.ttft_s / warm.ttft_s) if warm.ok and warm.ttft_s and warm.ttft_s > 0 else math.nan,
        # part du travail de lecture évitée = 1 - temps de lecture du prompt (2e requête) / temps de lecture (1re requête).
        # Mesuré le 2026-10-19 : Ollama renseigne prompt_eval_count avec le prompt COMPLET même quand le préfixe est réutilisé,
        # donc un calcul sur les nombres de tokens donnait toujours 0 ; le temps, lui, tombe de 18 s à 0,7 s.
        "cache_reuse_frac": (1 - warm.prompt_eval_s / cold.prompt_eval_s) if (cold.prompt_eval_s and cold.prompt_eval_s > 0 and warm.ok) else math.nan,
    })
    return out


def run_concurrency(c: OllamaClient, model: str, v: dict, seed: int, cpt: float) -> dict:
    n = int(v.get("clients", 1))
    results: list[GenResult | None] = [None] * n

    def one(i):
        rng = random.Random(seed * 1000 + i)
        prompt = (f"{_nonce()}\n{filler(int(v['ctx_depth']), rng, cpt)}\n\n"
                  "Écris un long texte descriptif sur la gestion de la mémoire dans un ordinateur.")
        results[i] = c.generate(model, prompt, seed=seed + i, **_gen_kwargs(v))

    t0 = time.perf_counter()
    th = [threading.Thread(target=one, args=(i,)) for i in range(n)]
    [t.start() for t in th]
    [t.join() for t in th]
    wall = time.perf_counter() - t0
    rs = [r for r in results if r is not None]
    out = _common(rs)
    out["wall_s"] = wall
    out["agg_tps"] = out["gen_tokens"] / wall if wall > 0 else math.nan
    out["clients"] = n
    return out


def run_arith(c: OllamaClient, model: str, v: dict, seed: int, cpt: float) -> dict:
    """Mini test de qualité : 12 calculs. Sensible à la dégradation due à une quantification agressive du cache KV."""
    rng = random.Random(4242)  # mêmes questions à chaque exécution : seule la configuration varie
    qs = []
    for _ in range(12):
        a, b, cc = rng.randint(120, 989), rng.randint(12, 97), rng.randint(100, 900)
        qs.append((f"Calcule {a} * {b} + {cc}. Réponds uniquement par le nombre.", a * b + cc))
    ok, rs = 0, []
    for q, ans in qs:
        r = c.generate(model, f"{_nonce()}\n{q}", seed=seed, **_gen_kwargs(v, num_predict=int(v["gen_tokens"])))
        rs.append(r)
        nums = re.findall(r"-?\d[\d\s,.]*", (r.text or ""))
        got = [re.sub(r"[\s,.]", "", s) for s in nums]
        ok += int(r.ok and str(ans) in got)
    out = _common(rs)
    out["quality"] = ok / len(qs)
    out["quality_n"] = len(qs)
    return out


ARITH_EASY_N = 150


def run_arith_easy(c: OllamaClient, model: str, v: dict, seed: int, cpt: float) -> dict:
    """Test de qualité plus fin que `arith` : 150 calculs FACILES (2 chiffres × 1 chiffre + 2 chiffres), mêmes questions
    pour tous les types de cache. Le modèle doit en réussir la grande majorité sans raisonner, pour qu'une perte soit visible.
    La température est nulle, mais un identifiant aléatoire est placé en tête de chaque prompt : deux répétitions peuvent différer
    d'une question ou deux (constaté le 2026-10-19). Les contextes sont courts (≈ 65 tokens par question) : le cache KV est peu sollicité."""
    rng = random.Random(777)
    qs = []
    for _ in range(ARITH_EASY_N):
        a, b, cc = rng.randint(12, 99), rng.randint(2, 9), rng.randint(10, 99)
        qs.append((f"Calcule {a} * {b} + {cc}. Réponds uniquement par le nombre.", a * b + cc))
    ok, rs = 0, []
    for q, ans in qs:
        r = c.generate(model, f"{_nonce()}\n{q}", seed=seed, **_gen_kwargs(v, num_predict=int(v["gen_tokens"])))
        rs.append(r)
        nums = re.findall(r"-?\d[\d\s,.]*", (r.text or ""))
        got = [re.sub(r"[\s,.]", "", s) for s in nums]
        ok += int(r.ok and str(ans) in got)
    out = _common(rs)
    out["quality"] = ok / len(qs)
    out["quality_n"] = len(qs)
    return out


WORKLOADS = {"mixed": run_mixed, "needle": run_needle, "prefix_cache": run_prefix_cache,
             "concurrency": run_concurrency, "arith": run_arith, "arith_easy": run_arith_easy}
