# Plan — Instance unique et récupération des Réglages

Plan ID: `arch-06ad3254a8a3-scope-caf01c9e2de7`

Date: 2026-08-12

Baseline: `06ad3254a8a3b1dcf3bc8b2e4fb7bee01f6c014a`

PR: [#273 — Draft](https://github.com/ggbond268/MacTools/pull/273)

Statut architecture: `ACTION_REQUIRED`

Revue architecture indépendante: `runtime_attestation=gpt-5.6-sol/high` ; paquet `settled`

## Résultat attendu

- Une seule instance fonctionnelle par bundle ID et session utilisateur.
- Relance Finder, Spotlight, Dock ou launcher : Réglages affichés par l'instance existante.
- Copie secondaire : commande `show-settings`, accusé de réception borné, puis arrêt.
- Aucun `PluginHost`, plugin, raccourci, event tap, status item ou updater dans la copie secondaire.
- Démarrage à froid et lancement à l'ouverture de session : silencieux.
- Même comportement en Debug et Release.
- PR conservée en Draft jusqu'à certification complète.

## Diagnostic confirmé

Le callback AppKit de réouverture est correct. Le fallback Debug ne l'est pas :

- polling de `NSWorkspace.runningApplications` chaque seconde ;
- détection symétrique : chaque processus voit l'autre ;
- ouverture possible des deux fenêtres Réglages ;
- deux runtimes complets restent actifs ;
- portée limitée au Debug ;
- mémorisation de PID non purgée ;
- tests limités à une politique bundle/PID, sans preuve multi-processus.

Risque principal : concurrence sur raccourcis globaux, observers, plugins matériels, préférences et répertoires partagés.

## Invariants

| ID | Invariant | Preuve attendue |
|---|---|---|
| I-001 | Au plus un runtime fonctionnel | Compteur d'initialisation = 1 sous lancements concurrents |
| I-002 | Toute copie secondaire transmet `show-settings` puis quitte | ACK reçu ; exit 0 ; aucun runtime secondaire |
| I-003 | Aucun polling permanent | Absence de `Timer` et de scan `runningApplications` |
| I-004 | Reopen AppKit et IPC utilisent la même présentation | Même handler central ; tests des deux entrées |
| I-005 | Une commande précoce n'est pas perdue | Réponse `not-ready`, retry borné, puis ACK après readiness |
| I-006 | Crash propriétaire récupérable | Le lancement suivant devient propriétaire |
| I-007 | Timeout borné et sûr | Pas de blocage ; pas de second runtime |
| I-008 | Debug et Release partagent le même code | Aucun `#if DEBUG` sur le comportement produit |

## Evidence ledger

| ID | Preuve | Conclusion |
|---|---|---|
| E-001 | Reproduction réelle du 2026-08-12 : deux PID `MacTools Dev` restent actifs | Le launcher peut démarrer une copie au lieu d'émettre un reopen |
| E-002 | `MacToolsAppDelegate` construit actuellement `PluginHost` et les stores en propriétés | L'arbitrage actuel arrive trop tard pour protéger les side effects |
| E-003 | Le polling est symétrique et basé uniquement sur bundle ID + PID | Il ne peut pas désigner l'instance propriétaire |
| E-004 | `AppWindowRouter.show` active, déminiaturise et met la fenêtre au premier plan | La présentation existante est réutilisable |
| E-005 | AppKit documente `applicationShouldHandleReopen` pour la réactivation d'une app déjà lancée | Conserver le callback et retourner `false` après traitement custom |
| E-006 | Core Foundation documente les ports nommés, les réponses et les timeouts | `CFMessagePort` fournit l'IPC local requis sans dépendance |
| E-007 | Revues Spec et standards indépendantes | Le polling ne doit pas être rendu mergeable |

## Classification des surfaces

| Surface | Classe | Décision |
|---|---|---|
| Callback `applicationShouldHandleReopen` | `NON_RISK` | Conserver ; déléguer au handler central |
| `AppWindowRouter.showSettings()` | `NON_RISK` | Conserver ; présentation déjà testée |
| Polling Debug et `AppDuplicateLaunchPolicy` | `ACTION_REQUIRED` | Supprimer entièrement |
| Initialisation en propriétés du delegate | `ACTION_REQUIRED` | Déplacer derrière l'élection propriétaire |
| Absence d'IPC/ACK | `ACTION_REQUIRED` | Ajouter un coordinateur d'instance |
| Cold launch silencieux | `PRESERVE` | Aucun affichage sans reopen ou commande IPC |
| URL routing et bootstrap plugins | `PRESERVE` | Exécuter uniquement dans le runtime propriétaire |

## Design retenu

### 1. Propriétaire atomique via `CFMessagePort`

Créer `AppInstanceCoordinator`, sans dépendance AppKit ni état persistant.

- Nom de port déterministe : `<bundle-id>.instance-coordination.v1`.
- Namespace natif de la session utilisateur.
- `CFMessagePortCreateLocal` tente l'enregistrement atomique.
- Port réellement créé : rôle `.primary`.
- Nom déjà enregistré : rôle `.secondary`.
- Callback attaché immédiatement à une queue série dédiée.
- Invalidation explicite à la terminaison.
- Crash : port Mach invalidé par le système ; prochaine copie éligible comme propriétaire.

Ne pas ajouter `LSMultipleInstancesProhibited` comme solution principale : il ne transporte pas la demande `show-settings` et peut produire une erreur LaunchServices au lieu du flux de récupération.

### 2. Protocole IPC minimal

Une seule commande versionnée : `show-settings`.

- Enveloppe : `{version: 1, command: "show-settings", requestID: <UUID>}`.
- Taille maximale : 1 KiB.
- Réponses fermées : `accepted`, `not-ready`, `unsupported`, `invalid`.
- Send timeout : 500 ms maximum par tentative.
- Receive timeout : 500 ms maximum par tentative.
- Budget global incluant retries : 2 secondes.
- Aucune URL, chemin, préférence ou donnée arbitraire transportée.
- Une copie secondaire ne peut pas initialiser le runtime, quel que soit le résultat.
- `requestID` rend une commande répétée idempotente.

Séquence secondaire :

1. Détecter le port existant.
2. Créer le port distant.
3. Envoyer `show-settings` et attendre l'ACK.
4. Si `accepted` : demander `NSApp.terminate(nil)`.
5. Si `not-ready` : réessayer dans le budget global de 2 secondes.
6. Si port invalide : retenter l'élection atomique.
7. Si la copie devient propriétaire après crash : démarrer normalement et demander les Réglages.
8. Si le propriétaire reste présent sans ACK : logger, quitter, ne jamais initialiser un second runtime.

### 3. Runtime créé seulement par le propriétaire

Introduire `MacToolsAppRuntime`, construit après élection positive.

Responsabilités regroupées :

- `PluginHost` ;
- updater et stores ;
- `AppWindowRouter` ;
- `MenuBarStatusItemController` ;
- bootstrap plugins ;
- routeur URL ;
- cleanup de terminaison.

Cycle de vie :

- `MacToolsAppDelegate` ne possède au départ que le coordinateur et un état de présentation léger.
- `applicationWillFinishLaunching` lance l'élection.
- `.secondary` transmet puis termine.
- `.primary` autorise `applicationDidFinishLaunching` à construire `MacToolsAppRuntime`.
- Tous les callbacks du delegate gardent un `guard` de rôle.

### 4. Handler de récupération unique

Remplacer `showSettingsForReopen` par `requestSettingsRecovery()`.

Entrées :

- callback AppKit de reopen ;
- commande IPC `show-settings`.

États :

- routeur disponible : dispatcher sur le `MainActor`, appeler `windowRouter.showSettings()`, puis ACK `accepted` ;
- routeur absent : répondre `not-ready`, sans perdre le port propriétaire ;
- copie secondaire : retry borné jusqu'à readiness ou expiration des 2 secondes.

Les requêtes successives après démarrage restent honorées. Un `requestID` déjà accepté ne présente pas une seconde fois la fenêtre.

### 5. Observabilité

Ajouter `AppLog.instanceCoordination`.

Événements structurés :

- rôle élu ;
- commande reçue ;
- commande acceptée/non prête/rejetée ;
- ACK ;
- retry après invalidation ;
- timeout ;
- arrêt secondaire ;
- invalidation à la terminaison.

Ne pas logger de payload, chemin personnel ou identifiant sensible.

## Matrice des pannes

| Cas | Comportement requis |
|---|---|
| Premier lancement | Propriétaire ; runtime unique ; aucune fenêtre forcée |
| Reopen AppKit | Propriétaire affiche/active Réglages |
| Seconde copie, propriétaire prêt | Commande + ACK ; Réglages ; secondaire quitte |
| Seconde copie pendant bootstrap | `not-ready` ; retry borné ; affichage dès que le routeur existe |
| Deux lancements exactement simultanés | Un seul port local ; un seul runtime |
| Propriétaire crash avant connexion | Retry ; secondaire devient propriétaire |
| Propriétaire vivant mais bloqué | Timeout ; secondaire quitte sans runtime |
| Message inconnu/version invalide | Rejet ; aucune présentation ; log warning |
| Debug et Release installés ensemble | Bundle IDs différents ; propriétaires indépendants |
| Deux copies du même bundle | Une seule propriétaire |

## Actions et DAG

```text
A-001 Coordinator + protocole IPC
  -> A-002 Gating du runtime + handler unique
      -> A-003 Tests multi-processus + QA réelle
          -> A-004 Revue finale + certification Draft
```

### A-001 — Coordinateur d'instance

But : fournir une élection atomique et une commande IPC bornée.

Fichiers prévus :

- `Sources/App/AppInstanceCoordinator.swift` — nouveau ; rôle, protocole, transport `CFMessagePort`, timeouts, invalidation.
- `Sources/Core/Diagnostics/AppLog.swift` — catégorie dédiée.
- `Tests/App/AppInstanceCoordinatorTests.swift` — protocole, rôle, ACK, retry, timeout, invalidation.

Contrat de sortie :

- API typée : `.primary` ou `.secondary(acknowledged: Bool)`.
- Aucun AppKit dans le cœur du coordinateur.
- Transport injectable pour tests déterministes.
- Aucun polling, PID cache ou fichier de lock.

### A-002 — Gating du runtime et récupération unique

But : empêcher tout side effect secondaire.

Fichiers prévus :

- `Sources/App/MacToolsApp.swift` — élection précoce, delegate minimal, suppression du polling.
- `Sources/App/MacToolsAppRuntime.swift` — nouveau ; composition du runtime propriétaire.
- `Tests/App/MacToolsAppDelegateTests.swift` — transitions primary/secondary, readiness/retry, reopen.

Contrat de sortie :

- `PluginHost` absent du delegate avant élection.
- Aucun appel de bootstrap, status item ou URL router côté secondaire.
- AppKit reopen et IPC convergent vers `requestSettingsRecovery()`.
- Cold launch inchangé.

### A-003 — Preuve multi-processus

But : tester les primitives réelles, pas uniquement des fakes.

Fichiers prévus :

- `Tests/App/AppInstanceCoordinatorProcessTests.swift` — orchestration de sous-processus.
- `Tests/Support/AppInstanceProbe/` — exécutable de test minimal, sans UI ni données utilisateur.
- `project.yml` et générateur de config test si nécessaires — cible helper Debug uniquement.
- `docs/features/app-reopen-recovery.md` — résultats et journal append-only.
- `README.md` — documenter la voie de récupération utilisateur.
- `changes/unreleased/app-reopen-recovery.md` — texte final centré utilisateur.

Scénarios automatiques :

- 2 puis 10 processus concurrents : exactement un propriétaire ;
- une commande par secondaire ; ACK et exit 0 ;
- commande reçue avant disponibilité du handler ;
- crash du propriétaire puis promotion ;
- propriétaire silencieux : timeout, aucun second runtime ;
- bundle IDs différents : indépendance ;
- message/version invalide : rejet.

Tous les artefacts utilisent un namespace temporaire de test. Aucun accès aux préférences ou répertoires réels.

### A-004 — Certification

But : décider si la PR peut quitter Draft. Ne pas la rendre Ready automatiquement.

Gates :

- tests ciblés coordinator, delegate et window router ;
- test multi-processus vert sans retry flaky ;
- suite `MacToolsTests` verte ;
- `make build` Debug ;
- build Release ;
- `git diff --check` ;
- review Spec séparée ;
- review standards séparée ;
- QA réelle Finder/Spotlight/Dock/launcher ;
- après stabilisation : un seul processus actif et Réglages au premier plan ;
- PR toujours Draft ; passage Ready seulement sur demande explicite.
- écrire `.Codex/rules/architecture-stability.md` seulement après tous les gates verts ; baseline = HEAD précédant le commit de certification.

## Tests d'acceptance

| ID | Given | When | Then |
|---|---|---|---|
| AT-001 | Aucun MacTools actif | L'app démarre | Un runtime ; aucune fenêtre forcée |
| AT-002 | MacTools actif, aucune fenêtre visible | Relance via launcher | Réglages visibles et actifs ; un seul runtime final |
| AT-003 | MacTools actif, Réglages miniaturisés | Relance | Même fenêtre déminiaturisée et au premier plan |
| AT-004 | MacTools actif, autre fenêtre visible | Reopen AppKit | Réglages affichés malgré `hasVisibleWindows = true` |
| AT-005 | Propriétaire en bootstrap | Une copie secondaire démarre | Demande non perdue ; affichage après readiness |
| AT-006 | 10 copies démarrent simultanément | Coordination | Un propriétaire ; neuf secondaires sans runtime |
| AT-007 | Propriétaire crash | Nouvelle copie démarre | Promotion ; démarrage normal |
| AT-008 | Propriétaire ne répond pas | Secondaire démarre | Arrêt borné ; aucun double runtime |
| AT-009 | MacTools Dev et MacTools Release | Les deux démarrent | Indépendance par bundle ID |

## Fitness functions

- Recherche statique : aucune référence à `duplicateLaunchPollTimer`, `handledDuplicateProcessIdentifiers`, `runningApplications` ou `AppDuplicateLaunchPolicy`.
- Construction : `PluginHost(` uniquement dans le runtime propriétaire/composition autorisée.
- Test concurrence : propriété `owners == 1` pour chaque groupe d'un même namespace.
- Test secondaire : propriété `runtimeInitializations == 0`.
- Test timeout : durée totale inférieure à 2 secondes.
- Test reopen : une seule invocation de présentation par événement.
- Aucun branchement produit `#if DEBUG` dans le coordinateur.

## Stability envelope

- Changements absorbés : plusieurs DerivedData, Finder/Spotlight, upgrade de bundle, crash primaire, future commande locale idempotente.
- Seuils : un runtime ; zéro bootstrap secondaire ; présentation en moins de 2 secondes ; zéro polling au repos.
- Contraintes : macOS 14+, Swift 6, Apple-native, UI `MainActor`, aucune dépendance.
- Invalidation du design : commande IPC non idempotente, sandbox bloquant `CFMessagePort`, besoin inter-session, timeout observé sur 100 relances QA.
- Compatibilité inter-version : arrêt/redémarrage requis si l'ancienne version ne publie aucun port ; coexistence non promise.

## Rollback

- Revert isolé de `AppInstanceCoordinator` et `MacToolsAppRuntime`.
- Restaurer uniquement le callback AppKit de reopen, sans réintroduire le polling.
- Aucun format de préférence ni donnée utilisateur à migrer.
- Aucun lock ou socket persistant à nettoyer.
- Garder la PR Draft si un gate échoue.

## Hors périmètre

- Modifier le comportement du plugin qui masque la barre de menus.
- Ajouter un raccourci global de secours.
- Changer Finder, Spotlight ou le launcher.
- Ajouter une restauration automatique de préférences.
- Ajouter une dépendance tierce ou un service XPC.
- Fusionner ou rendre la PR Ready.

## Décisions fermées

- IPC : `CFMessagePort`, pas polling ni notification sans ACK.
- Unicité : enregistrement atomique du port nommé, pas PID.
- Échec : fail closed ; jamais de second runtime.
- Présentation : handler central vers `AppWindowRouter.showSettings()`.
- Portée : même code Debug/Release, isolation par bundle ID.
- Livraison : PR Draft jusqu'à demande explicite et certification.
