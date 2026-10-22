# Comprendre les mesures : quoi tester, pourquoi, et comment lire les résultats

Ce document explique **chaque réglage que le banc d'essai (`lab bench`) mesure** : ce que c'est, pourquoi ça vaut la peine
de le tester, comment lire le résultat, et ce que ta machine a donné. Il se termine par un glossaire.

Les chiffres de ta machine sont dans [performance.md](performance.md) ; le mode d'emploi du banc est dans
[`bench/README.md`](../bench/README.md). Ici : le « pourquoi » et le « comment lire ».

## 1. Pourquoi mesurer au lieu de deviner

Un réglage qui « paraît bon » peut coûter de la vitesse, de la mémoire ou de la qualité sans que ça se voie à l'usage.
Exemple vécu : la limite de puissance de 300 W est annoncée « sans perte » partout ; sur ta carte, elle coûte environ 7 % de
vitesse de génération (et fait gagner 7 % d'énergie par token). C'est un bon compromis, mais c'est un **compromis**, et
seule la mesure dit de combien.

Règle de la maison : **on change un réglage seulement quand une mesure le justifie, puis on note la décision** dans le
journal de [performance.md](performance.md) §4.

## 2. La carte : un réglage, une question, une expérience

| Réglage | La question | Expérience | Décision à la clé | État |
|---|---|---|---|---|
| Limite de puissance du GPU | Combien de vitesse perd-on en bridant la carte ? | `power-sweep`, `power-confirm` | Quelle limite installer (`lab gpu-limit`) | **Mesuré** : 300 W |
| Quantité de texte dans le contexte | Combien coûte un long document ? | `context-scaling` | Valeur de `OLLAMA_CONTEXT_LENGTH`, temps d'attente à prévoir | **Mesuré** |
| Taille de la fenêtre de contexte (`num_ctx`) | Combien coûte de **réserver** une grande fenêtre, même vide ? Où est la limite de la carte ? | `ctx-window` | Taille de fenêtre par défaut et par préréglage ; marge de VRAM | Mesuré le 2026-10-18 (voir §3.2 bis) |
| Type de cache KV (`f16`, `q8_0`, `q4_0`) | Combien de mémoire gagne-t-on, pour quelle perte de vitesse ou de justesse ? | `kv-cache` | Valeur de `OLLAMA_KV_CACHE_TYPE` | Mesuré le 2026-10-18 (décodage invalide, voir §3.3) |
| Qualité avec le cache KV quantifié | La quantification abîme-t-elle les réponses ? | `kv-quality` | Garder `q8_0` ou renoncer à `q4_0` | Mesuré les 2026-10-18 et 2026-10-19 (aucune perte visible, tests faibles, voir §3.4) |
| Cache de préfixe | Gagne-t-on du temps quand le début d'un prompt se répète ? | `prefix-cache` | Comment écrire les prompts des agents | Pas encore |
| Parallélisme | Peut-on servir plusieurs demandes en même temps ? | `concurrency` | Valeur de `OLLAMA_NUM_PARALLEL` | Pas encore |

## 3. Les réglages, un par un

### 3.1 Limite de puissance du GPU

**Ce que c'est.** Un plafond de watts que la carte ne dépasse pas (`nvidia-smi -pl`). L'usine règle la RTX 3090 à 350 W.

**Pourquoi tester.** Moins de watts, c'est moins de chaleur, moins de bruit, moins de consommation. Mais la carte baisse sa
fréquence pour respecter le plafond, donc elle calcule plus lentement. Le tout est de savoir **à partir de quand la perte de
vitesse n'est plus compensée par l'énergie économisée**.

**Ce qu'on mesure.** Vitesse de génération (tok/s), énergie par token (J/token), puissance moyenne, fréquence du GPU.

**Comment lire.**
- Compare la vitesse **et** l'énergie par token. Un plafond plus bas n'est intéressant que si l'énergie par token baisse aussi.
- Sous un certain seuil, les deux se dégradent : la carte tourne si lentement que l'énergie « fixe » (mémoire, ventilateurs,
  repos) pèse plus par token. Le brider davantage ne sert alors à rien.

**Ton résultat** (`qwen3.8:27b`, 2 048 tokens de contexte) : 300 W donne environ −7 % de vitesse, −7 % d'énergie par token,
−11,5 % de puissance moyenne ; 250 W perd un tiers de vitesse sans gain d'énergie. **300 W est installé en permanence.**

### 3.2 Le contexte : combien de texte la machine « garde en tête »

**Ce que c'est.** La fenêtre de contexte est la quantité de texte (conversation, document, consignes) que le modèle voit en
même temps, comptée en tokens. `OLLAMA_CONTEXT_LENGTH` fixe la taille par défaut ; un préréglage Open WebUI peut la modifier
(`num_ctx`).

