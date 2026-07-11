#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "changelog.py"
SPEC = importlib.util.spec_from_file_location("mactools_changelog", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
changelog = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = changelog
SPEC.loader.exec_module(changelog)


class ComposeSparkleNotesTests(unittest.TestCase):
    def test_includes_plugin_releases_since_previous_app_release(self) -> None:
        content = """# Changelog

## [v1.2.0] - 2026-07-11

### Added

- Added the app feature.

## [plugins-1.4.0] - 2026-07-10

### Added

- Added the first plugin feature.

### Fixed

- Fixed a shared plugin issue.

## [plugins-1.3.0] - 2026-07-09

### Changed

- Improved another plugin.

### Fixed

- Fixed a shared plugin issue.

## [v1.1.0] - 2026-07-08

### Fixed

- Fixed the previous app.

## [plugins-1.2.0] - 2026-07-07

### Added

- This plugin update is too old.
"""

        notes = changelog.compose_sparkle_notes(content, "v1.2.0", "### Added\n\n- Added the app feature.\n")

        self.assertIn("## App Updates", notes)
        self.assertIn("## Plugin Updates", notes)
        self.assertIn("- Added the first plugin feature.", notes)
        self.assertIn("- Improved another plugin.", notes)
        self.assertEqual(notes.count("- Fixed a shared plugin issue."), 1)
        self.assertNotIn("This plugin update is too old", notes)

    def test_omits_plugin_heading_when_no_plugin_release_intervened(self) -> None:
        content = """# Changelog

## [v1.2.0] - 2026-07-11

### Fixed

- Fixed the app.

## [v1.1.0] - 2026-07-08

### Fixed

- Fixed the previous app.
"""

        notes = changelog.compose_sparkle_notes(content, "v1.2.0", "Release highlight.\n")

        self.assertEqual(notes, "## App Updates\n\nRelease highlight.\n")

    def test_rejects_plugin_tag_as_sparkle_app_release(self) -> None:
        with self.assertRaisesRegex(changelog.ChangelogError, "require an app tag"):
            changelog.compose_sparkle_notes("", "plugins-1.2.0", "Plugin notes.")


if __name__ == "__main__":
    unittest.main()
