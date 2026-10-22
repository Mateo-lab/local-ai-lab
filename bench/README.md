# Banc d'essai (labbench)

Mesurer de façon **reproductible et chiffrée** : vitesse du modèle, effet du cache KV, du contexte, du parallélisme,
et **perte de performance quand on bride la puissance du GPU**. Chaque résultat vient avec un intervalle de confiance
et des avertissements de validité.

```bash
./7-bench.sh check
./7-bench.sh run quick-smoke --model qwen3.8:27b       # ~5 min, vérifie que tout marche
./7-bench.sh run power-sweep --model qwen3.8:27b       # ~1 h
```

Résultats : `bench/results/<expérience>-<date>/` → `report.html` (à ouvrir dans le navigateur), `runs.csv` (une ligne par
mesure), `telemetry.csv` (GPU à 10 Hz), `summary.csv`, `comparisons.csv`, `meta.json`.

## Expériences fournies (`bench/experiments/*.yaml`)

| Nom | Question | Durée indicative* |
|---|---|---|
| `quick-smoke` | Est-ce que ça marche ? (300 W vs 200 W, 3 répétitions) | ~5 min |
| `power-sweep` | Combien de tok/s, de J/token et de °C perd-on à 350/300/250/220/200/180/150 W ? | ~1 h |
| `context-scaling` | Coût du prefill et de la génération selon la taille du contexte (512 → 56 000 tokens) | ~1 h |
| `ctx-window` | Taille de la fenêtre (`num_ctx` 8 192 → 98 304) × cache KV (`f16`/`q8_0`) : VRAM réservée, vitesse à vide, limite avant débordement sur le CPU | ~1 h* |
| `kv-cache` | Cache KV f16 / q8_0 / q4_0 : VRAM, préremplissage et capacité à retrouver une info dans 24 000 tokens (aiguille). **Sa vitesse de décodage est invalide** (4 à 7 tokens générés) : voir `kv-decode` | 22 min (mesuré) |
| `kv-decode` | Vitesse de décodage et VRAM par type de cache KV (f16 / q8_0 / q4_0), contexte rempli à 24 000 caractères, 128 tokens générés | 9 min (mesuré) |
| `kv-quality-easy` | Qualité sur 150 calculs faciles (même jeu pour les 3 caches) : détecte une perte d'au moins ≈ 5 points ; sollicite peu le cache (questions de ≈ 65 tokens) | ≈ 9 min (mesuré) |
| `kv-quality` | Qualité sur 12 calculs selon le type de cache KV (peu discriminant : le modèle n'en réussit que 3 sur 12) | ~30 min* |
| `prefix-cache` | Gain de TTFT quand un long début de prompt est réutilisé | ≈ 4 min (mesuré) |
| `concurrency` | `OLLAMA_NUM_PARALLEL` × nombre de clients : débit agrégé vs latence (enregistre aussi `server-logs.txt`) | ≈ 8 min (mesuré) |

\* estimations, non mesurées sur ta machine. `--dry-run` affiche le plan, `--reps N` change le nombre de répétitions.

Écrire sa propre expérience = copier un YAML. Facteurs possibles : `power_limit_w`, `kv_cache_type`, `flash_attention`,
`num_parallel`, `num_ctx`, `ctx_depth`, `gen_tokens`, `clients`, `needle_depth`, `think`. La grille est **factorielle**
(toutes les combinaisons des listes). Charges (`workload`) : `mixed`, `needle`, `prefix_cache`, `concurrency`, `arith`, `arith_easy`.

## Ce qui est mesuré

- **Génération** (tok/s), **prefill** (tok/s), **TTFT** (délai au 1er token), **latence inter-token** (p50/p95/p99) :
  durées rapportées par Ollama + chronométrage client en streaming.
- **GPU** : puissance, température, fréquences SM/mémoire, utilisation, VRAM, motifs de bridage (limite de puissance,
  thermique, ralentissement matériel), échantillonnés à 10 Hz.
- **Énergie** : compteur matériel NVML (exact), d'où J/token et tok/J. Inclut le prefill et la consommation au repos.
- **Placement** : part du modèle en VRAM d'après `/api/ps` (détecte un débordement sur CPU).
- **Qualité** (`needle`, `arith`) : proportion de réussites avec intervalle de Wilson.

## Méthode (pourquoi les chiffres sont fiables… ou pas)

1. **Plan randomisé** : l'ordre des mesures est mélangé (graine fixe, enregistrée) pour qu'une dérive thermique ne se
   confonde pas avec un facteur. Seuls les facteurs « serveur » (cache KV, flash attention, parallélisme) sont groupés en
   blocs, car chaque bloc redémarre le conteneur de test.
2. **Répétitions** (5 par défaut, 7 pour `power-sweep`) + échauffement non compté avant chaque bloc.
3. **Refroidissement** : on attend que le GPU repasse sous `cooldown.target_c` avant chaque mesure.
4. **Pas de triche du cache** : chaque prompt débute par un identifiant unique, sinon Ollama réutilise le cache de préfixe
   d'une mesure précédente (sauf dans `prefix_cache`, dont c'est l'objet).
5. **Statistiques** : moyenne ± IC 95 % (Student) ; variation par rapport à la référence en % avec IC bootstrap ; une
   différence est marquée **significative** (`*`, fond vert) seulement si l'IC exclut 0. Le rapport donne aussi le CV et
   le **plus petit écart détectable** : en dessous, une différence est du bruit.
6. **Avertissements automatiques** : peu de répétitions, bruit élevé (CV > 5 %), dérive temporelle (Spearman), bridage
   thermique ou matériel, modèle partiellement hors VRAM.
7. **Reprise** : si le test est interrompu, relance avec `--resume bench/results/<dossier>` : les mesures faites sont
   conservées. La limite de puissance d'origine est restaurée à la fin, même en cas d'erreur.

## Limites à connaître

- **Isolation** : pendant un test, rien d'autre ne doit utiliser le GPU. Le script arrête l'Ollama de production ; arrête
  aussi ComfyUI et Hermes. Le rapport signale un bruit élevé, mais ne peut pas deviner la cause.
- **Température ambiante, ventilation** : non contrôlées ; elles influencent le bridage thermique. Note-les.
- **Qualité** : `needle` et `arith` sont de petits tests (quelques dizaines d'essais) : ils détectent une dégradation
  marquée, pas une perte de 1 %. Pour une mesure de qualité rigoureuse (perplexité sur un corpus), il faudrait ajouter
  `llama-perplexity` de llama.cpp — non fait ici.
- **Un modèle « thinking »** (comme qwen3.8) : `think: false` par défaut pour mesurer la vitesse brute. Avec
  `think: true`, `gen_tokens` doit être grand, car le raisonnement consomme des tokens.
- **Limite de puissance** : réglée avec `sudo nvidia-smi -pl`. Le pilote peut arrondir ; la valeur réelle est
  relue et enregistrée (`power_limit_actual_w`).
- **Ollama** n'expose pas tous les réglages de llama.cpp (par ex. `-ctv` séparé du `-ctk`) : le type de cache K et V est
  commun.
- Les chiffres valent pour **cette machine, ce modèle, cette version d'Ollama** (enregistrée dans `meta.json`).

## Tests du banc lui-même

`python3 bench/tests/run_tests.py` : tests avec un faux serveur Ollama et un faux GPU (aucun matériel requis). Ils
vérifient la logique (plan, reprise, calculs, détection d'une perte simulée), **pas** le comportement réel de ton GPU.

## Livrer une nouvelle version sur AiBeast depuis le PC Windows

`windows\outils\Deployer-sur-AiBeast.bat` (double-clic, VPN connecté, clé SSH chargée) envoie `ai-lab.tar.gz` par `scp`, vérifie la
taille, **refuse de continuer si un banc d'essai tourne**, sauvegarde `bench`, `docs`, `windows`, `scripts` et `lab` dans
`~/avant-AAAAMMJJ-HHMM.tgz`, extrait dans `~/Documents`, puis compare chaque fichier de l'archive avec le disque.
Testé seulement côté AiBeast (script bash essayé dans un dossier factice) ; la partie PowerShell n'a jamais tourné sur ton PC.
