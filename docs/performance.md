# Performance : régler avec des mesures, pas au feeling

Principe : chaque réglage important a une **expérience du banc d'essai** qui le mesure (`lab bench ...`). On change un
réglage seulement quand une mesure le justifie, et on note le résultat ici.

## 1. Limite de puissance du GPU

### Mesure (power-sweep, 15 octobre 2026)
RTX 3090, `qwen3.8:27b`, 2048 tokens de contexte rempli, 256 tokens générés, 7 répétitions par niveau.
Référence : 350 W (réglage d'usine). **Mesuré avec le bureau à distance actif** (voir `remote-desktop-gpu.md`).

| Limite | Génération | vs 350 W | Prefill | J/token | Fréquence SM |
|---|---|---|---|---|---|
| 350 W | 55,1 tok/s | référence | 1 238 tok/s | 7,6 | 1 591 MHz |
| **300 W** | **50,3** | **−9 %** [−13 ; −3] | 1 166 | **6,8 (−10 %)** | 1 419 |
| 250 W | 40,7 | −26 % | 1 059 | 7,4 (≈ 350 W) | 1 088 |
| 220 W | 29,8 | −46 % | 889 | 8,5 | 855 |
| 200 W | 24,8 | −55 % | 750 | 9,2 | 662 |
| 180 W | 19,0 | −66 % | 575 | 10,9 | 506 |
| 150 W | 9,6 | −83 % | 316 | 17,7 | 245 |

Lecture :
- **300 W est le meilleur compromis** : seul niveau plus efficace en énergie que 350 W, pour 9 % de vitesse en moins.
- **Sous 250 W**, on perd en vitesse **et** en énergie par token : le brider davantage ne sert à rien.
- La vitesse de génération suit la fréquence SM (≈ 0,035 à 0,039 tok/s par MHz) : ici, la génération est limitée par le
  calcul, pas par la mémoire.
- La carte ne dépasse pas ≈ 309 W en charge, même avec une limite de 350 W.

Limites de cette mesure : un modèle, une charge, bruit de mesure (CV médian 9 %, plus petit écart détectable ≈ 10,5 %).
La différence 300 W / 350 W (−9 %) était donc **à la limite du détectable** : d'où la confirmation ci-dessous.

### Confirmation (power-confirm, 15 octobre 2026, 15 répétitions par niveau)
Même modèle et même charge ; référence 350 W ; intervalles de confiance à 95 % entre crochets.

| Limite | Génération | Prefill | Temps avant 1er token | Puissance moyenne | Énergie par token |
|---|---|---|---|---|---|
| **300 W** | **−6,8 %** [−12,5 ; −0,7] | −5,1 % | +3,7 % | −11,5 % | **−7,0 %** [−11,3 ; −2,5] |
| 250 W | −30,7 % [−35,0 ; −26,1] | −14,5 % | +14,9 % | −23,1 % | −0,8 % (non significatif) |

Tous les écarts de 300 W sont significatifs : −7 % de vitesse environ (le vrai écart se situe probablement entre 1 et
12 %), −7 % d'énergie par token. À 250 W la vitesse chute d'un tiers sans gain d'énergie par token : réglage écarté.
Non noté au moment du test : l'état du bureau à distance (demandé éteint ; à vérifier si les chiffres sont comparés à de
futures mesures).

### Appliquer de façon permanente
```bash
lab gpu-limit install 300      # installe un service systemd (demande sudo)
lab gpu-limit status           # limite actuelle, bornes, service installé ?
lab gpu-limit remove           # retire le service et remet la limite d'usine
```
Le service exécute `nvidia-smi -pm 1` puis `-pl 300` à chaque démarrage. Le banc d'essai **restaure la limite qu'il a
trouvée** à la fin de chaque test, donc il ne défait pas ce réglage.

## 1 bis. Coût du contexte (context-scaling, 18 octobre 2026)

