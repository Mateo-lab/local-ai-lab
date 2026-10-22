# Impact du bureau à distance sur la consommation du GPU

Analyse réalisée le 15 octobre 2026 sur AiBeast (RTX 3090, pilote 595.99.02, Ubuntu 26.04).

## Résumé

Le service système `gnome-remote-desktop` (bureau à distance) maintenait la RTX 3090 dans l'état de performance
**P2 (calcul)** en permanence, même avec 0 % d'utilisation : **~123 W au repos** au lieu de **~17-23 W** (état P8).
L'arrêt du service a fait passer le GPU en P8 en moins de 20 secondes. Écart mesuré : **~100 W en continu**,
soit ~2,4 kWh/jour.

## 1. Symptôme

| Mesure | Valeur |
|---|---|
| Puissance au repos (banc d'essai, `quick-smoke`) | 123,3 W, 44 °C |
| Puissance au repos (banc d'essai, `power-sweep`) | 124,5 W |
| `nvidia-smi`, GPU à 0 % d'utilisation | P2, SM 1740 MHz, mémoire 9501 MHz, 124 W |
| Ventilateur | 53 % à 44 °C |
| VRAM utilisée sans modèle chargé | 777 à 1148 Mo |

Une RTX 3090 inactive est normalement en P8 (SM ~210 MHz) et consomme 15 à 40 W.

## 2. Diagnostic

`nvidia-smi` listait des processus marqués `C+G` (contexte graphique **et** contexte de calcul CUDA) :

| Processus | Type | VRAM |
|---|---|---|
| `gnome-remote-desktop-daemon` | C+G | 344 Mo |
| `ptyxis` (terminal) | C+G | 46 Mo |
| `resources` (moniteur système) | C+G | 31 Mo |
| `gnome-shell` (×2), `Xwayland` | G | 112 / 161 / 6 Mo |

Hypothèse : un contexte de calcul ouvert empêche le pilote de redescendre en P8. Le principal suspect était le
bureau à distance, qui est la plus grosse de ces applications.

## 3. Test

Le service actif était la version **système** (pas la version utilisateur) :

```bash
systemctl --user is-active gnome-remote-desktop.service   # inactive
systemctl is-active gnome-remote-desktop.service          # active
```

Test réalisé depuis une session SSH (pour ne pas être coupé), avec l'arrêt du service :

```bash
sudo systemctl stop gnome-remote-desktop.service
sleep 20
nvidia-smi --query-gpu=pstate,clocks.sm,power.draw --format=csv
```

| | État | SM | Puissance |
|---|---|---|---|
| Avant | P2 | 1740 MHz | 122,7 - 123,0 W |
| Après arrêt du service | **P8** | **210 MHz** | **17,2 - 23,3 W** |

**Conclusion : l'arrêt de ce service suffit à ramener le GPU au repos réel.** L'écart est d'environ **100 W**.
Cause établie par le test ; le mécanisme exact (contexte CUDA / encodage GPU de la capture) est une explication
probable, pas vérifiée dans le code du service.

## 4. Coût

Hypothèses : écart de 100 W, machine allumée 24 h/24, électricité à 0,30 €/kWh (à remplacer par ton tarif).

- 100 W × 24 h = **2,4 kWh/jour**
- ≈ **0,72 €/jour**, ≈ **260 €/an**
- Avec le bureau à distance laissé actif en continu. Pas de coût tant qu'il est éteint.

## 5. Effet sur les résultats du banc d'essai

Le `power-sweep` (49 mesures, qwen3.8:27b) a été réalisé **avec le bureau à distance actif**.

- **Comparaisons entre limites de puissance : valables.** Tous les niveaux ont subi les mêmes conditions.
- **Valeur absolue du J/token : légèrement gonflée.** Elle inclut la consommation de fond du GPU.
- **Bruit de mesure : plausiblement augmenté** (CV médian 9 %, plus petit écart détectable ~10,5 %).
- **Mesure de la puissance au repos : faussée** (124,5 W au lieu de ~20 W).

Conclusions du `power-sweep` (inchangées) : 300 W est le meilleur compromis (−9 % de vitesse de génération,
−10 % d'énergie par token), et au-dessous de 250 W on perd sur tous les tableaux. Une expérience de confirmation
(`power-confirm`, 15 répétitions à 350 / 300 / 250 W) est prévue **avec le bureau à distance éteint**.

## 6. Options

| Option | Effet | Commande |
|---|---|---|
| Éteint par défaut, démarré à la demande | économie complète, démarrage par SSH | `sudo systemctl start gnome-remote-desktop.service` |
| Ne pas le lancer au démarrage | idem après redémarrage | `sudo systemctl disable gnome-remote-desktop.service` |
| Toujours actif | confort, ~100 W de plus en continu | aucune |
| Autre outil d'accès à distance | à évaluer : certains gardent aussi un contexte de calcul | non vérifié |

Prérequis pour les deux premières options : un **accès de secours en SSH** (installé et testé le même jour :
`openssh-server`, accès par VPN depuis l'extérieur). Ne jamais arrêter le service depuis un terminal ouvert
*dans* le bureau à distance : la session se coupe.

## 7. Procédure de test reproductible

1. Se connecter en SSH depuis un autre appareil (pas via le bureau à distance).
2. Noter l'état : `nvidia-smi --query-gpu=pstate,clocks.sm,power.draw --format=csv`.
3. Arrêter le service : `sudo systemctl stop gnome-remote-desktop.service`, attendre 20 s, relire l'état.
4. Si le GPU reste en P2 : lister les contextes de calcul restants
   `nvidia-smi --query-compute-apps=pid,name,used_memory --format=csv`.
5. Rétablir : `sudo systemctl start gnome-remote-desktop.service`.

## 8. Limites et points non vérifiés

- Une seule machine, un seul pilote (595.99.02). Un autre pilote ou une autre version du service peut se comporter
  autrement.
- Le mécanisme précis (CUDA ou NVENC dans le service) n'est pas confirmé ; seule la corrélation « service arrêté →
  P8 » est mesurée.
- `ptyxis` et `resources` portent aussi un contexte `C+G`. Leur effet seul n'a pas été testé ; le test montre qu'ils ne
  suffisent pas à maintenir le GPU en P2 quand le bureau à distance est arrêté (ils étaient ouverts ou pas, non noté).
- Le coût annuel dépend entièrement du tarif et du temps d'allumage supposés.
- Le `power-sweep` n'a pas été refait sans bureau à distance au moment de cette note.

## Annexe : résultats du `power-sweep` (bureau à distance actif)

qwen3.8:27b, 7 répétitions par niveau, 2048 tokens de contexte rempli, 256 tokens générés, référence 350 W.

| Limite | Génération (tok/s) | vs 350 W | Prefill (tok/s) | J/token | Fréquence SM (MHz) |
|---|---|---|---|---|---|
| 350 W | 55,1 | référence | 1 238 | 7,6 | 1 591 |
| 300 W | 50,3 | −9 % | 1 166 | 6,8 | 1 419 |
| 250 W | 40,7 | −26 % | 1 059 | 7,4 | 1 088 |
| 220 W | 29,8 | −46 % | 889 | 8,5 | 855 |
| 200 W | 24,8 | −55 % | 750 | 9,2 | 662 |
| 180 W | 19,0 | −66 % | 575 | 10,9 | 506 |
| 150 W | 9,6 | −83 % | 316 | 17,7 | 245 |

La vitesse de génération suit presque proportionnellement la fréquence SM (≈ 0,035 à 0,039 tok/s par MHz).

## 9. Précision du 16 octobre : service actif sans session = GPU en veille

Le 16 octobre, `lab doctor` a relevé le service `gnome-remote-desktop` **actif** et le GPU pourtant en **P8 à 43 W**,
sans modèle chargé et sans session de bureau à distance ouverte (accès uniquement par SSH).

Conséquence : ce n'est probablement pas le service seul qui garde le GPU en P2, mais une **session de bureau à distance
ouverte** (et le contexte CUDA qu'elle crée). Le test du 15 octobre (arrêt du service → P8) avait lieu pendant que cette
session était en cours : il ne distinguait pas les deux causes.

Non encore mesuré : l'état du GPU **pendant** une session ouverte, puis **après sa fermeture** service actif. À tester :
ouvrir le bureau à distance, relever `nvidia-smi --query-gpu=pstate,power.draw --format=csv`, se déconnecter, relever à
nouveau après 30 s. En attendant, la règle prudente reste : fermer la session quand elle ne sert pas, et `lab bureau off`
si on ne s'en sert pas du tout. L'alerte `GpuBloqueEnP2AuRepos` signale le cas.