**Pourquoi tester.** Un grand contexte permet d'analyser un long document, mais il a deux coûts : de la **mémoire** (le cache KV,
voir §3.3) et du **temps** (le modèle doit « lire » tout le texte avant de répondre : c'est le prefill).

**Ce qu'on mesure.** On remplit le contexte à 512, 4 096, 16 384, 32 768 et 56 000 tokens et on regarde : le délai avant le
premier mot (TTFT), la vitesse de lecture (prefill), la vitesse de génération, et si le modèle reste entièrement sur le GPU.

**Comment lire.**
- **TTFT** : c'est le temps d'attente ressenti. Il croît à peu près proportionnellement au texte à lire.
- **Vitesse de génération** : si elle reste stable quand le contexte grandit, un grand contexte ne ralentit pas les mots suivants.
- **Part du temps au GPU** (`gpu_frac`) : doit rester à 100 %. Si elle descend, une partie du modèle déborde sur le processeur
  et tout devient beaucoup plus lent.

**Ton résultat.** TTFT : 3,6 s à 4 096 tokens, 13,4 s à 16 384, 27,4 s à 32 768, 50,8 s à 56 000 (≈ 0,9 ms par token de prompt).
Génération stable (≈ 55 à 59 tok/s). 100 % GPU jusqu'à 65 536 de contexte, seul sur la carte. **Décision : `OLLAMA_CONTEXT_LENGTH`
inchangé (32 768).**

**Piège.** Ce test mesure la *quantité de texte dans la fenêtre*, pas la *taille de la fenêtre* : toute la série est à
`num_ctx` 65 536. L'effet de la taille de fenêtre sur la mémoire et la vitesse à vide n'a pas été comparé.

### 3.2 bis La taille de la fenêtre (à ne pas confondre avec son remplissage)

**Ce que c'est.** `num_ctx` est la taille de la fenêtre **réservée** ; le remplissage est le texte réellement présent dedans.
La mémoire du cache KV (§3.3) est dimensionnée sur la fenêtre, pas sur le texte, d'après ce que je comprends du fonctionnement
d'Ollama (non vérifié ici : c'est une des choses que ce test établit). Une fenêtre de 65 536 pour une conversation de 500 tokens
coûterait donc la même VRAM qu'une fenêtre pleine.

**Pourquoi tester.** `context-scaling` a mesuré le coût du *remplissage* dans une fenêtre fixe. Il ne dit rien de ce que coûte
la *taille* : combien de VRAM prend le passage de 32 768 à 65 536, quelle marge reste pour le modèle de tâches ou ComfyUI, et
à partir de quelle taille le modèle déborde sur le processeur.

**Ce qu'on mesure (`ctx-window`).** Cinq tailles (8 192, 16 384, 32 768, 65 536, 98 304) × deux types de cache (`f16`,
`q8_0`), avec un prompt court de 1 024 tokens pour ne mesurer que l'effet de la réservation : VRAM utilisée sur la carte
(`peak_mem_used_mb`), part du modèle en VRAM (`gpu_frac`), vitesse de génération, TTFT, taille de fenêtre réellement
appliquée (`ctx_effective` dans `runs.csv`).

**Comment lire.**
- **VRAM en fonction de `num_ctx`** : si elle augmente en ligne droite avec la taille, chaque 16 384 tokens de fenêtre coûte une
  quantité fixe ; tu en déduis la marge disponible pour une fenêtre donnée. Compare `f16` et `q8_0` : l'écart est le gain du cache
  compressé.
- **`gpu_frac` < 100 %** à une taille donnée : le modèle ne tient plus entièrement dans la carte. C'est la limite pratique,
  pas une erreur du banc.
- **`ctx_effective` inférieur à `num_ctx`** : le modèle plafonne sa fenêtre à son maximum. Au-delà, demander plus ne sert à
  rien.
- **Vitesse de génération et TTFT à vide** : s'ils bougent peu avec la taille, une grande fenêtre ne coûte que de la mémoire.

**Pièges.**
- `peak_mem_used_mb` est la VRAM de **toute la carte** : si autre chose l'utilise (ComfyUI, le bureau à distance, un autre
  modèle), le chiffre est faussé. Isole la carte comme pour les autres tests.
- Le banc recharge le modèle à chaque changement de taille (le test est groupé par taille pour limiter les rechargements).
- À lancer **après** `kv-cache` : le type de cache retenu détermine la ligne qui compte pour ta production.

**Ton résultat (`ctx-window`, 2026-10-18, 40 mesures, 4 répétitions par condition, prompt court, 128 tokens générés, 300 W).**

VRAM utilisée sur la carte (pic, Mio ; carte de 24 576 ; le banc tourne seul, production arrêtée) :

| `num_ctx` | `f16` | `q8_0` | Modèle sur le GPU |
|---|---|---|---|
| 8 192 | 19 284 | 19 045 | 100 % |
| 16 384 | 19 524 | 19 065 | 100 % |
| 32 768 | 20 644 | 19 769 | 100 % |
| 65 536 | 22 854 | 21 147 | 100 % |
| 98 304 | 22 682 (**débordement**) | 22 555 | **`f16` : 81 %** ; `q8_0` : 100 % |

- **La croissance n'est pas linéaire :** pour `q8_0`, passer de 8 192 à 16 384 ne coûte que 20 Mio, puis +704 (→ 32 768),
  +1 378 (→ 65 536), +1 408 (→ 98 304). Pour `f16` : +240, +1 120, +2 210. Ne pas extrapoler à partir de deux points.
- **`f16` déborde à 98 304 :** 19 % du modèle passe sur le processeur (la VRAM mesurée *baisse* parce que des couches sont
  parties), le décodage tombe de ≈ 50 à **24 tok/s**, le préremplissage de ≈ 1 070 à 785 tok/s, le TTFT monte à 1,45 s.
  Même type de cache : à 65 536 `f16` occupe déjà 22,9 Go ; avec le petit modèle de tâches (≈ 1,7 Gio) il ne tiendrait plus.
- **`q8_0` tient à 98 304** (22 555 Mio, soit ≈ 2,0 Gio de marge, vitesse inchangée), **mais seul** : avec le petit modèle de
  tâches chargé, la marge disparaîtrait (non mesuré). Mon estimation d'avant la mesure (≈ 21,7 Go) était trop basse d'environ 0,9 Go.
