# Feature — Récupération de l’application

Last verified: 2026-08-12

Status: planned — WIP unsafe, not mergeable
Source of truth: yes

## Résumé

- Le callback AppKit de réouverture affiche les Réglages.
- Le fallback Debug par polling est invalide : deux runtimes peuvent rester actifs.
- Cible : instance unique ; copie secondaire → commande `show-settings` → arrêt avant bootstrap.

## User flow

- MacTools est déjà lancé sans fenêtre visible, ou avec une fenêtre existante.
- L’utilisateur relance l’app depuis Finder, Spotlight ou le Dock.
- La fenêtre Réglages MacTools est affichée et activée.
- Si le launcher démarre une autre copie, elle transmet la demande puis quitte.
- Un seul runtime reste actif.

## Règles métier

| Règle | Markdown | Code centralisé | Consommation |
|---|---|---|---|
| Aucune règle métier durable | — | — | — |

## Décisions

| Date | Décision | Raison | Impact |
|---|---|---|---|
| 2026-08-12 | Réouverture → Réglages | Récupération indépendante de l'icône | Le callback AppKit reste conservé |
| 2026-08-12 | Instance unique + IPC avec ACK | Éviter deux runtimes concurrents | La copie secondaire transmet puis quitte avant le bootstrap |

## Plan

- [x] P001 — Formaliser le scénario de récupération.
- [x] P002 — Gérer la réouverture AppKit.
- [x] P003 — Ajouter le test, le changelog et la PR brouillon.
- [x] P004 — Reproduire le cas launcher avec deux processus.
- [x] P005 — Diagnostiquer le risque et rédiger le plan d'architecture.
- [ ] P006 — Remplacer le polling par l'instance unique et l'IPC.
- [ ] P007 — Certifier par tests multi-processus et QA réelle.

## TODO

- [x] F001 — Définir la surface de récupération — files: `docs/features/app-reopen-recovery.md` — status: done
- [x] F002 — Afficher les Réglages lors de la réouverture — files: `Sources/App/MacToolsApp.swift` — status: done
- [x] F003 — Couvrir le callback AppKit — files: `Tests/App/MacToolsAppDelegateTests.swift` — status: done
- [ ] F004 — Garantir un seul runtime — files: `Sources/App/AppInstanceCoordinator.swift`, `Sources/App/MacToolsAppRuntime.swift` — status: planned
- [ ] F005 — Couvrir les courses, crashs, ACK et timeouts — files: `Tests/App/AppInstanceCoordinatorTests.swift`, `Tests/App/AppInstanceCoordinatorProcessTests.swift` — status: planned

## Journal impl Codex

- 2026-08-12 — `MacToolsAppDelegate.applicationShouldHandleReopen` délègue à `AppWindowRouter.showSettings()` dans les deux états de visibilité, puis retourne `false` car l’app gère elle-même l’événement AppKit. `MacToolsAppDelegateTests` couvre ce câblage ; `AppWindowRouterTests` couvre activation, déminiaturisation et mise au premier plan.
- 2026-08-12 — En Debug, l’instance inspecte les applications en cours une fois par seconde ; le lancement d’une autre copie avec le même bundle ID ouvre les Réglages de l’instance existante, une seule fois par PID. Tests de filtrage par bundle ID et PID ajoutés.
- 2026-08-12 — Validation réelle : `make run` lance le bundle du dépôt, puis l'ouverture d'une copie Xcode concurrente affiche les Réglages de l'instance existante. Capture vérifiée visuellement.
- 2026-08-12 — Correction du diagnostic : la QA montre deux processus encore actifs. Le polling est symétrique ; il ne garantit ni l'identité de l'instance qui présente les Réglages ni l'unicité du runtime.
- 2026-08-12 — Plan de remplacement : `docs/superpowers/plans/2026-08-12-single-instance-reopen-recovery.md`. PR maintenue Draft ; aucun passage Ready avant preuve multi-processus.

## Files actuels

| Zone | Files |
|---|---|
| Cycle de vie app | `Sources/App/MacToolsApp.swift` |
| Plan d'architecture | `docs/superpowers/plans/2026-08-12-single-instance-reopen-recovery.md` |
| Présentation Réglages | `Sources/App/AppWindowRouter.swift` |
| Tests | `Tests/App/MacToolsAppDelegateTests.swift`, `Tests/App/AppWindowRouterTests.swift` |

## Tests / QA

- [x] Le callback AppKit appelle les Réglages ; le routeur active, déminiaturise et met la fenêtre au premier plan.
- [x] Exécuter `MacToolsAppDelegateTests` et `AppWindowRouterTests` après implémentation.
- [x] Reproduire le lancement de deux bundles Debug concurrents : Réglages affichés, mais deux processus encore actifs.
- [ ] Vérifier qu'une copie secondaire quitte sans initialiser le runtime.
- [ ] Vérifier 10 lancements concurrents, crash propriétaire et timeout.
- [ ] Refaire la QA Finder, Spotlight, Dock et launcher avec un seul processus final.

## Historique

<!-- Ne lire que pour bug, régression, audit, ou demande explicite. -->

| Date | Commit | Type | Notes |
|---|---|---|---|
| 2026-08-12 | `vwt` | Feature | Réouverture de MacTools comme voie de récupération |
