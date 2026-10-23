# Développer du code avec Hermes : code → test → review → fusion

Objectif : qu'Hermes écrive du code **et le teste lui-même**, qu'un autre sous-agent le relise, et que **toi seul** décides de la fusion.
Tout est local sur AiBeast (git local, rien sur GitHub), pour n'importe quel langage.

## 1. Le principe en une image

```
toi ── lab dev start PROJET ──▶ Hermes (dans le conteneur-bac à sable, dossier du projet)
                                  │ branche agent/<sujet>
                                  │ pour chaque petite tâche : test qui échoue → code → ./scripts/check → commit
                                  │ sous-agent NEUF : relecture « conforme au plan ? » puis « qualité ? »
                                  │ compte rendu docs/reviews/<sujet>.md  (+ BLOCKED.md si bloqué)
toi ◀── lab dev review PROJET ───┘
toi ── lab dev merge PROJET agent/<sujet> ──▶ check relancé dans le bac à sable → tu confirmes → fusion --no-ff dans main
```

Deux garde-fous distincts : **l'agent ne touche pas à `main`** (règle écrite dans `AGENTS.md`, que Hermes lit), et **`lab dev merge`
refuse de fusionner si `scripts/check` échoue**, quoi que l'agent affirme dans son compte rendu.

## 2. Mise en route (une fois)

```bash
lab dev ctx64        # variante du modèle avec 65 536 de contexte (voir §5) et config Hermes pointée dessus
lab dev setup        # sous-agents un par un + compétence de relecture en deux passes
lab dev new essai python     # python | node | shell | autre
lab dev start essai          # ouvre Hermes DANS le projet
```
Premier message conseillé : *« Lis AGENTS.md. Ajoute une fonction slugify(texte) avec ses tests, en suivant le déroulement du fichier. »*
Puis `/exit`, et : `lab dev review essai`.

## 3. Commandes

| Commande | Effet |
|---|---|
| `lab dev new NOM [python\|node\|shell\|autre]` | Dossier `hermes/data/workspace/projects/NOM` : dépôt git (`main`), `AGENTS.md`, `scripts/check`, `tests/`, `docs/plans/`, `docs/reviews/` |
| `lab dev list` | Projets, branche courante, fichiers non commités, branches `agent/*` à relire |
| `lab dev start NOM [MODELE]` | Hermes ouvert dans le projet. Modèle : celui donné, sinon `LAB_MODEL`, sinon **le plus gros modèle installé** (jamais le petit modèle de tâches d'Open WebUI ni un modèle d'embeddings, à taille égale la variante `-64k`). La config de Hermes (`model.default`) est alignée sur ce choix, copie `config.yaml.avant-modele` |
| `lab dev review NOM [BRANCHE [--diff]]` | Sans branche : liste. Avec : commits, fichiers, compte rendu de l'agent ; `--diff` : diff complet |
| `lab dev check NOM [BRANCHE]` | `scripts/check` **dans le bac à sable** (bascule sur la branche si donnée, arbre propre exigé) |
| `lab dev merge NOM BRANCHE [--yes]` | Check → diffstat → confirmation → `merge --no-ff` dans `main` → branche supprimée. Conflit : fusion annulée |
| `lab dev setup` | Ajoute le bloc `delegation` à `hermes/data/config.yaml` (copie `.avant-dev`) et installe la compétence `subagent-driven-development` |
| `lab dev ctx64 [MODELE]` | Crée `MODELE-64k` (`num_ctx 65536`) et le met comme modèle de Hermes (copie `.avant-ctx64`) |

## 4. Ce que fait `scripts/check` (un seul point d'entrée, tous langages)