- **Vitesse :** jusqu'à 65 536, le décodage reste entre 48 et 54 tok/s pour les deux caches, écarts dans les marges d'erreur
  (4 répétitions) : réserver une grande fenêtre ne coûte pas de vitesse détectable, seulement de la mémoire, tant que tout tient.
  Le TTFT est de 0,97 s à 8 192 puis ≈ 1,11 à 1,14 s dès 16 384 et plat ensuite (cause inconnue, écart de 0,14 s).
- Le décodage de cette expérience (≈ 50 tok/s) est plus bas que celui de `kv-decode` (≈ 56-59) : protocoles différents (prompt
  court, 4 répétitions, fréquences GPU plus basses : 1 410-1 460 MHz contre ≈ 1 550). Ne compare pas les deux.

**Conséquences pour les réglages.** `OLLAMA_CONTEXT_LENGTH` reste à 32 768. Un préréglage à 65 536 est possible en `q8_0`
avec le petit modèle de tâches (22 620 Mio mesurés plus haut, §1 de `open-webui.md`) ; en `f16` non. 98 304 : `q8_0` seulement,
sans le petit modèle, et sans marge : non recommandé.

### 3.3 Le cache KV et sa quantification

**Ce que c'est.** Pour produire chaque nouveau mot, le modèle consulte des résultats intermédiaires de tout ce qui précède
(les « clés » et « valeurs » de l'attention, d'où KV). Plutôt que de les recalculer, il les garde en mémoire vidéo : c'est le
**cache KV**. Sa taille grandit avec le contexte. On peut le stocker en pleine précision (`f16`) ou en le compressant
(`q8_0`, environ moitié moins de mémoire ; `q4_0`, environ un quart). La compression de `q4_0` et `q8_0` s'appelle la
**quantification**. L'**attention flash** (`OLLAMA_FLASH_ATTENTION`) est une façon optimisée de calculer l'attention, requise
pour quantifier le cache.

**Pourquoi tester.** Ta carte a 24 Go de VRAM et le gros modèle en occupe une grande partie. Un cache plus petit libère de la
place (pour le modèle de tâches, pour un plus grand contexte, pour ComfyUI à côté). En contrepartie, il peut ralentir ou
dégrader les réponses : l'ampleur dépend du modèle, c'est pourquoi on mesure sur le **tien**.

**Ce qu'on mesure.** Pour `f16`, `q8_0` et `q4_0` : vitesse de génération et de prefill, VRAM, et un test de « l'aiguille » : on
cache une information à 10 %, 50 % ou 90 % d'un texte de 24 000 tokens et on demande au modèle de la retrouver (proportion
de réussites avec son intervalle d'incertitude).

**Comment lire.**
- Si `q8_0` n'est pas plus lent que `f16` **et** retrouve l'aiguille aussi souvent, il est préférable (même résultat, moins de
  mémoire). C'est la lecture que j'en fais, pas une règle démontrée.
- `q4_0` ne se justifie que s'il ne perd rien de visible ; la quantification la plus forte est celle qui risque le plus.
- Un taux de réussite qui baisse **surtout pour une position précise** de l'aiguille (par exemple 50 %, au milieu) est un signe
  que la compression gêne la récupération d'information dans un long texte.

**Ton résultat (`kv-cache`, 2026-10-18, 54 mesures, 22 min, contexte 32 768 rempli à ≈ 21 700 tokens, 300 W).**

| Cache | VRAM utilisée sur la carte (pic) | Préremplissage (tok/s) | TTFT (s) | Aiguille retrouvée |
|---|---|---|---|---|
| `f16` | ≈ 20 643 Mio | 1 170 | 19,44 | 100 % |
| `q8_0` (production) | ≈ 19 753-19 771 Mio | 1 160 | 19,35 | 100 % |
| `q4_0` | ≈ 19 241-19 259 Mio | 1 162 | 19,18 | 100 % |

- **Mémoire :** `q8_0` économise ≈ 0,9 Gio de VRAM par rapport à `f16`, `q4_0` ≈ 0,5 Gio de plus (valeurs lues dans `runs.csv`,
  carte entière, 595 Mio déjà utilisés au repos). Le cache f16 de 32 768 tokens pèse donc ≈ 1,9 Gio sur ce modèle
  (extrapolation à partir de ces écarts, non mesurée directement).
- **Préremplissage et TTFT :** `f16` est < 1 % plus rapide : sans intérêt pratique.
- **Justesse :** l'aiguille est retrouvée partout, `q4_0` compris. Test faible (un seul fait) : le verdict vient de `kv-quality`.
- **Décodage : à ne pas utiliser.** Le modèle ne générait que 4 à 7 tokens par requête (la réponse est un code de 6 caractères) ;
  la vitesse calculée sur si peu de tokens dépend du nombre de tokens (≈ 69 tok/s pour 4, 85-90 pour 5, 100-109 pour 6,
  ≈ 61 pour 7), pas du cache. À nombre de tokens égal (5), les médianes sont `f16` ≈ 90, `q8_0` ≈ 86, `q4_0` ≈ 85 tok/s :
  tendance (≈ 5 % pour `f16`), pas une preuve, et les blocs ont tourné l'un après l'autre (`q4_0`, `f16`, `q8_0`).
  La mesure propre est l'expérience `kv-decode` (ci-dessous).
- **J/token : sans signification ici** (≈ 5 000 J de toute la requête, préremplissage compris, divisés par 5 tokens).
  Deux mesures de `f16` (profondeur 10 %) ont un compteur d'énergie incohérent (707 et 3 763 J) avec des pics à 365-380 W.