`qwen3.8:27b`, limite 300 W, `num_ctx` 65 536, 128 tokens générés, 5 répétitions par profondeur, Ollama de production arrêté
(le modèle de tâches n'était donc pas chargé). Cache KV du banc : **f16** d'après `bench/labbench/config.py` (valeur par
défaut du banc ; à relire dans `meta.json`), alors que la production utilise `q8_0`. Ces chiffres viennent de `summary.csv`.

| Contexte rempli | Génération (tok/s) | Prefill (tok/s) | Délai avant le 1er token | Puissance moy. | Part du temps au GPU |
|---|---|---|---|---|---|
| 512 | 48,6 ± 4,2 | 896 | 1,5 s | 253 W | 100 % |
| 4 096 | 57,9 ± 5,2 | 1 225 | 3,6 s | 269 W | 100 % |
| 16 384 | 59,4 ± 2,7 | 1 204 | 13,4 s | 285 W | 100 % |
| 32 768 | 58,5 ± 2,6 | 1 126 | 27,4 s | 291 W | 100 % |
| 56 000 | 54,9 ± 4,4 | 1 023 | 50,8 s | 294 W | 100 % |

Lecture :
- **Le coût d'un grand contexte se paie au premier token** : environ 0,9 ms par token de prompt, soit ≈ 13 s pour 16 000
  tokens, ≈ 27 s pour 32 000, ≈ 51 s pour 56 000 (prefill de 1 225 à 1 023 tok/s, en baisse de ≈ 16 %, intervalles étroits).
- **La génération reste stable (≈ 55 à 59 tok/s) de 4 096 à 56 000 tokens** : les intervalles de confiance se recouvrent. Le
  recul à 56 000 (−7 % par rapport au plateau) n'est pas démontré. Latence inter-token p95 : 51 → 56 ms.
- **Le point à 512 est suspect** (génération 48,6 tok/s, puissance 253 W, fréquence SM 1 425 MHz, plus bas que les autres,
  et TTFT très bruité, CV 45 %) : des essais très courts, GPU pas encore à plein régime. Ne pas s'en servir comme référence
  de « vitesse à vide » ; les écarts en % du fichier `comparisons.csv` sont mesurés par rapport à lui et sont donc trompeurs.
- **Le modèle reste à 100 % GPU à 65 536 tokens de contexte**, seul sur la carte. Pas de bridage thermique (max 63 °C) ;
  la carte est bridée par la limite de puissance (300 W) presque tout le temps, ce qui est le réglage voulu.
- Énergie par token (7,6 → 110 J) : elle inclut le prefill ; ce n'est pas l'efficacité de la génération.

Limites : pas de comparaison de `num_ctx` (tout le test est à 65 536, donc l'effet de la **taille de fenêtre** sur la VRAM
et la vitesse à vide n'est pas mesuré, seulement l'effet de la **quantité de texte** dans la fenêtre) ; cache f16, pas
`q8_0` ; un seul modèle ; 5 répétitions. Génération à 58 tok/s à 300 W, contre 50 tok/s mesurés au `power-sweep` : écart
non expliqué (le bureau à distance était actif lors du premier test, état non noté pour celui-ci).

## 1 ter. Génération d'images : Qwen-Image-2.1 dans ComfyUI (21 octobre 2026)

**Configuration** : ComfyUI 0.39.0, PyTorch 2.14.1+cu130, RTX 3090. Modèle de diffusion `qwen-image-2.1-UC-BF16.gguf` (14,2 Go, chargé par le nœud *Unet Loader (GGUF)* du fork `leejet/ComfyUI-GGUF`), encodeur de texte `qwen3vl_8b_int8_convrot.safetensors` (9,35 Go), VAE `qwen_image_2.1_vae_bf16.safetensors`. Réglages du template : 1024×1024 (1:1, 1,0 mégapixel), 25 étapes, `cfg` 1,0, `euler` / `simple`, `refine_prompt` désactivé. Fichiers vérifiés par SHA256.

| Essai | Durée | Remarque |
|---|---|---|
| Prompt par défaut du template (portrait) | **42,55 s** | première génération : charge les modèles |
| Test 1 (ruelle de ramen) | 32,66 s | modèles déjà chargés |
| Test 2 (horloger) | 32,39 s | idem |
| Test 3 (bibliothèque) | 32,42 s | idem |
| Test 3 (bibliothèque) relancé après vidage des modèles et du cache | 37,82 s | rechargement des modèles |

- **Régime établi : ≈ 32,5 s par image** (≈ 1,3 s par étape, encodage du texte et VAE compris : je n'ai pas séparé ces temps). Très stable : 32,39 à 32,66 s sur trois prompts différents.
- **Coût du chargement : ≈ 5 s** (rechargement après vidage, 37,82 contre 32,42) **à ≈ 10 s** (toute première image). L'écart entre ces deux valeurs n'est pas expliqué : les prompts différaient, et je ne sais pas ce que « vider le cache » a vidé exactement.
- **VRAM pendant la génération** : 23 347 Mio utilisés sur 24 576 Mio (95 %), dont 22 682 Mio pour le processus ComfyUI et ≈ 600 Mio pour le bureau (gnome-shell, bureau à distance). GPU à 100 %, 298 W sur 300 W, 53 °C, état P2. Ces 22,7 Go ne sont pas le besoin réel du modèle (14,2 Go) : ComfyUI utilise la VRAM disponible pour garder des données en cache.
- **Qualité observée** (4 images) : très bonne fidélité sur un prompt long et descriptif ; texte court en gros caractères correct ; erreurs sur l'heure d'une horloge, sur un texte manuscrit de petite taille et sur une instruction de placement précise (« le chat sur le vélo »).
- **Mise en place** : `/root/.triton` n'est pas accessible en écriture pour l'utilisateur du conteneur, ce qui faisait échouer l'encodeur de texte (`PermissionError`). Contournement appliqué avec `docker exec` (perdu si le conteneur est recréé) ; correction durable à faire : variable `TRITON_CACHE_DIR` dans `comfyui/docker-compose.yml`.

Détail, exemples et pièges dans [image-generation.md](image-generation.md).

**Non mesuré** : durée par étape isolée ; résolutions supérieures à 1 mégapixel ; nombre d'étapes différent ; Q8_0 et INT8 comparés au BF16 (vitesse, qualité, VRAM) ; effet du bureau à distance sur la VRAM disponible ; dispersion sur plusieurs graines ; consommation moyenne sur une image complète.

## 2. Les réglages d'Ollama et ce qu'ils changent

| Réglage (`ai-stack/.env`) | Effet | Comment le mesurer |
|---|---|---|
| `OLLAMA_CONTEXT_LENGTH` | Taille de la fenêtre de contexte par défaut. Plus grand = plus de VRAM (cache KV) et un prefill plus long | `lab bench context-scaling` |
| `OLLAMA_KV_CACHE_TYPE` | `f16` (le plus précis), `q8_0` (≈ moitié de la mémoire du cache), `q4_0` (≈ quart ; qualité à surveiller) | `lab bench kv-cache` (vitesse + retrouver une info) et `kv-quality` |
| `OLLAMA_FLASH_ATTENTION` | Attention optimisée ; requise pour quantifier le cache KV | `kv-cache` (facteur `flash_attention`) |
| `OLLAMA_NUM_PARALLEL` | Requêtes servies en même temps. Chaque emplacement multiplie le cache KV | `lab bench concurrency` |
| `OLLAMA_KEEP_ALIVE` | Durée de maintien du modèle en VRAM. Évite les rechargements (le chargement de 17 Go prend de longues secondes) | observer `load_s` dans `runs.csv` |
| `OLLAMA_MAX_LOADED_MODELS` | Nombre de modèles en VRAM simultanément (2 avec un modèle de tâches) | `ollama ps` |

Les ordres de grandeur du cache KV (f16 > q8_0 > q4_0) sont des propriétés du format ; **les pertes de vitesse et de
qualité ne sont connues que partiellement : `kv-cache` et `kv-decode` (18 octobre) ont mesuré mémoire, vitesse et l'aiguille ; `kv-quality` (18 octobre) n'a montré aucune différence mais discrimine mal (3 calculs justes sur 12)**.

## 3. Marche à suivre (dans cet ordre)

1. **Environnement propre** : arrête le bureau à distance (`lab bureau off`), ferme les navigateurs et les applications
   graphiques lourdes. Vérifie `lab status` : le GPU doit être en `P8` au repos (≈ 20 W).
2. `lab bench quick-smoke` : s'assure que tout fonctionne (5 min).
3. `lab bench power-confirm` : confirme 300 W avec 15 répétitions (≈ 10 min). **Fait le 16 octobre : 300 W installé.**
4. `lab bench context-scaling` : coût du contexte, pour choisir `OLLAMA_CONTEXT_LENGTH`. **Fait le 18 octobre** (voir §1 bis).
5. `lab bench kv-cache` (**fait le 18 octobre**), puis `lab bench kv-decode` (**fait le 18 octobre**) et `lab bench kv-quality` (**fait le 18 octobre, peu informatif**), puis `lab bench kv-quality-easy` (**fait le 19 octobre**, 150 calculs faciles) : choisir f16 ou q8_0 en connaissance de cause.
   Puis `lab bench ctx-window` (taille de la fenêtre × type de cache : VRAM réservée et limite avant débordement) : **fait le 18 octobre**.
6. `lab bench concurrency` : seulement si tu comptes servir plusieurs requêtes en parallèle (n8n + Open WebUI + agents).
7. Après chaque changement dans `ai-stack/.env` : `cd ai-stack && docker compose up -d`, puis vérifie
   `docker exec ollama ollama ps` : le modèle doit rester à **100 % GPU**.

Durées indiquées dans `bench/README.md` : estimations, non mesurées sauf `power-sweep` (≈ 15 min réels).

## 4. Journal des décisions

| Date | Décision | Preuve |
|---|---|---|
| 2026-10-15 | Limite de puissance cible : 300 W | `power-sweep` (voir §1) |
| 2026-10-16 | **300 W confirmé** et installé en permanence (`lab gpu-limit install 300`) | `power-confirm`, 15 répétitions : −7 % vitesse, −7 % énergie/token, −11,5 % puissance moyenne (voir §1) |
| 2026-10-18 | `OLLAMA_CONTEXT_LENGTH` **inchangé** (32 768) : aucune mesure ne justifie de le modifier ; 65 536 reste possible par préréglage | `context-scaling` (§1 bis) : 100 % GPU à 65 536, génération stable, coût = délai avant le 1er token |
| 2026-10-18 | `OLLAMA_KV_CACHE_TYPE` **inchangé** (`q8_0`), à confirmer | `kv-cache` : VRAM ≈ 20 643 / 19 760 / 19 250 Mio (f16 / q8_0 / q4_0), préremplissage et TTFT identiques à < 1 %, aiguille 100 % partout ; décodage **invalide** (4 à 7 tokens) ; `kv-decode` : `f16` 58,6, `q8_0` 55,7 (5 mesures sur 6), `q4_0` 55,4 tok/s, écart `f16`/`q8_0` ≈ 5 % non démontré ; VRAM reproductible ; `kv-quality` : 30 (`f16`), 29 (`q8_0`), 30 (`q4_0`) réponses justes sur 120, aucune différence mais test peu discriminant (3 calculs justes sur 12) |
| 2026-10-18 | Fenêtre de contexte : **32 768 par défaut inchangé** ; 65 536 possible en `q8_0` avec le petit modèle ; 98 304 déconseillé | `ctx-window` : VRAM `q8_0` 19 045 / 19 065 / 19 769 / 21 147 / 22 555 Mio (8 192 → 98 304), `f16` 22 854 à 65 536 puis **débordement à 98 304** (81 % sur GPU, décodage 24 tok/s) ; pas de perte de vitesse détectable jusqu'à 65 536 |
| 2026-10-19 | Aucun réglage changé : le cache de préfixe d'Ollama fonctionne déjà (le début identique d'un prompt est relu 10 à 23 fois plus vite) | `prefix-cache` (f16) : TTFT chaud 0,56 / 0,63 / 0,81 s contre froid 1,4 / 6,5 / 18,9 s pour ≈ 950 / 7 400 / 21 500 tokens communs. Pour les agents : garder le début du prompt stable |
| 2026-10-19 | `lab update` : 6 images mises à jour (dont `ollama`), plus MinIO (Langfuse, non mémorisé pour `lab rollback`, corrigé) | `kv-decode` refait après la mise à jour : `f16` 57,6 tok/s (avant 58,6), `q8_0` 54,7 et `q4_0` 56,3 hors une mesure à ≈ 23 tok/s dans chacun ; VRAM identique ; aucune régression visible ; `q8_0` conservé |
| 2026-10-19 | `OLLAMA_KV_CACHE_TYPE` **`q8_0` confirmé** (choix maintenu) | `kv-quality-easy` : 147 (`f16`), 147-148 (`q8_0`), 148-149 (`q4_0`) bonnes réponses sur 150, aucune perte visible ; test peu sollicitant pour le cache (≈ 65 tokens par question) ; `q4_0` n'économise que 0,5 Gio de plus |
| 2026-10-19 | `OLLAMA_NUM_PARALLEL` **inchangé (1)** | `concurrency` : débit total ≈ 36-38 tok/s quel que soit le nombre de clients (1, 2, 4) et `NUM_PARALLEL` (1, 2, 4) ; premier token ≈ 1,1 / 2,9 / 6,4 s pour 1 / 2 / 4 clients ; VRAM identique : les demandes sont traitées l'une après l'autre ; cause : Ollama ignore `NUM_PARALLEL` pour `qwen35` (confirmé par `server-logs.txt`) |
| 2026-10-21 | Image : Qwen-Image-2.1 `UC-BF16.gguf` essayé dans ComfyUI | ≈ 32,5 s par image en 1024×1024 / 25 étapes (modèles chargés), VRAM 23,3 Gio sur 24 ; voir §1 ter |
| 2026-10-15 | Bureau à distance éteint par défaut (−100 W au repos) | `remote-desktop-gpu.md` |

Ajoute une ligne à chaque changement de réglage : date, décision, mesure qui la justifie.

## 5. Ce qui n'est pas mesuré

- `prefix-cache` et `concurrency` : mesurés en `f16` seulement ; pour `concurrency`, `NUM_PARALLEL` est ignoré par Ollama pour l'architecture `qwen35` (journal du serveur : « does not currently support parallel requests », `-np 1`) (`ctx-window` : mesuré, voir le journal) (`kv-cache` : VRAM et préremplissage ; `kv-decode` : vitesse de décodage)
  à ce jour (`context-scaling` : voir §1 bis). Ne choisis pas ces réglages sur des chiffres venus d'ailleurs.
- La limite de 300 W n'est confirmée que pour ce modèle et cette charge (génération, 2 048 tokens de contexte).
- L'effet du bureau à distance sur le bruit du `power-sweep` (supposé, non quantifié).
