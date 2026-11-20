# APAESENCA

Inscriptions des bénéficiaires aux **journées APA**. La page d'accueil affiche un menu
avec toutes les journées. Chaque journée a ses activités, ses horaires, ses institutions
et **son propre code d'accès**.

| Journée | Date | Adresse directe | Accès |
|---|---|---|---|
| Journée APA de Marcinelle | mardi 30 mars 2027 | `…/APAESENCA/#marcinelle-2027` | code de la journée |
| Journée APA de Philippeville | jeudi 22 avril 2027 | `…/APAESENCA/#philippeville-2027` | code de la journée |
| Poire qui Roule (PQR) | jeudi 27 mai 2027 | `…/APAESENCA/#pqr-2027` | **code réservé aux institutions de la région de Chimay** |

Adresse de la page : `https://romaincapp.github.io/APAESENCA/`. Tu peux envoyer aux
éducateurs l'adresse directe de leur journée (ex. `https://romaincapp.github.io/APAESENCA/#marcinelle-2027`).

> ⚠ Les activités et horaires des trois journées sont **provisoires** : ce sont ceux de la
> journée du 17 novembre, recopiés en attendant les vraies listes.

- `site/index.html` : la page (menu des journées, inscriptions, espace organisateur ; un seul fichier).
- `supabase/schema.sql` : la base de données (journées, tables, sécurité, contrôle des places).
- `tests/` : les tests automatiques (voir « Tests »).
- `.github/workflows/deploy.yml` : publication automatique sur GitHub Pages.
- `.github/workflows/tests.yml` : lance les tests à chaque pull request.

## Mise en place (une seule fois)

### 1. Base de données Supabase

Le projet Supabase de la journée du 17 novembre est réutilisé.

1. Dans Supabase : **SQL Editor** → **New query** → colle `supabase/schema.sql` → **Run**.
   Au premier lancement, les anciennes tables du 17 novembre sont déplacées dans le schéma
   `archive_17_novembre` (rien n'est effacé, mais elles ne sont plus visibles depuis la page).
   Pour supprimer définitivement ces noms : `drop schema archive_17_novembre cascade;`
2. **Le reste se fait dans l'espace organisateur** de la page (`…/APAESENCA/#organisateur`,
   lien « Espace organisateur » en bas du menu), avec le code organisateur : journées,
   codes d'accès, places maximum, ateliers, horaires, institutions. Plus besoin de SQL.
   Le code organisateur du 17 novembre est conservé ; il se change depuis cet espace.
   (Si tu n'as jamais défini de code organisateur : `select public.apa_definir_code_admin('…');`
   une seule fois dans le SQL Editor.)
3. Les **institutions s'inscrivent elles-mêmes** dans la page (plus besoin de Google Form
   ni de fichier SQL). Envoie-leur simplement l'adresse de la journée et son code.

### 2. Configuration GitHub

1. Dans le dépôt : **Settings → Pages → Build and deployment → Source : GitHub Actions**.
2. **Settings → Secrets and variables → Actions → onglet Variables → New repository variable** :
   - `SUPABASE_URL` : le *Project URL* (Supabase → Project Settings → API)
   - `SUPABASE_KEY` : la clé **anon** / **publishable** (jamais `service_role` / `secret`)
3. **Actions → Déployer la page d'inscription → Run workflow**.
   L'adresse de la page s'affiche à la fin : `https://romaincapp.github.io/APAESENCA/`.

Chaque modification de `site/` poussée sur `main` redéploie la page automatiquement.

La clé publique sera visible dans la page, c'est normal : sans le code d'une journée, elle
permet seulement de lire le menu (nom, date, lieu des journées), ni les noms ni les codes.

## Espace organisateur (`…/#organisateur`)

À gauche, la liste des journées (cachées comprises) ; à droite, la journée choisie :

- **Nouvelle journée** : nom, date, lieu, identifiant dans l'adresse (proposé
  automatiquement, ex. `couvin-2027`, ne change plus ensuite). On peut partir d'une journée
  vide ou copier les ateliers et horaires d'une autre.