**Ton résultat (`kv-decode`, 2026-10-18, 18 mesures, 9 min, 128 tokens générés à chaque requête, contexte ≈ 22 000 tokens, 300 W).**

| Cache | Décodage moyen (tok/s) | Médiane | Les 6 mesures (tok/s) | VRAM (Mio) |
|---|---|---|---|---|
| `f16` | 58,6 ± 3,0 | 59,0 | 54,4 à 62,5 | 20 643 |
| `q8_0` | 50,4 ± 13,8 (**55,7** sans la mesure 24,1) | 54,9 | 24,1 ; 51,4 ; 53,8 ; 56,1 ; 57,2 ; 59,8 | 19 771 |
| `q4_0` | 55,4 ± 2,4 | 55,0 | 53,2 à 58,9 | 19 263 |

- **Mesure aberrante :** une mesure de `q8_0` (la 2ᵉ du bloc) a duré 25,1 s au lieu de 21-22 s et décodé à 24 tok/s, avec un pic à
  305 W (au-dessus de la limite de 300 W). Cause inconnue (à-coup ponctuel). Sans elle, `q8_0` ≈ 55,7 tok/s (5 mesures).
- **Vitesse :** `f16` ≈ 5 % plus rapide que `q8_0` (58,6 contre 55,7 tok/s), `q4_0` ≈ `q8_0` (55,4). Le même ordre de grandeur
  (+5 % pour `f16`) était apparu à nombre de tokens égal dans `kv-cache`. **Ce n'est pas statistiquement établi** (l'écart de
  3 tok/s est du même ordre que la dispersion entre mesures, 6 mesures par cache, blocs exécutés l'un après l'autre).
- **VRAM :** identique au millième à `kv-cache` (reproductible) : `q8_0` économise 872 Mio, `q4_0` 508 Mio de plus.
- **J/token (42 à 50) :** ≈ 19,5 s de préremplissage pour ≈ 2,2 s de décodage ; l'énergie du seul décodage est de l'ordre de
  5 J/token (288 W ÷ 58 tok/s). Ne pas comparer avec d'autres expériences.

**Même test après la mise à jour d'Ollama (`kv-decode`, 2026-10-19, `lab update` du matin, 18 mesures).**

| Cache | Décodage moyen (tok/s) | Sans la mesure aberrante | Les 6 mesures (tok/s) | VRAM (Mio) |
|---|---|---|---|---|
| `f16` | 57,6 ± 2,6 | (aucune) 57,6 | 53,7 à 60,3 | 20 642 |
| `q8_0` | 49,6 ± 13,5 | 54,7 | 23,9 ; 51,0 ; 52,3 ; 55,9 ; 55,9 ; 58,5 | 19 771 |
| `q4_0` | 50,7 ± 14,3 | 56,3 | 23,0 ; 54,0 ; 55,5 ; 56,8 ; 56,8 ; 58,3 | 19 259 |

