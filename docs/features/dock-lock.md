# Feature — Dock Lock

Last verified: 2026-08-10

Status: implemented
Source of truth: yes

## Résumé

- Bloque le déplacement accidentel du Dock entre écrans.
- Uniquement lorsque le Dock est en bas.
- Le curseur reste utilisable horizontalement au bord inférieur.

## User flow

- L’utilisateur active « Dock Lock » dans le panneau principal.
- MacTools demande l’autorisation Accessibilité si elle manque.
- Le curseur est retenu quelques points avant le bord inférieur de chaque écran.
- L’utilisateur désactive le commutateur pour restaurer le comportement macOS.

## Règles métier

| Règle | Markdown | Code centralisé | Consommation |
|---|---|---|---|
| Aucune règle métier durable | — | — | — |

## Décisions

| Date | Décision | Raison | Impact |
|---|---|---|---|
| 2026-08-10 | Portée minimale, sans sélection d’écran, raccourci ni démarrage automatique | Reproduire le comportement de verrouillage demandé sans extension produit | Tous les écrans sont protégés au bord inférieur après activation explicite |
| 2026-08-10 | Nom « Dock Lock » | Évite de reprendre la marque et l’identité visuelle de DockLock | Plugin `dock-lock` |

## Plan

- [x] P001 — Formaliser le contrat et la portée.
- [x] P002 — Implémenter le plugin et sa session CGEvent tap.
- [x] P003 — Ajouter les tests ciblés et la documentation ; vérifier les contrôles disponibles.
- [x] P004 — Créer la PR.

## TODO

- [x] F001 — Définir le comportement du curseur — files: `docs/features/dock-lock.md` — status: done
- [x] F002 — Créer le plugin — files: `Plugins/DockLock/` — status: done
- [x] F003 — Ajouter la documentation utilisateur et le fragment de changelog — files: `README.md`, `changes/unreleased/` — status: done

## Journal impl Codex

- 2026-08-10 — Contrat établi. La référence observée bloque le pointeur près du bord inférieur avec une autorisation Accessibilité. Aucun code ou actif de cette référence n’est repris.
- 2026-08-10 — Plugin créé. `Plugins/DockLock/Sources/DockLockPlugin.swift` installe un CGEvent tap et réactive le tap après désactivation système ; les tests couvrent le calcul de bord, l’activation, la désactivation et l’absence d’autorisation.
- 2026-08-10 — Revue spec : premier lancement désactivé ; la session vérifie périodiquement que le Dock reste en bas avant tout blocage. Ajout des tests correspondants.
- 2026-08-10 — Revue standards : la désactivation arrête désormais le CGEvent tap, y compris pendant une mise à jour ; test de cycle ajouté.
- 2026-08-10 — Revue sécurité : une orientation Dock inconnue ne bloque jamais le pointeur ; tests `nil` et valeur invalide ajoutés.
- 2026-08-10 — Checks : `git diff --check`, validation JSON, génération de configuration plugin et `swiftc -parse` réussis. Compilation XCTest bloquée : Xcode et xcodegen ne sont pas installés dans l’environnement.
- 2026-08-10 — PR créée : `ggbond268/MacTools#263`.
- 2026-08-10 — XCTest local : le cas d’autorisation manquante était initialisé désactivé, donc ne pouvait pas produire l’erreur attendue. Le test initialise désormais le plugin activé ; la vérification couvre bien le refus d’autorisation. Le mock de test conserve l’isolation MainActor du scénario.
- 2026-08-11 — Compatibilité Swift 6 : le polling du Dock utilise un `Timer` cible/sélecteur sur la boucle principale, sans closure `@Sendable` capturant le moniteur.

## Files actuels

| Zone | Files |
|---|---|
| Plugin similaire | `Plugins/MouseEnhancer/`, `Plugins/AutoHideDock/` |
| Documentation | `docs/plugins/local-native-plugins.md` |

## Files à créer/modifier

- `Plugins/DockLock/`
- `README.md`, `README.zh-CN.md`
- `changes/unreleased/dock-lock.md`
- `CONTRIBUTING.md`, `docs/plugins/local-native-plugins.md`

## Tests / QA

- [x] Couvrir le calcul de retenue du curseur, l’activation, la désactivation, la perte d’autorisation et les orientations non prises en charge.
- [x] Vérifier le manifeste et la génération de configuration plugin.
- [x] Compiler et exécuter les XCTest ciblés — Xcode 26.6 ; exécution locale sans signature.

## Historique

<!-- Ne lire que pour bug, régression, audit, ou demande explicite. -->

| Date | Commit | Type | Notes |
|---|---|---|---|
| 2026-08-10 | `mus` | Feature | Dock Lock implémenté et PR #263 créée |