- **Informations** : nom, date, lieu, places maximum (vide = pas de limite), pause de midi,
  mention d'accès (ex. « Réservé aux institutions de la région de Chimay »), texte d'accueil,
  afficher ou cacher la journée dans le menu.
- **Code d'accès** : ouvrir les inscriptions avec un code (6 caractères minimum ; un code
  qui contient le nom ou le lieu de la journée est refusé, car ils sont visibles par tous),
  le remplacer, ou fermer les inscriptions. « Proposer un code » en invente un. Le code ne
  peut plus être relu ensuite : note-le au moment de l'enregistrer.
- **Ateliers** : ajouter, renommer, changer de lieu (plateau), de places ou d'ordre,
  supprimer. Garde-fous :
  - les places ne peuvent pas descendre sous le nombre d'inscrits d'une tournante ;
  - supprimer un atelier qui a des inscrits affiche d'abord les institutions touchées
    (en signalant celles qui ont déjà téléchargé leur PDF) et demande de confirmer ;
    leurs cases redeviennent « à choisir ».
- **Horaires** : un générateur (début, durée d'un atelier, changement, nombre de
  tournantes le matin et l'après-midi, reprise) prépare un aperçu modifiable à la main,
  enregistré seulement au clic. Les inscriptions restent attachées au numéro de tournante ;
  retirer des tournantes qui ont des inscrits demande de confirmer.
- **Institutions** : modifier les coordonnées et la réservation (même si le planning est
  verrouillé), déverrouiller un planning, supprimer une institution avec ses participants.
- **Dupliquer** la journée (infos, ateliers, horaires ; sans institutions ni code).
- **Supprimer** la journée : seulement si elle n'a plus d'institution ni de participant.
  Sinon, la cacher du menu.
- **Changer le code organisateur** (8 caractères minimum, l'ancien est demandé).

Si un éducateur a la page ouverte pendant une modification, sa page se met à jour toute
seule ; s'il avait des changements non enregistrés sur une fiche touchée, l'enregistrement
est refusé avec un message clair, sans rien écraser.

## Utilisation par les éducateurs

L'éducateur choisit sa journée dans le menu (ou ouvre directement son lien), puis entre le
code d'accès de cette journée. La page s'en souvient sur cet appareil.

**Inscrire son institution** (remplace le Google Form) : bouton **+ Inscrire mon
institution**, avec les mêmes questions que le formulaire : nom de l'institution, personne
responsable, téléphone, e-mail, nombre de participants, nombre d'éducateurs · éducatrices,
nombre de PMR.
- Les places restantes s'affichent partout (menu, onglet, formulaire). Quand la journée est
  complète, l'inscription se ferme d'elle-même. C'est vérifié par la base : deux
  institutions qui s'inscrivent en même temps ne peuvent pas dépasser le maximum.
- Une institution ne peut s'inscrire qu'une fois par journée (même nom, peu importe les
  majuscules).
- Les lignes « Participant 1, 2… » sont créées tout de suite, prêtes à être renommées et
  planifiées.
- **Modifier la réservation** permet ensuite de changer le nombre de places, d'éducateurs
  ou de PMR (dans la limite des places restantes). On ne peut pas avoir plus de participants
  que de places réservées.

Onglet **Par institution** : l'éducateur choisit son institution, et ses participants
s'affichent en tableau (une ligne par participant, une colonne par tournante).

- Il choisit une activité ou **Pause / repos** dans chaque case. Les places restantes
  s'affichent dans chaque menu, et une activité complète ne peut pas être choisie.
- **Remplir automatiquement les cases vides** propose un planning complet qui respecte
  les places et évite de refaire la même activité. Chaque nouveau clic (**Proposer une
  autre variante**) tire une autre répartition. Les cases proposées ont une bordure bleue,
  et les cases choisies à la main ne bougent pas. **Tout vider** repart de zéro (rien n'est
  effacé tant qu'on n'a pas enregistré).
- **Contrôles anti-oubli** : les cases vides sont en rouge, les activités faites deux fois
  sont en orange, et le nombre de participants est comparé au nombre annoncé.
- Les noms sont modifiables (ex. remplacer « Participant 3 » par le vrai nom), et on
  peut ajouter ou retirer un participant.
- **Enregistrer** envoie toute l'institution d'un coup. Si une place a été prise
  entre-temps, ou si un collègue a modifié la même fiche, rien n'est enregistré et la page
  explique quoi corriger.

**Vue par groupe** (affichage par défaut ; « Tableau détaillé » garde l'ancien tableau avec
un menu par case) :
- Une ligne par groupe, des cases en couleur selon le lieu. Un clic sur une case ouvre la
  **palette d'ateliers** : rangés par lieu, avec les places libres, ceux déjà faits signalés,
  les complets barrés. Taper deux lettres filtre (« zu » → Zumba), Entrée choisit.
- **Atelier trop petit pour le groupe** (ex. 8 résidents pour 4 places, ou plus assez de
  places) : on choisit dans une liste qui y va (ceux qui ne l'ont pas encore fait sont
  présélectionnés), puis un 2e atelier est proposé pour les autres, **d'abord sur le même
  lieu**. Un groupe divisé montre ses deux ateliers côte à côte dans la case.
- **▸** déplie un groupe pour changer l'atelier d'un seul résident ou son nom.
- **↶ Annuler** (ou Ctrl+Z) revient en arrière d'une action à la fois, y compris après
  « Remplir automatiquement », « Tout vider » ou « Former des groupes ». ✕ ou Échap ferme la
  palette sans rien changer.
- Rien n'est enregistré tant qu'on n'a pas cliqué « Enregistrer ».

**Groupes (≈ 8 résidents par éducateur)** :
- **Former des groupes de 8** répartit les participants sans groupe en groupes équilibrés
  d'au plus 8 (ex. 20 → 7 + 7 + 6). Clique sur le nom d'un groupe pour le renommer (ex.
  « Groupe de Marie »). Le petit menu sous chaque nom change quelqu'un de groupe.
- Chaque groupe a sa propre ligne dans le tableau : choisir une activité dans cette ligne
  **inscrit tout le groupe d'un coup** à cette tournante. Seules les activités avec assez de
  places pour tout le groupe peuvent être choisies. « · mixte · » signifie que les résidents
  du groupe n'ont pas tous la même activité.
- **Remplir automatiquement** garde les groupes ensemble quand une activité a assez de
  places, et ne les sépare que sinon (le message dit combien de fois).
- Le PDF contient une page **Planning par groupe** pour les éducateurs, et le groupe figure
  sur chaque fiche et dans l'export CSV.

**Téléchargement et verrouillage** : **Télécharger et verrouiller (PDF)** demande une
confirmation, puis verrouille le planning de l'institution et télécharge le PDF (vue
d'ensemble, « où sont les participants », une fiche par participant). Une fois verrouillé,
plus personne ne peut modifier, ajouter ou supprimer un participant de cette institution :
c'est contrôlé par la base, pas seulement par la page. Le PDF reste téléchargeable.
Seul l'organisateur peut déverrouiller : bouton **Déverrouiller (organisateur)** et code
organisateur.

Onglet **Organisateur** (code organisateur) : la liste des institutions inscrites avec
leurs coordonnées (responsable, e-mail, téléphone), places, éducateurs, PMR et date
d'inscription, avec les totaux. Boutons **Exporter (CSV)**, **Copier toutes les adresses
e-mail** (à coller en Cci) et **Supprimer** une institution avec ses participants. Les
coordonnées ne sont lisibles qu'avec le code organisateur, jamais avec le code de la journée.

**📅 Ajouter à l'agenda** : télécharge un fichier agenda (`.ics`) à ouvrir avec Outlook,
Google Agenda, l'agenda Apple ou celui du téléphone. Il contient la journée (de la première à
la dernière tournante, heure de Bruxelles), le lieu, le **récapitulatif des inscriptions**
par groupe dans la description, le **planning PDF en pièce jointe** (gardée par Outlook et
l'agenda Apple ; Google Agenda l'ignore) et un rappel la veille. Il reprend le planning
enregistré.

Onglet **Inscription individuelle** : pour une personne seule ou un ajout de dernière
minute.

## Horaires

Les trois journées de départ ont des horaires **provisoires** (ceux du 17 novembre :
15 tournantes de 15 minutes de 9h45 à 15h25, dîner à 12h05). Ils se changent dans l'espace
organisateur, section « Horaires ».

Relancer `schema.sql` ne touche plus aux journées, ateliers ni horaires : il ne les crée
que sur une base vide. Tout ce que tu modifies dans l'espace organisateur est conservé.

## Comment ça marche

- La page n'accède jamais directement aux tables. Elle passe par des fonctions SQL
  (`apa_journees` pour le menu, puis `apa_connexion`, `apa_etat`, `apa_enregistrer`,
  `apa_enregistrer_lot`, `apa_supprimer`, `apa_verrouiller`) qui vérifient toutes le code de
  la journée demandée. Un code ne donne jamais accès à une autre journée.
- Les places sont comptées séparément pour chaque journée.
- Places de la journée = places réservées par chaque institution (ou son nombre réel de
  participants s'il est plus grand) + inscriptions individuelles sans institution.
- **Places garanties** : les fonctions d'enregistrement verrouillent les activités,
  enregistrent, puis recomptent. Si une place manque, tout est annulé et la page affiche
  « Plus de place pour : … ». Tests effectués : 10 inscriptions simultanées sur la
  dernière place donnent 1 acceptée et 9 refusées ; 4 institutions qui enregistrent en
  même temps sur la dernière place donnent 1 acceptée et 3 refusées.
- Si deux personnes modifient la même fiche, la deuxième est prévenue au lieu d'écraser
  le travail de la première.
- Une seule activité par tournante et par bénéficiaire (garanti par la base).
- La page se met à jour toutes les 5 secondes.
- Export CSV (ouvrable dans Excel) par bénéficiaire ou par activité.

## Tests

Deux séries de tests vérifient l'application à chaque pull request (onglet **Actions** de
GitHub, coche verte ou croix rouge sur la pull request) :

- **`tests/test_*.py` : la base de données** (179 tests). Chaque test part d'une base vide,
  installe le vrai `schema.sql` et appelle les fonctions exactement comme la page, avec la
  clé publique. Ils couvrent : installation, relance du script et migration depuis le
  17 novembre ; création, modification, ouverture, fermeture, duplication, masquage et
  suppression des journées ; ateliers et horaires, y compris après des inscriptions ;
  inscriptions des institutions, places, groupes, conflits entre deux personnes,
  verrouillage ; sécurité (chaque fonction de l'organisateur refusée sans le bon code,
  fonctions internes et tables inaccessibles, cloisonnement entre journées).
- **`tests/e2e/parcours.cjs` : le parcours complet dans un vrai navigateur**, à deux en
  même temps (organisatrice et éducatrice) : créer une journée, ses ateliers, ses horaires
  et son code ; inscrire une institution ; envoyer un groupe de 8 dans un atelier de 4 ;
  enregistrer ; fichier agenda ; puis l'organisatrice modifie et supprime après les
  inscriptions, et l'éducatrice voit les changements ; verrouillage PDF ; dupliquer,
  supprimer, cacher ; changer le code organisateur ; contraste des écrans en clair et en
  sombre, et affichage sur téléphone.

Pour les lancer sur un ordinateur (PostgreSQL, Python et Node.js installés) :
```bash
pip install "psycopg[binary]" pytest
APA_TEST_DSN=postgresql://postgres:motdepasse@localhost:5432/postgres python -m pytest tests -q
npm install --no-save playwright && npx playwright install chromium
APA_TEST_DSN=postgresql://postgres:motdepasse@localhost:5432/postgres python tests/e2e/lancer.py
```
Les tests créent puis suppriment leur propre base temporaire : ils ne touchent jamais la
base Supabase.

## À savoir

- **Projet gratuit mis en pause** : Supabase met en pause un projet gratuit après 7 jours
  sans activité. Il suffit de cliquer sur « Restore » dans le tableau de bord. Vérifie-le
  la veille.
- Toute personne qui a le code d'une journée peut modifier ou supprimer n'importe quelle
  fiche de cette journée. Change le code après la journée.
- Les noms des bénéficiaires sont des données personnelles : supprime-les après chaque
  journée (`delete from public.beneficiaires where journee = 'marcinelle-2027';`).