- **Pas de régression visible :** `f16` 57,6 contre 58,6 avant (dans la dispersion), VRAM identique à quelques Mio près. Ce test
  ne dit pas si l'image d'Ollama a réellement changé de version du moteur (la version n'est pas dans les fichiers reçus).
- **Mesures aberrantes :** `q8_0` et `q4_0` ont chacun une mesure à ≈ 23 tok/s (la 5ᵉ de leur bloc), avec 3 s de plus que les autres
  et une puissance moyenne plus basse. Déjà vu une fois pour `q8_0` le 18 octobre, jamais pour `f16` (3 fois sur 24 mesures
  quantifiées, 0 sur 12 en `f16`). Cause inconnue ; je n'ai pas de preuve que le cache quantifié en soit responsable, et 12 mesures
  en `f16` ne suffisent pas à l'exclure.
- **Conclusion inchangée :** `f16` ≈ 3 à 5 % plus rapide que les caches quantifiés hors aberrations, écart du même ordre que la
  dispersion ; `q8_0` reste en production pour ≈ 0,9 Gio de VRAM.
- **À propos de la colonne `itl_p50_ms` :** ≈ 0,018 ms, donc inutilisable. Le journal du serveur montre que le moteur démarre avec
  `--spec-type draft-mtp` (décodage spéculatif : plusieurs tokens validés d'un coup). Je n'ai pas mesuré l'effet de ce mode ; ne lis
  que `decode_tps` et `itl_p95_ms`.
- **Pourquoi la quantification économise peu :** le journal indique que seules 16 des 64 couches ont un cache KV
  (`f16` : 2 048 Mio à 32 768 de contexte, `q8_0` : 1 088, `q4_0` : 576) ; le reste est un état récurrent fixe de 748 Mio.

**Décision provisoire :** `q8_0` reste en production : ≈ 0,9 Gio de VRAM gagnés par rapport à `f16` pour une perte de décodage
d'environ 5 % (≈ 3 tok/s, non démontrée), aucune perte visible sur l'aiguille. `q4_0` ne va pas plus vite que `q8_0` et ne gagne que
0,5 Gio : à ne considérer qu'après `kv-quality`. Si la VRAM n'est jamais la limite, `f16` reste défendable.

### 3.4 Qualité avec le cache KV quantifié

**Ce que c'est.** Un test de justesse complémentaire à l'aiguille : 12 calculs d'arithmétique par mesure, 10 répétitions, pour
chaque type de cache, avec le raisonnement du modèle désactivé.

**Pourquoi tester.** Une réponse rapide mais fausse ne sert à rien. Ce test détecte une dégradation **marquée**.

**Comment lire.** Compare le taux de réussite entre `f16`, `q8_0` et `q4_0` (avec les intervalles de Wilson). Si les intervalles
se recouvrent, **tu ne peux pas dire que l'un est meilleur** : c'est du bruit.

**Ton résultat (`kv-quality-easy`, 2026-10-19, 150 calculs faciles, 2 répétitions par cache, ≈ 9 min, contexte 8 192).**

| Cache | Bonnes réponses (répétition 1 / 2) | Taux moyen | VRAM (Mio) |
|---|---|---|---|
| `f16` | 147 / 147 sur 150 | 98,0 % | 19 287 |
| `q8_0` | 148 / 147 | 98,3 % | 19 049 |
| `q4_0` | 149 / 148 | 99,0 % | 18 921 |

- **Aucune perte visible :** les trois caches sont à 98-99 %, l'écart maximal est de 2 questions sur 150, ce qui est du bruit
  (`q4_0` est même le premier, sans que cela veuille dire qu'il soit meilleur). Pour 147 réussites sur 150, l'intervalle à 95 % va
  d'environ 94 % à 99 % : le test ne verrait qu'une perte d'au moins ≈ 5 points.
- **Mais il sollicite peu le cache :** chaque question ne fait que ≈ 65 tokens ; la quantification a très peu de matière à
  abîmer. Ce test dit surtout que le modèle fonctionne normalement avec un cache quantifié, pas que `q4_0` tient sur de longs
  textes. Pour le long contexte, seule l'aiguille à ≈ 22 000 tokens (100 % pour les trois) y répond, et c'est un test faible.
- **Répétitions :** à température nulle on attendait des réponses identiques ; `q8_0` et `q4_0` diffèrent d'une question entre
  les deux répétitions (un identifiant aléatoire placé en tête de chaque prompt suffit à changer légèrement les calculs).
- **Conclusion :** `q4_0` n'a montré aucune dégradation sur les trois tests (aiguille longue, 12 calculs difficiles, 150 calculs
  faciles), mais ces tests sont faibles et il n'économise que 0,5 Gio de plus que `q8_0`. Je ne vois pas de raison de prendre ce
  risque : `q8_0` reste le choix.

**Limites.** 12 calculs, c'est peu : ça voit un effondrement, pas une perte de 1 %. Une mesure de qualité rigoureuse demanderait
un corpus de texte et une mesure de perplexité (non faite ici).

**Ton résultat (`kv-quality`, 2026-10-18, 12 calculs × 10 répétitions × 3 caches, contexte 8 192).**

| Cache | Taux de réussite moyen | Variabilité | VRAM (Mio) |
|---|---|---|---|
| `f16` | 25,0 % (3 calculs sur 12, **identique aux 10 répétitions**) | 0 | 19 289 |
| `q8_0` | 24,2 % (29 bonnes réponses sur 120) | 10,9 % | 19 049 |
| `q4_0` | 25,0 % (30 sur 120) | 22 % | 18 926 |

- **Aucune différence détectable** entre les trois caches : 29, 30 et 30 réponses justes sur 120.
- **Mais le test est peu informatif.** (1) Le modèle, sans raisonnement, ne réussit que 3 calculs sur 12
  (multiplication à 3 chiffres × 2 chiffres + 3 chiffres, réponse directe) : avec une base aussi basse, une dégradation
  de la qualité serait difficile à voir. (2) Les 12 questions et la graine sont fixes et la température est nulle : `f16`
  redonne exactement les mêmes réponses à chaque répétition, donc les 10 répétitions valent **une seule mesure**.
  (3) 12 questions : un écart de 1 ou 2 réponses n'est pas significatif.
- **Conclusion prudente :** ce test **ne prouve pas** que `q4_0` est sans danger ; il montre seulement qu'il n'y a pas
  d'effondrement visible sur ce test. Pour trancher, il faudrait des questions plus faciles (base proche de 100 %) et plus
  nombreuses. C'est l'expérience **`kv-quality-easy`** (150 calculs faciles, mêmes questions pour les trois caches, 6 mesures) :
  mesurée le 2026-10-19 (résultat ci-dessous).
- **Vitesse et énergie de cette expérience : à ignorer** (réponses de quelques tokens, voir §4.3 bis).
- **VRAM à 8 192 de contexte :** `f16` 19 289, `q8_0` 19 049, `q4_0` 18 926 Mio. J'en avais déduit une taille de cache « par
  token » en supposant une croissance linéaire ; **`ctx-window` a montré que c'est faux** (voir §3.2 bis : la croissance n'est pas
  linéaire). Ne retiens pas cette extrapolation.

### 3.5 Le cache de préfixe

**Ce que c'est.** Quand une nouvelle demande commence exactement comme la précédente (mêmes consignes, même début de
conversation), Ollama peut réutiliser le travail déjà fait sur ce début au lieu de le relire.

**Pourquoi tester.** Pour les agents (Hermes, OpenClaw), qui renvoient à chaque tour un long début identique (consignes système,
outils, historique), le gain de temps peut être important. À l'inverse, un début qui change à chaque fois annule le bénéfice.

**Ce qu'on mesure.** Le TTFT quand le début est déjà connu, avec 1 024, 8 192 et 24 000 tokens de préfixe commun.

**Comment lire.** Un TTFT qui chute quand le préfixe est réutilisé signifie que **l'ordre des éléments du prompt compte** :
mets ce qui ne change pas **au début**, ce qui change à la fin.

