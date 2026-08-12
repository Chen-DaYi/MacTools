# Feature — Récupération de l’application

Last verified: 2026-08-12

Status: implemented
Source of truth: yes

## Résumé

- Une nouvelle demande d’ouverture de MacTools affiche les Réglages.
- Filet de récupération si l’icône de barre des menus est inaccessible.
- En Debug, une autre copie du même bundle déclenche aussi les Réglages de l’instance existante.

## User flow

- MacTools est déjà lancé sans fenêtre visible, ou avec une fenêtre existante.
- L’utilisateur relance l’app depuis Finder, Spotlight ou le Dock.
- La fenêtre Réglages MacTools est affichée et activée.
- En Debug, si le launcher démarre une autre copie, l’instance déjà lancée affiche les Réglages.

## Règles métier

| Règle | Markdown | Code centralisé | Consommation |
|---|---|---|---|
| Aucune règle métier durable | — | — | — |

## Décisions

| Date | Décision | Raison | Impact |
|---|---|---|---|
| 2026-08-12 | Réouverture → Réglages ; en Debug, autre copie → Réglages | Récupération indépendante de l’icône et des copies locales concurrentes | Finder, Spotlight et Dock ouvrent la configuration sans comportement par défaut supplémentaire |

## Plan

- [x] P001 — Formaliser le scénario de récupération.
- [x] P002 — Gérer la réouverture AppKit.
- [x] P003 — Ajouter le test, le changelog et la PR brouillon.

## TODO

- [x] F001 — Définir la surface de récupération — files: `docs/features/app-reopen-recovery.md` — status: done
- [x] F002 — Afficher les Réglages lors de la réouverture — files: `Sources/App/MacToolsApp.swift` — status: done
- [x] F003 — Couvrir les fenêtres visibles, absentes et les copies locales concurrentes — files: `Tests/App/MacToolsAppDelegateTests.swift` — status: done

## Journal impl Codex

- 2026-08-12 — `MacToolsAppDelegate.applicationShouldHandleReopen` délègue à `AppWindowRouter.showSettings()` dans les deux états de visibilité, puis retourne `false` car l’app gère elle-même l’événement AppKit. `MacToolsAppDelegateTests` couvre ce câblage ; `AppWindowRouterTests` couvre activation, déminiaturisation et mise au premier plan.
- 2026-08-12 — En Debug, l’instance inspecte les applications en cours une fois par seconde ; le lancement d’une autre copie avec le même bundle ID ouvre les Réglages de l’instance existante, une seule fois par PID. Tests de filtrage par bundle ID et PID ajoutés.
- 2026-08-12 — Validation réelle : `make run` lance le bundle du dépôt, puis l’ouverture d’une copie Xcode concurrente affiche les Réglages de l’instance existante. Capture vérifiée visuellement.

## Files actuels

| Zone | Files |
|---|---|
| Cycle de vie app | `Sources/App/MacToolsApp.swift` |
| Présentation Réglages | `Sources/App/AppWindowRouter.swift` |
| Tests | `Tests/App/MacToolsAppDelegateTests.swift`, `Tests/App/AppWindowRouterTests.swift` |

## Tests / QA

- [x] Le callback AppKit, ou en Debug le lancement d’une autre copie, appelle les Réglages ; le routeur active, déminiaturise et met la fenêtre au premier plan.
- [x] Exécuter `MacToolsAppDelegateTests` et `AppWindowRouterTests` après implémentation.
- [x] Reproduire le lancement de deux bundles Debug concurrents et vérifier l’affichage des Réglages.

## Historique

<!-- Ne lire que pour bug, régression, audit, ou demande explicite. -->

| Date | Commit | Type | Notes |
|---|---|---|---|
| 2026-08-12 | `vwt` | Feature | Réouverture de MacTools comme voie de récupération |
