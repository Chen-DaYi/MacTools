import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
COVERAGE_DOCUMENT = REPO_ROOT / "docs" / "plugins" / "action-provider-coverage.md"
PLUGINS_ROOT = REPO_ROOT / "Plugins"


class ActionProviderCoverageTests(unittest.TestCase):
    def test_every_plugin_directory_is_a_provider_or_an_explicit_exclusion(self):
        document = COVERAGE_DOCUMENT.read_text(encoding="utf-8")
        providers = self.directory_names(
            document,
            "## Migrated providers",
            "Parameterized actions publish",
        )
        exclusions = self.directory_names(
            document,
            "## Intentionally specialized or non-operational",
            "Specialized shortcuts may remain",
        )
        manifest_directories = {
            path.parent.name for path in PLUGINS_ROOT.glob("*/plugin.json")
        }

        self.assertFalse(providers & exclusions)
        self.assertEqual(providers | exclusions, manifest_directories)

    @staticmethod
    def directory_names(document: str, start: str, end: str):
        section = document.split(start, 1)[1].split(end, 1)[0]
        return set(re.findall(r"`([A-Za-z][A-Za-z0-9]+)`", section))


if __name__ == "__main__":
    unittest.main()