**Ton résultat (`prefix-cache`, 2026-10-19, 18 mesures, ≈ 4 min, cache KV en `f16` : la valeur par défaut du banc, pas celle de ta production `q8_0`).**
Chaque mesure envoie deux demandes qui partagent le même long début : la 1re est « froide », la 2e « chaude ».

| Début commun (tokens réels) | TTFT froid | TTFT chaud | Gain |
|---|---|---|---|
| ≈ 950 | 1,39 s (très variable : 1,1 à 1,8) | 0,56-0,58 s | × 2,5 (± 0,6) |
| ≈ 7 400 | 6,52 s | 0,62-0,64 s | × 10,3 (± 0,5) |
| ≈ 21 500 | 18,87 s | 0,81 s | **× 23,3** (± 0,4) |

- **Le gain augmente avec la longueur du début commun** parce que le coût d'une demande chaude reste presque fixe (0,56 s à 0,81 s)
  alors que celui d'une demande froide croît avec le texte. Pour un agent qui renvoie ≈ 20 000 tokens identiques à chaque tour, le
  premier token arrive en moins d'une seconde au lieu de 19 s.
- **Condition :** le début doit être **identique caractère pour caractère** et au **début** du prompt (une date, un identifiant ou un
  horodatage placé en tête annule le gain), et le modèle doit rester chargé (30 min par défaut ici).
- **Non mesuré :** avec le cache `q8_0` de ta production, avec plusieurs conversations en parallèle (voir `concurrency`), et dans
  les vrais clients (Hermes, OpenClaw, Open WebUI) : je ne sais pas s'ils gardent leur début stable.
- **Défaut du banc corrigé :** la colonne « part du préfixe réutilisée » (`cache_reuse_frac`) valait 0 partout parce
  qu'Ollama renseigne le nombre de tokens du prompt **complet** même quand il en réutilise une grande partie. Le calcul
  se fait désormais sur les temps de lecture du prompt (18,4 s contre 0,73 s, soit 96 % évités à 21 500 tokens). Pour le run déjà
  fait, ignore cette colonne et lis `cold_prompt_eval_s` / `warm_prompt_eval_s` dans `runs.csv`. Le correctif n'est vérifié que par la
  suite de tests, pas sur le GPU.
- Vitesse de décodage et J/token de cette expérience : sans objet (32 tokens, énergie dominée par la lecture du prompt).

### 3.6 Le parallélisme

**Ce que c'est.** `OLLAMA_NUM_PARALLEL` fixe combien de demandes le même modèle traite en même temps. Chaque « emplacement »
supplémentaire multiplie le cache KV.

**Pourquoi tester.** n8n, Open WebUI et les agents peuvent demander quelque chose simultanément. Il faut savoir si le
parallélisme augmente le travail total par seconde (le **débit agrégé**) ou si chacun attend plus longtemps pour rien.

**Ce qu'on mesure.** `NUM_PARALLEL` de 1, 2 et 4 avec 1, 2 et 4 clients simultanés : débit total et latence par client.

**Comment lire.** Le bon réglage est celui où le débit total progresse sans que la latence d'un client devienne pénible. Plus
d'emplacements coûte de la VRAM : vérifie toujours que le modèle reste à 100 % GPU (`ollama ps`).

**Ton résultat (`concurrency`, 2026-10-19, 45 mesures, ≈ 8 min, cache KV `f16`, contexte 16 384, prompt ≈ 1 000 tokens, 128 tokens par client).**

| Clients simultanés | Premier token (moyenne, `NUM_PARALLEL` 1 / 2 / 4) | Débit total (tok/s) |
|---|---|---|
| 1 | 1,14 / 1,13 / 1,11 s | 36,1 / 38,1 / 36,4 |
| 2 | 2,86 / 2,90 / 2,87 s | 36,6 / 36,7 / 36,6 |
| 4 | 6,40 / 6,33 / 6,42 s | 36,2 / 36,9 / 36,4 |

- **Les demandes sont traitées l'une après l'autre, quel que soit `NUM_PARALLEL`.** Le débit total reste à ≈ 36-38 tok/s (il
  ne progresse pas avec les clients), la vitesse de chaque client reste à ≈ 54 tok/s quand il est servi, et le premier token
  arrive de plus en plus tard : avec 4 clients, la durée totale est ≈ 4 fois celle d'un client (13,9 s contre 3,5 s).
- **`NUM_PARALLEL=2` ou `4` n'a eu aucun effet mesurable, ni sur la vitesse, ni sur la mémoire** (VRAM 19 521 à 19 523 Mio dans
  les trois cas, alors que quatre emplacements devraient réserver quatre fois plus de cache). **Cause confirmée par le journal du serveur**
  (`server-logs.txt`, relevé le 2026-10-19 avec `NUM_PARALLEL` 4 et 2) : Ollama écrit
  `model architecture does not currently support parallel requests architecture=qwen35`, puis lance le moteur avec `-np 1`
  (un seul emplacement, `n_slots = 1`). Le réglage est donc ignoré pour ce modèle (architecture `qwen35`) dans cette version
  d'Ollama. Ça pourrait changer avec une mise à jour d'Ollama ou un autre modèle : à re-tester alors.
- **Conséquence pratique :** ne monte pas `OLLAMA_NUM_PARALLEL` en espérant servir plusieurs demandes plus vite : ici, rien n'est
  gagné. Avec `NUM_PARALLEL=1` (valeur actuelle), deux demandes simultanées (n8n et Open WebUI par exemple) se mettent en file :
  la seconde attend la fin de la première (≈ 3,5 s pour une réponse de 128 tokens), sans erreur.