Il détecte ce qui existe et **échoue si aucun test n'a tourné** (un projet sans test ne passe pas) :
Python (syntaxe, `pytest` s'il est installé, sinon `unittest`, `ruff` s'il est installé), Node (`npm test`, `npm run lint` s'il existe),
shell (`bash -n`, `shellcheck` s'il est installé, `tests/*.sh`). Autre langage : écris `tests/run.sh`. Adapte le fichier à ton
projet, mais **ne l'affaiblis pas pour faire passer un test** (c'est écrit dans `AGENTS.md`).
Sans `pytest`, les tests Python doivent être des classes `unittest.TestCase` ; sinon aucun test n'est trouvé et le check échoue.

## 5. Choix de conception et pourquoi

- **Sous-agents un par un** (`max_concurrent_children: 1`). Mesuré le 2026-10-19 (`concurrency`) : Ollama traite une requête à la fois pour
  ce modèle, quel que soit `NUM_PARALLEL`. Par défaut Hermes lance jusqu'à 10 sous-agents en parallèle ; ils feraient la queue, et
  Hermes abandonne un sous-agent sans progrès depuis 450 s (valeur de sa documentation, non testée ici).
  Il n'y a donc aucun gain de vitesse à les paralléliser. *Hypothèse non mesurée :* alterner des sous-agents aux contextes différents oblige
  Ollama à recalculer le début du prompt à chaque changement, ce qui coûte du temps (le cache de préfixe ne sert que pour un début identique).
- **Relecture par un sous-agent neuf** : un sous-agent démarre sans mémoire, donc il juge le code sans le biais de celui qui l'a écrit.
  C'est le même modèle des deux côtés : la relecture attrape des oublis, **pas toutes les erreurs de raisonnement du modèle**. D'où ta relecture
  finale du diff et le check relancé par `lab dev merge`.
- **Contexte de 65 536.** Hermes exige au moins 64 000 tokens, alors qu'Ollama sert 32 768 par défaut (`OLLAMA_CONTEXT_LENGTH`). L'API
  compatible OpenAI (`/v1`) que Hermes utilise ne permet pas de demander `num_ctx` ; la variante `MODELE-64k` règle donc la taille dans le
  modèle lui-même. Mesuré (`ctx-window`, cache `q8_0`) : 21 147 Mio de VRAM à 65 536 avec le modèle `qwen3.8:27b` seul sur la carte ; la combinaison
  « 65 536 + petit modèle de tâches + Open WebUI » n'a pas été mesurée.
- **Le code agent ne s'exécute jamais sur AiBeast, hors bac à sable.** Les tests tournent dans le conteneur Hermes. Les commandes git lancées par
  `lab dev` sur l'hôte ignorent les hooks, et refusent un dépôt dont `.git/config` contient autre chose que le minimum (l'agent peut écrire dans
  `.git/` : une option comme `core.fsmonitor` ou un alias exécuterait une commande sur l'hôte). Testé par `scripts/test-dev.sh`.
- **Git local, pas de GitHub** : aucun jeton à protéger. Pour publier plus tard : `git push` fait par toi, depuis `main`, après relecture.

## 6. Quand l'agent est bloqué ou se trompe

- `BLOCKED.md` dans le projet : l'agent s'est arrêté après 3 échecs (règle d'`AGENTS.md`) ; `lab dev review` le signale.
- Branche qui échoue au check : `lab dev merge` s'arrête et te laisse sur la branche ; relance `lab dev start` et demande la correction.
- Compte rendu trop optimiste : `lab dev check NOM agent/…` le contredit en une commande. Lis le diff, pas seulement le compte rendu.
- Projet mal parti : `git -C hermes/data/workspace/projects/NOM log --oneline --all` ; tout est dans git, rien n'est perdu. La sauvegarde
  (`lab backup run`) inclut les projets (ils sont dans `hermes/data`).

## 7. Tests de ce dispositif

`bash scripts/test-dev.sh` (sans Docker ni Hermes) : création, nom invalide, review, check qui passe, fusion et signature, refus si le check
échoue, refus avec fichiers non commités, configuration git piégée (commande non exécutée), hooks ignorés, `.git` en lien. Il a trouvé deux
défauts de `scripts/check` avant livraison (détection de Python, tests `pytest` sans `pytest`).

## Premier essai réel (2026-10-19, projet `essai`, tâche « slugify »)

Vérifié sur AiBeast :
- `lab dev new`, `lab dev start` (bon modèle après correction), `lab dev review` et `lab dev check` fonctionnent. Le check s'exécute dans le conteneur Hermes
  (`bash`, `python3` 3.14 et `unittest` présents) : **10 tests, OK**, relancés par `lab dev check`, pas seulement annoncés par l'agent.
- Hermes a produit une branche `agent/slugify` (4 commits : fonctionnalité + tests, test complété, docstring, compte rendu) et un compte rendu qui respecte le plan
  d'`AGENTS.md` (conformité PASS, qualité APPROUVÉ, section « ce qui n'a pas été vérifié »). Le contenu du code n'a pas été relu par moi.
- Dans le bac à sable : `pytest`, `ruff` et `shellcheck` sont **absents** (les tests Python doivent donc être des classes `unittest`, et ruff/shellcheck ne tournent pas).

Non mesuré : durée de la tâche, nombre de tours de relecture, qualité du code sur une tâche moins simple.

## Ce qui n'est pas vérifié

- **Blocage observé le 2026-10-19 :** `lab dev check` affichait « check : tout est bon » puis ne rendait pas la main (Ctrl+C nécessaire ; aucun conteneur orphelin ensuite).
  Correctif appliqué : l'entrée standard du conteneur est coupée (`< /dev/null`). **Non confirmé** que cela règle le problème ; si la commande reste en attente,
  ouvre un second terminal et lance `docker ps` puis `docker top NOM_DU_CONTENEUR` pendant l'attente, et envoie-moi le résultat.

- Le choix du « plus gros modèle installé » se base sur la colonne SIZE d'`ollama list` ; testé avec une liste simulée seulement. Si tu as plusieurs gros modèles, donne le nom : `lab dev start NOM MODELE`. Le 2026-10-19, `lab dev start` avait pris `qwen2.5:1.5b` (le petit modèle de tâches) : défaut corrigé.
- Non confirmés à ce jour : `lab dev merge` (fusion réelle), `lab dev setup` (la commande `skills install official/software-development/subagent-driven-development`
  vient de la documentation de Hermes ; elle peut demander une confirmation) et `lab dev ctx64` (la variante doit apparaître avec `CONTEXT 65536` dans `ollama ps`).
- Hermes semble lire `AGENTS.md` (son compte rendu cite la règle sur la fusion et suit le déroulement), mais je n'ai pas vérifié le mécanisme ; le dossier de travail `-w` fonctionne.
- Le bac à sable n'a ni `node` ni `pytest` confirmés : seul Python 3.14 + `unittest` l'est. Un projet Node échouera au check s'il manque `node`/`npm`.
- Les clés exactes `delegation.max_iterations` / `max_concurrent_children` / `max_spawn_depth` viennent de la documentation de Hermes (version courante) ;
  la version de l'image `:stable` installée chez toi n'a pas été comparée.
- Qualité réelle du travail d'un modèle local sur des tâches de code : non mesurée. À évaluer sur 2 ou 3 vraies tâches avant de lui confier du sérieux.
- Hermes n'a jamais exécuté la boucle complète (plan → tests → relecture en deux passes) ici ; la durée d'une tâche n'est pas connue.
- `scripts/check` : testé ici pour Python (`unittest`), Node (`npm test`) et shell ; `pytest`, `ruff` et `shellcheck` ne l'ont pas été (absents de mon environnement).
