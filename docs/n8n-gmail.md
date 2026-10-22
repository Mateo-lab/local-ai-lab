# n8n : tri des mails Gmail par le modèle local

Inspiré du modèle « Gmail AI Email Manager » (n8n.io, workflow 4722), adapté à AiBeast : le mail est classé par **Ollama en local** (rien ne part chez un fournisseur d'IA). Les workflows posent des **libellés** ; la seule action destructrice, la corbeille, est séparée, manuelle et réversible.

## Les quatre workflows (dossier `n8n/`)

| Fichier | Rôle | Se lance |
|---|---|---|
| `gmail-creer-libelles.json` | Crée les 9 libellés dans Gmail | une fois, à la main |
| `gmail-tri-ia.json` | Classe les **nouveaux** mails | automatique, toutes les 5 min |
| `gmail-tri-anciens.json` | Classe les **anciens** mails, 200 par passage | automatique à 1 h, ou à la main |
| `gmail-corbeille-validee.json` | Met à la corbeille les mails que **tu** as validés | à la main |

## Les libellés

| Catégorie | Libellé Gmail |
|---|---|
| À répondre | `IA/À répondre` |
| Info | `IA/Info` |
| Notification | `IA/Notification` |
| Marketing | `IA/Marketing` |
| Réunion | `IA/Réunion` |
| Commentaire | `IA/Commentaire` |
| Voyage | `IA/Voyage` |
| (marqueur) mail déjà traité | `IA/Fait` |
| (proposition) à relire avant corbeille | `IA/Supprimer` |

Les noms `IA/Fait` et `IA/Supprimer` sont volontairement sans accent : les recherches Gmail les utilisent.

## Mise en place

1. Dans n8n : *Workflows → ⋯ → Import from file*, pour chacun des 4 fichiers. Sur chaque node Gmail, choisis ton identifiant Gmail.
2. Lance **« créer les libellés »** une fois (*Execute workflow*).
3. Dans les nodes **« Préparer le mail »** (workflows de tri), vérifie la ligne `MODELE` : le nom donné par `lab main-model`.
4. Teste « tri des nouveaux mails » avec *Execute workflow*, puis active-le.
5. Active « tri des anciens mails » (ou lance-le à la main) : il traite 200 mails par passage et s'arrête tout seul quand tout est marqué `IA/Fait`.

## Supprimer les inutiles : le circuit

1. Le tri pose `IA/Supprimer` sur les mails qui paraissent sans valeur. **Rien n'est supprimé à ce stade.**
2. Tu ouvres le libellé `IA/Supprimer` dans Gmail, tu retires le libellé de ceux que tu veux garder.
3. Tu lances « corbeille des mails validés » : les mails restants vont à la **Corbeille** de Gmail, **récupérable 30 jours** (Gmail la vide ensuite). Ce n'est pas une suppression définitive.

Qui peut recevoir `IA/Supprimer` : seulement les catégories **Marketing** et **Notification**, jamais un mail étoilé, important ou de plus de 300 Ko, et seulement si le modèle répond `supprimable: true`. Ces garde-fous sont dans le code, le modèle ne peut pas les contourner. Le workflow de corbeille refuse un lot de plus de 1000 mails et ignore les mails étoilés.

## Bon à savoir

- **Durée :** Ollama traite un mail à la fois. Compte quelques secondes par mail avec le modèle principal : 200 mails prennent de l'ordre d'une demi-heure, une grosse boîte plusieurs nuits. Dès que le premier lot a tourné, ouvre l'exécution dans n8n et regarde la durée réelle.
- **VRAM :** le modèle principal est chargé pendant le tri. Désactive les workflows pendant les séances d'images (mode images) ou d'agents Hermes.
- **Contenu non fiable :** le texte du mail est une donnée, avec la consigne de ne suivre aucune instruction. La sortie est limitée par un schéma (7 catégories, un booléen, une raison) : au pire, un mauvais libellé.
- **Sauvegarde :** workflows et identifiants sont dans la base n8n, couverte par `lab backup`.
- **Premier passage sur les anciens mails :** relis un échantillon de `IA/Supprimer` avant la première corbeille, par exemple 30 mails pris au hasard. C'est ton seul contrôle de la qualité du modèle sur ta boîte.

## Ce qui n'est pas vérifié

- Les fichiers JSON n'ont **jamais été importés dans n8n** : je n'ai pas accès à ton instance. La logique des nodes Code est testée hors n8n (21 contrôles) ; les paramètres des nodes Gmail et HTTP suivent le format n8n que je connais, et un champ peut demander un ajustement selon ta version (2.43.8).
- **À surveiller en premier :** que le node Gmail accepte `TRASH` comme libellé (corbeille), que « Chercher les anciens mails » renvoie bien le corps du texte (`simple: false`), et que le trigger expose `labelIds` et `internalDate`. Sans `sizeEstimate`, la protection « gros mail » ne joue pas.
- L'appel Ollama (`format` en schéma JSON, `think: false`) n'a pas été essayé sur ton modèle.
- La qualité du classement et du champ `supprimable` sur ta vraie boîte n'est pas mesurée.