- Mesuré en `f16`, avec un seul modèle chargé ; le cache de préfixe (§3.5) n'a pas été testé avec plusieurs clients.

## 4. Lire un rapport sans se tromper

### 4.1 Les fichiers

| Fichier | Contenu | À utiliser pour |
|---|---|---|
| `summary.csv` | Valeurs **absolues** par condition (tok/s, secondes, watts…), avec intervalle de confiance et CV | Savoir « combien » |
| `comparisons.csv` | Écarts **en pourcentage par rapport à la référence** | Savoir « mieux ou moins bien que la référence » |
| `runs.csv` | Une ligne par mesure | Chercher une mesure aberrante |
| `telemetry.csv` | État du GPU à 10 mesures par seconde | Comprendre un bridage ou une chaleur |
| `report.html` | Tout cela avec graphiques et avertissements | Lecture générale |
| `meta.json` | Réglages réellement utilisés, version d'Ollama | Vérifier dans quelles conditions la mesure a été faite |

### 4.2 Les quatre questions à poser à chaque chiffre

1. **Quelle est la marge d'erreur ?** Une valeur sans intervalle de confiance n'est qu'un chiffre. Si les intervalles de deux
   conditions se recouvrent, la différence n'est pas démontrée.
2. **Est-ce significatif ?** Le rapport marque une différence « significative » seulement si l'intervalle de l'écart exclut 0.
3. **Est-ce plus grand que le bruit ?** Le rapport donne le **plus petit écart détectable** : en dessous, une différence est
   indistinguable du hasard. Pour ta machine à l'époque du `power-sweep` : ≈ 10,5 %.
4. **La référence est-elle fiable ?** Un pourcentage n'a de sens que si la référence est bonne (voir §4.3).

### 4.3 Un piège rencontré en vrai (`context-scaling`)

`comparisons.csv` annonçait que la génération était **+19 % à +22 % plus rapide** avec un grand contexte que la référence.
C'est contre-intuitif : plus de texte ne devrait pas accélérer la génération. En lisant `summary.csv`, la cause apparaît : le
point de référence (512 tokens) est anormalement lent (48,6 tok/s contre ≈ 58), avec une puissance et une fréquence plus basses :
des essais très courts, GPU pas encore monté en régime. Les pourcentages en héritent. **Moralité : quand un résultat est
contre-intuitif, regarde les valeurs absolues avant de conclure.**

### 4.3 bis Un deuxième piège rencontré en vrai (`kv-cache`)

Une vitesse de décodage calculée sur **4 à 7 tokens** n'est pas une vitesse : elle change avec le nombre de tokens (de 61 à
109 tok/s dans le même run) et ses marges d'erreur sont énormes. Avant de lire `decode_tps`, ouvre `runs.csv` et regarde la
colonne `gen_tokens` : il en faut au moins plusieurs dizaines. Les expériences à base d'aiguille (réponse d'un code) ne
mesurent pas le décodage ; la charge `mixed` (long texte demandé) le fait. Même réflexe pour les joules par token : si
`energy_j` couvre un préremplissage de 19 s pour 5 tokens générés, le résultat (> 1 000 J/token) n'a aucun sens.

### 4.4 Les avertissements automatiques du rapport

Le rapport signale : trop peu de répétitions ; bruit élevé (CV > 5 %), donc machine pas isolée ; dérive dans le temps
(la vitesse change avec l'ordre des mesures) ; bridage thermique ou matériel ; modèle partiellement sur le processeur. Un
avertissement ne dit pas la cause : à toi de chercher (une application en arrière-plan, la température de la pièce…).

### 4.5 Les conditions d'une bonne mesure

- **Machine isolée** : le banc arrête l'Ollama de production ; arrête aussi ComfyUI et Hermes, et laisse le bureau à distance
  éteint (il consomme ≈ 100 W et fausse la comparaison).
- **Modèle explicite** : passe toujours `--model qwen3.8:27b`. Sans cela, `lab bench` prend le premier modèle chargé, qui peut
  être le petit modèle de tâches.
- **Même modèle, même version d'Ollama** que ceux que tu utilises : les résultats ne se transportent pas d'un autre modèle.
- **Noter l'état de la machine** (bureau à distance, température de la pièce) pour pouvoir comparer plus tard.

## 5. Glossaire

| Terme | Définition |
|---|---|
| **Token** | Morceau de texte (mot, partie de mot, ponctuation) : l'unité que le modèle lit et écrit. Environ 3 à 4 caractères en français. |
| **Prompt** | Tout le texte envoyé au modèle pour une demande : consignes, historique, documents, question. |
| **Contexte / fenêtre de contexte** | Quantité maximale de tokens que le modèle considère à la fois (prompt + réponse). |
| **Réservation vs remplissage** | `num_ctx` réserve la fenêtre ; le remplissage est le texte qui s'y trouve vraiment. Le temps d'attente suit le remplissage, la mémoire suit (en principe) la réservation. |
| **`num_ctx`** | Réglage Ollama de la taille de cette fenêtre pour une demande. `OLLAMA_CONTEXT_LENGTH` donne la valeur par défaut. |
| **Prefill** | Phase où le modèle **lit** le prompt avant de répondre. Se mesure en tokens lus par seconde. |
| **Génération (decode)** | Phase où le modèle **écrit** la réponse, token après token. Se mesure en tokens/s. |
| **tok/s** | Tokens par seconde : la vitesse. |
| **TTFT** (*time to first token*) | Délai entre l'envoi de la demande et le premier token de la réponse : l'attente ressentie. Dépend surtout du prefill. |
| **ITL** (*inter-token latency*) | Délai entre deux tokens successifs ; sa valeur p95 dit que 95 % des délais sont inférieurs. |
| **p50 / p95 / p99** | Percentiles : valeur en dessous de laquelle se trouvent 50 %, 95 %, 99 % des mesures. Le p95 décrit les « mauvais jours ». |
| **Cache KV** | Mémoire où le modèle garde les résultats intermédiaires de tout le texte déjà vu pour ne pas les recalculer. |
| **Quantification** | Stockage compressé (moins de bits par valeur) : moins de mémoire, au prix éventuel de précision. |
| **`f16` / `q8_0` / `q4_0`** | Précision du cache KV : 16 bits (pleine), 8 bits, 4 bits. |
| **Attention flash** | Méthode de calcul de l'attention plus économe en mémoire et plus rapide ; requise pour quantifier le cache KV. |
| **VRAM** | Mémoire vidéo de la carte (24 Go sur la 3090) où vivent le modèle et le cache KV. |
| **100 % GPU** | Tout le modèle est dans la VRAM. Moins que cela = une partie sur le processeur, nettement plus lent. |
| **Limite de puissance (`power limit`)** | Plafond en watts imposé au GPU. |
| **Fréquence SM** | Vitesse d'horloge des unités de calcul du GPU (en MHz) ; elle baisse quand la carte est bridée. |
| **Bridage (`throttling`)** | Baisse automatique de fréquence, due à la limite de puissance, à la température, ou à une protection matérielle. |
| **J/token** | Énergie par token généré (joules). Dans nos mesures elle **inclut le prefill** : un long prompt la fait exploser sans que la génération devienne moins efficace. |
| **État `P8`** | Mode repos du GPU (≈ 20 W). Un GPU qui n'y retourne pas indique une charge de fond. |
| **Répétition** | Une mesure refaite dans les mêmes conditions, pour estimer le bruit. |
| **Échauffement (`warmup`)** | Mesure non comptée faite avant, pour que le modèle et la carte soient prêts. |
| **Refroidissement (`cooldown`)** | Attente que le GPU redescende à une température cible entre deux mesures. |
| **Référence (`baseline`)** | Condition à laquelle on compare les autres. |
| **Facteur** | Réglage qui varie d'une condition à l'autre dans une expérience. |
| **Plan factoriel** | Toutes les combinaisons des valeurs des facteurs. |
| **Intervalle de confiance à 95 % (IC)** | Fourchette dans laquelle la vraie valeur se trouve avec 95 % de probabilité, d'après l'échantillon. |
| **CV** (coefficient de variation) | Dispersion relative des mesures (écart-type ÷ moyenne). Plus il est grand, plus c'est bruité. |
| **Significatif** | Écart dont l'IC exclut 0 : peu probablement dû au hasard. |
| **Plus petit écart détectable** | Taille minimale d'écart que ce nombre de répétitions permet de distinguer du bruit. |
| **Intervalle de Wilson** | Intervalle de confiance adapté aux proportions (taux de réussite). |
| **Aiguille (`needle`)** | Test de récupération : une information cachée dans un long texte, que le modèle doit retrouver. |
| **Cache de préfixe** | Réutilisation du travail fait sur un début de prompt identique entre deux demandes. |
| **`OLLAMA_NUM_PARALLEL`** | Nombre de demandes traitées simultanément par le même modèle. |
| **`OLLAMA_KEEP_ALIVE`** | Durée pendant laquelle un modèle reste en VRAM après sa dernière utilisation (30 min ici). |
| **`OLLAMA_MAX_LOADED_MODELS`** | Nombre de modèles chargés en même temps (2 avec le modèle de tâches). |
| **Perplexité** | Mesure rigoureuse de la qualité d'un modèle sur un texte ; non faite ici. |

## 6. Ce qui n'est pas vérifié

- Les définitions du §5 et les explications du §3 sont des explications générales ; elles ne proviennent pas de mesures sur ta
  machine. Seuls les paragraphes « Ton résultat » le sont.
- Les chiffres « environ moitié » et « environ un quart » du cache quantifié sont des propriétés du format, pas des
  mesures de ta machine. La VRAM gagnée a été lue dans `runs.csv` de `kv-cache` (voir §3.3).
- Les critères de choix du §3.3 (garder `q8_0` s'il n'est pas plus lent et retrouve l'aiguille aussi bien) sont ma proposition de
  lecture, pas une règle établie.
- `prefix-cache` et `concurrency` ont été mesurés en cache `f16` seulement ; `NUM_PARALLEL` est ignoré par Ollama pour l'architecture `qwen35` (confirmé par le journal).
- `ctx-window` : 4 répétitions seulement par condition ; la combinaison « 98 304 + petit modèle de tâches » et la valeur réellement appliquée de `num_ctx` à 98 304 (colonne `ctx_effective` de `runs.csv`) n'ont pas été vérifiées.
- J'ai ajouté la colonne `peak_mem_used_mb` aux tableaux du rapport (`bench/labbench/report.py`) ; elle n'a été testée qu'avec la suite de tests à faux GPU, pas sur un vrai rapport. En cas de doute, la colonne est dans `runs.csv`.
- Les résultats de `power-sweep` et `power-confirm` ont été obtenus avec le bureau à distance dans un état non noté pour le
  second ; leur comparaison avec `context-scaling` (génération à 58 tok/s contre 50 mesurés au `power-sweep`) reste inexpliquée.
