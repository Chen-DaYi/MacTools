#!/usr/bin/env python3
"""Validation and projection for checked-in MacTools plugin manifests."""

from __future__ import annotations

import hashlib
import json
import re
import struct
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from urllib.parse import urlparse


SUPPORTED_LOCALES = {
    "ar", "de", "en", "es", "fr", "ja", "ko", "pt", "ru", "zh-Hans", "zh-Hant"
}
LOCALIZED_REFERENCES = {"@displayName", "@summary"}
VALID_CATEGORIES = {
    "display", "audio", "system", "storage", "productivity", "monitoring", "other"
}
VALID_PERMISSION_IDS = {
    "accessibility", "automation", "calendarFullAccess", "inputMonitoring",
    "screen-recording", "system-audio-recording"
}
VALID_SURFACES = {
    "unified-search", "global-shortcut", "run-link", "workflow", "automatic-rule",
    "action-grid", "trackpad-gesture", "app-intent", "manual"
}
VALID_RISKS = {"safe", "confirmationRequired"}
VALID_EXTERNAL_POLICIES = {"unavailable", "allowed", "confirmAlways"}
VALID_PROVIDER_KINDS = {"static", "dynamic", "mixed"}
VALID_PARAMETER_KINDS = {"boolean", "integer", "double", "string"}
VALID_PORTABILITY = {"portable", "localOnly"}
VALID_ARCHITECTURES = {"arm64", "x86_64"}
VALID_SETUP_COMPLEXITIES = {"none", "simple", "guided", "advanced"}
VALID_NETWORK_USE = {"none", "optional", "required"}
VALID_TELEMETRY = {"none", "optional", "required"}
VALID_RETENTION = {"none", "session", "until-disabled", "until-uninstalled", "user-controlled"}
MAX_ASSET_BYTES = 10 * 1024 * 1024
MAX_ASSET_DIMENSION = 7680
IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
DOMAIN_PATTERN = re.compile(
    r"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+"
    r"[A-Za-z]{2,63}$"
)


class ManifestValidationError(ValueError):
    pass


@dataclass(frozen=True)
class AssetProjection:
    source: Path
    catalog: dict


def expand_localized_references(manifest: dict) -> dict:
    """Expand source-only localization references for catalog and package projection."""
    projected = json.loads(json.dumps(manifest))
    metadata = projected.get("localizedMetadata", {})
    reference_values = {}
    for field in ("displayName", "summary"):
        fallback = metadata.get("en", {}).get(field) or projected.get(field)
        reference_values[f"@{field}"] = {
            locale: metadata.get(locale, {}).get(field, fallback)
            for locale in SUPPORTED_LOCALES
        }

    def expand(value: object) -> object:
        if isinstance(value, str) and value in reference_values:
            return dict(reference_values[value])
        if isinstance(value, list):
            return [expand(item) for item in value]
        if isinstance(value, dict):
            return {key: expand(item) for key, item in value.items()}
        return value

    for section in (
        "presentation", "discovery", "requirements", "privacy", "actions", "setup", "relationships"
    ):
        if section in projected:
            projected[section] = expand(projected[section])
    return projected


def _fail(plugin_id: str, field: str, message: str) -> None:
    raise ManifestValidationError(f"{plugin_id}: {field}: {message}")


def _require_keys(value: dict, keys: set[str], plugin_id: str, field: str) -> None:
    missing = sorted(keys - value.keys())
    if missing:
        _fail(plugin_id, field, "missing " + ", ".join(missing))


def _unique_strings(values: list, plugin_id: str, field: str) -> None:
    if not all(isinstance(value, str) and value.strip() for value in values):
        _fail(plugin_id, field, "must contain non-empty strings")
    if len(values) != len(set(values)):
        _fail(plugin_id, field, "contains duplicate values")


def _localized_text(value: object, plugin_id: str, field: str, require_all: bool = True) -> None:
    if not isinstance(value, dict) or not value:
        _fail(plugin_id, field, "must be a locale-to-string object")
    unknown = sorted(set(value) - SUPPORTED_LOCALES)
    if unknown:
        _fail(plugin_id, field, "uses unsupported locales: " + ", ".join(unknown))
    if require_all:
        missing = sorted(SUPPORTED_LOCALES - set(value))
        if missing:
            _fail(plugin_id, field, "missing locale fallback values: " + ", ".join(missing))
    if not all(isinstance(text, str) and text.strip() for text in value.values()):
        _fail(plugin_id, field, "contains an empty localized value")


def _identifier(value: object, plugin_id: str, field: str) -> None:
    if not isinstance(value, str) or not IDENTIFIER_PATTERN.fullmatch(value):
        _fail(plugin_id, field, "must be a stable identifier")


def _https_url(value: object, plugin_id: str, field: str) -> None:
    if value is None:
        return
    parsed = urlparse(value) if isinstance(value, str) else None
    if parsed is None or parsed.scheme != "https" or not parsed.netloc:
        _fail(plugin_id, field, "must be an HTTPS URL")


def _image_dimensions(path: Path, media_type: str) -> tuple[int | None, int | None]:
    data = path.read_bytes()
    if media_type == "image/png" and len(data) >= 24 and data[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", data[16:24])
    if media_type == "image/jpeg":
        index = 2
        while index + 9 < len(data):
            if data[index] != 0xFF:
                index += 1
                continue
            marker = data[index + 1]
            index += 2
            if marker in {0xD8, 0xD9}:
                continue
            if index + 2 > len(data):
                break
            length = int.from_bytes(data[index:index + 2], "big")
            if marker in {
                0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
            }:
                if index + 7 <= len(data):
                    return (
                        int.from_bytes(data[index + 5:index + 7], "big"),
                        int.from_bytes(data[index + 3:index + 5], "big"),
                    )
                break
            index += max(length, 2)
    return None, None


def _image_media_type(path: Path) -> str | None:
    header = path.read_bytes()[:16]
    if header.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if header.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if len(header) >= 12 and header[:4] == b"RIFF" and header[8:12] == b"WEBP":
        return "image/webp"
    return None


def _validate_asset(asset: dict, plugin_root: Path, plugin_id: str, field: str) -> AssetProjection:
    _require_keys(asset, {"id", "path", "alt"}, plugin_id, field)
    _identifier(asset["id"], plugin_id, f"{field}.id")
    _localized_text(asset["alt"], plugin_id, f"{field}.alt")
    relative = PurePosixPath(asset["path"])
    if relative.is_absolute() or ".." in relative.parts or relative.parts[:1] != ("MarketplaceAssets",):
        _fail(plugin_id, f"{field}.path", "must stay under MarketplaceAssets/")
    source = plugin_root.joinpath(*relative.parts)
    if not source.is_file():
        _fail(plugin_id, f"{field}.path", f"asset does not exist: {relative}")
    size = source.stat().st_size
    if size <= 0 or size > MAX_ASSET_BYTES:
        _fail(plugin_id, f"{field}.path", f"asset size must be 1...{MAX_ASSET_BYTES} bytes")
    media_type = _image_media_type(source)
    if media_type is None:
        _fail(plugin_id, f"{field}.path", "must be PNG, JPEG, or WebP")
    width, height = _image_dimensions(source, media_type)
    if width is not None and height is not None:
        if width <= 0 or height <= 0 or width > MAX_ASSET_DIMENSION or height > MAX_ASSET_DIMENSION:
            _fail(plugin_id, f"{field}.path", f"dimensions must not exceed {MAX_ASSET_DIMENSION}px")
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    projected = dict(asset)
    projected.update({"mediaType": media_type, "sha256": digest, "size": size})
    if width is not None and height is not None:
        projected.update({"width": width, "height": height})
    return AssetProjection(source=source, catalog=projected)


def _validate_parameters(parameters: object, plugin_id: str, field: str) -> None:
    if not isinstance(parameters, list):
        _fail(plugin_id, field, "must be an array")
    seen: set[str] = set()
    for index, parameter in enumerate(parameters):
        item_field = f"{field}[{index}]"
        if not isinstance(parameter, dict):
            _fail(plugin_id, item_field, "must be an object")
        _require_keys(parameter, {"id", "kind", "isRequired", "portability"}, plugin_id, item_field)
        _identifier(parameter["id"], plugin_id, f"{item_field}.id")
        if parameter["id"] in seen:
            _fail(plugin_id, f"{item_field}.id", "duplicates a parameter ID")
        seen.add(parameter["id"])
        if parameter["kind"] not in VALID_PARAMETER_KINDS:
            _fail(plugin_id, f"{item_field}.kind", "is not supported")
        if parameter["portability"] not in VALID_PORTABILITY:
            _fail(plugin_id, f"{item_field}.portability", "is not supported")
        if not isinstance(parameter["isRequired"], bool):
            _fail(plugin_id, f"{item_field}.isRequired", "must be a boolean")


def _validate_action_policy(action: dict, plugin_id: str, field: str) -> None:
    for key in ("permissionIDs", "surfaces", "keywords"):
        _unique_strings(action[key], plugin_id, f"{field}.{key}")
    invalid_permissions = sorted(set(action["permissionIDs"]) - VALID_PERMISSION_IDS)
    if invalid_permissions:
        _fail(plugin_id, f"{field}.permissionIDs", "unknown: " + ", ".join(invalid_permissions))
    invalid_surfaces = sorted(set(action["surfaces"]) - VALID_SURFACES)
    if invalid_surfaces:
        _fail(plugin_id, f"{field}.surfaces", "unknown: " + ", ".join(invalid_surfaces))
    if action["risk"] not in VALID_RISKS:
        _fail(plugin_id, f"{field}.risk", "is not supported")
    if action["externalInvocation"] not in VALID_EXTERNAL_POLICIES:
        _fail(plugin_id, f"{field}.externalInvocation", "is not supported")
    if not isinstance(action["automaticEligible"], bool):
        _fail(plugin_id, f"{field}.automaticEligible", "must be a boolean")
    if action["automaticEligible"] and "automatic-rule" not in action["surfaces"]:
        _fail(plugin_id, field, "automatic actions must include automatic-rule")


def _validate_actions(actions: dict, plugin_id: str) -> None:
    _require_keys(actions, {"providers"}, plugin_id, "actions")
    if not isinstance(actions["providers"], list) or not actions["providers"]:
        _fail(plugin_id, "actions.providers", "must be a non-empty array")
    seen_keys: set[tuple[str, str]] = set()
    seen_providers: set[str] = set()
    for provider_index, provider in enumerate(actions["providers"]):
        field = f"actions.providers[{provider_index}]"
        _require_keys(provider, {"id", "kind", "staticActions", "dynamicTemplates"}, plugin_id, field)
        _identifier(provider["id"], plugin_id, f"{field}.id")
        if provider["id"] in seen_providers:
            _fail(plugin_id, f"{field}.id", "duplicates a provider ID")
        seen_providers.add(provider["id"])
        if provider["kind"] not in VALID_PROVIDER_KINDS:
            _fail(plugin_id, f"{field}.kind", "is not supported")
        static_actions = provider["staticActions"]
        dynamic_templates = provider["dynamicTemplates"]
        if not isinstance(static_actions, list) or not isinstance(dynamic_templates, list):
            _fail(plugin_id, field, "action collections must be arrays")
        if provider["kind"] == "static" and (not static_actions or dynamic_templates):
            _fail(plugin_id, field, "static providers require only staticActions")
        if provider["kind"] == "dynamic" and (static_actions or not dynamic_templates):
            _fail(plugin_id, field, "dynamic providers require only dynamicTemplates")
        if provider["kind"] == "mixed" and (not static_actions or not dynamic_templates):
            _fail(plugin_id, field, "mixed providers require both action kinds")
        for index, action in enumerate(static_actions):
            action_field = f"{field}.staticActions[{index}]"
            _require_keys(action, {
                "id", "title", "description", "keywords", "systemImage", "parameters",
                "permissionIDs", "risk", "surfaces", "automaticEligible", "externalInvocation"
            }, plugin_id, action_field)
            _identifier(action["id"], plugin_id, f"{action_field}.id")
            key = (provider["id"], action["id"])
            if key in seen_keys:
                _fail(plugin_id, f"{action_field}.id", "duplicates a static action key")
            seen_keys.add(key)
            _localized_text(action["title"], plugin_id, f"{action_field}.title")
            _localized_text(action["description"], plugin_id, f"{action_field}.description")
            if "parameterSummary" in action:
                _localized_text(action["parameterSummary"], plugin_id, f"{action_field}.parameterSummary")
            _validate_parameters(action["parameters"], plugin_id, f"{action_field}.parameters")
            _validate_action_policy(action, plugin_id, action_field)
        for index, template in enumerate(dynamic_templates):
            template_field = f"{field}.dynamicTemplates[{index}]"
            _require_keys(template, {
                "id", "title", "description", "entrySource", "parameters", "parameterSummary",
                "localOnlyIdentity", "permissionIDs", "risk", "surfaces", "automaticEligible",
                "externalInvocation", "keywords"
            }, plugin_id, template_field)
            _identifier(template["id"], plugin_id, f"{template_field}.id")
            _localized_text(template["title"], plugin_id, f"{template_field}.title")
            _localized_text(template["description"], plugin_id, f"{template_field}.description")
            _localized_text(template["parameterSummary"], plugin_id, f"{template_field}.parameterSummary")
            if not isinstance(template["entrySource"], str) or not template["entrySource"].strip():
                _fail(plugin_id, f"{template_field}.entrySource", "must be non-empty")
            if not isinstance(template["localOnlyIdentity"], bool):
                _fail(plugin_id, f"{template_field}.localOnlyIdentity", "must be a boolean")
            _validate_parameters(template["parameters"], plugin_id, f"{template_field}.parameters")
            _validate_action_policy(template, plugin_id, template_field)


def validate_and_project_manifest(
    manifest: dict,
    manifest_path: Path,
    known_plugin_ids: set[str],
) -> tuple[dict, list[AssetProjection]]:
    manifest = expand_localized_references(manifest)
    plugin_id = manifest.get("id", manifest_path.parent.name)
    for section in ("presentation", "discovery", "requirements", "privacy", "actions", "setup", "relationships"):
        if section in manifest and not isinstance(manifest[section], dict):
            _fail(plugin_id, section, "must be an object")
    if "category" in manifest and manifest.get("category") not in VALID_CATEGORIES:
        _fail(plugin_id, "category", "is not a supported category")
    if "permissions" in manifest:
        invalid_permissions = sorted(set(manifest["permissions"]) - VALID_PERMISSION_IDS)
        if invalid_permissions:
            _fail(plugin_id, "permissions", "unknown: " + ", ".join(invalid_permissions))

    assets: list[AssetProjection] = []
    presentation = manifest.get("presentation")
    if presentation is not None:
        _require_keys(presentation, {
            "longDescription", "examples", "screenshots", "publisher", "license"
        }, plugin_id, "presentation")
        _localized_text(presentation["longDescription"], plugin_id, "presentation.longDescription")
        if not isinstance(presentation["examples"], list) or not isinstance(presentation["screenshots"], list):
            _fail(plugin_id, "presentation", "examples and screenshots must be arrays")
        example_ids = [example.get("id", "") for example in presentation["examples"]]
        _unique_strings(example_ids, plugin_id, "presentation.examples.id")
        for index, example in enumerate(presentation["examples"]):
            _localized_text(example.get("text"), plugin_id, f"presentation.examples[{index}].text")
        seen_asset_ids: set[str] = set()
        for index, asset in enumerate(presentation["screenshots"]):
            projected = _validate_asset(asset, manifest_path.parent, plugin_id, f"presentation.screenshots[{index}]")
            if projected.catalog["id"] in seen_asset_ids:
                _fail(plugin_id, f"presentation.screenshots[{index}].id", "duplicates an asset ID")
            seen_asset_ids.add(projected.catalog["id"])
            assets.append(projected)
        for key in ("documentationURL", "supportURL"):
            _https_url(presentation.get(key), plugin_id, f"presentation.{key}")

    discovery = manifest.get("discovery")
    if discovery is not None:
        _require_keys(discovery, {
            "keywords", "localizedSynonyms", "useCases", "goalCategories",
            "relatedPluginIDs", "alternativePluginIDs"
        }, plugin_id, "discovery")
        _unique_strings(discovery["keywords"], plugin_id, "discovery.keywords")
        if not isinstance(discovery["localizedSynonyms"], dict):
            _fail(plugin_id, "discovery.localizedSynonyms", "must be an object")
        missing_locales = sorted(SUPPORTED_LOCALES - set(discovery["localizedSynonyms"]))
        if missing_locales:
            _fail(plugin_id, "discovery.localizedSynonyms", "missing: " + ", ".join(missing_locales))
        for locale, synonyms in discovery["localizedSynonyms"].items():
            if locale not in SUPPORTED_LOCALES:
                _fail(plugin_id, "discovery.localizedSynonyms", f"unsupported locale {locale}")
            _unique_strings(synonyms, plugin_id, f"discovery.localizedSynonyms.{locale}")
        use_case_ids: list[str] = []
        for index, use_case in enumerate(discovery["useCases"]):
            _require_keys(use_case, {"id", "title"}, plugin_id, f"discovery.useCases[{index}]")
            _identifier(use_case["id"], plugin_id, f"discovery.useCases[{index}].id")
            use_case_ids.append(use_case["id"])
            _localized_text(use_case["title"], plugin_id, f"discovery.useCases[{index}].title")
        _unique_strings(use_case_ids, plugin_id, "discovery.useCases.id")
        for key in ("goalCategories", "relatedPluginIDs", "alternativePluginIDs"):
            _unique_strings(discovery[key], plugin_id, f"discovery.{key}")

    requirements = manifest.get("requirements")
    if requirements is not None:
        _require_keys(requirements, {
            "architectures", "hardware", "applications", "executables", "permissionIDs",
            "setupComplexity", "requiresRelaunch"
        }, plugin_id, "requirements")
        invalid_architectures = sorted(set(requirements["architectures"]) - VALID_ARCHITECTURES)
        if invalid_architectures:
            _fail(plugin_id, "requirements.architectures", "unknown: " + ", ".join(invalid_architectures))
        invalid_permissions = sorted(set(requirements["permissionIDs"]) - VALID_PERMISSION_IDS)
        if invalid_permissions:
            _fail(plugin_id, "requirements.permissionIDs", "unknown: " + ", ".join(invalid_permissions))
        if requirements["setupComplexity"] not in VALID_SETUP_COMPLEXITIES:
            _fail(plugin_id, "requirements.setupComplexity", "is not supported")

    privacy = manifest.get("privacy")
    if privacy is not None:
        _require_keys(privacy, {
            "dataObserved", "dataPersisted", "retention", "networkUse", "networkDomains",
            "telemetry", "processesSensitiveUserContent", "diagnosticExportsContainUserData"
        }, plugin_id, "privacy")
        if privacy["networkUse"] not in VALID_NETWORK_USE:
            _fail(plugin_id, "privacy.networkUse", "is not supported")
        if privacy["telemetry"] not in VALID_TELEMETRY:
            _fail(plugin_id, "privacy.telemetry", "is not supported")
        for domain in privacy["networkDomains"]:
            if not isinstance(domain, str) or not DOMAIN_PATTERN.fullmatch(domain):
                _fail(plugin_id, "privacy.networkDomains", f"invalid domain: {domain}")
        if "allowsUserConfiguredDomains" in privacy and not isinstance(
            privacy["allowsUserConfiguredDomains"], bool
        ):
            _fail(plugin_id, "privacy.allowsUserConfiguredDomains", "must be a boolean")
        retention = privacy["retention"]
        if not isinstance(retention, dict) or retention.get("policy") not in VALID_RETENTION:
            _fail(plugin_id, "privacy.retention.policy", "is not supported")
        if retention.get("description") is not None:
            _localized_text(retention["description"], plugin_id, "privacy.retention.description")

    if manifest.get("actions") is not None:
        _validate_actions(manifest["actions"], plugin_id)

    setup = manifest.get("setup")
    if setup is not None:
        _require_keys(setup, {"steps", "optionalSurfaces"}, plugin_id, "setup")
        for index, step in enumerate(setup["steps"]):
            _require_keys(step, {"id", "title", "description"}, plugin_id, f"setup.steps[{index}]")
            _identifier(step["id"], plugin_id, f"setup.steps[{index}].id")
            _localized_text(step["title"], plugin_id, f"setup.steps[{index}].title")
            _localized_text(step["description"], plugin_id, f"setup.steps[{index}].description")
        test_action = setup.get("suggestedTestAction")
        if test_action is not None:
            key = (test_action.get("providerID"), test_action.get("actionID"))
            static_keys = {
                (provider["id"], action["id"])
                for provider in manifest.get("actions", {}).get("providers", [])
                for action in provider.get("staticActions", [])
            }
            if key not in static_keys:
                _fail(plugin_id, "setup.suggestedTestAction", "must reference a declared static action")
        invalid_surfaces = sorted(set(setup["optionalSurfaces"]) - VALID_SURFACES)
        if invalid_surfaces:
            _fail(plugin_id, "setup.optionalSurfaces", "unknown: " + ", ".join(invalid_surfaces))
        if setup.get("missingDependencyHelp") is not None:
            _localized_text(setup["missingDependencyHelp"], plugin_id, "setup.missingDependencyHelp")

    relationships = manifest.get("relationships")
    if relationships is not None:
        _require_keys(relationships, {
            "relatedPluginIDs", "includedPackIDs", "suggestedRecipeIDs", "supersedesPluginIDs"
        }, plugin_id, "relationships")
        referenced = set(relationships["relatedPluginIDs"]) | set(relationships["supersedesPluginIDs"])
        missing = sorted(referenced - known_plugin_ids)
        if missing:
            _fail(plugin_id, "relationships", "references unknown plugins: " + ", ".join(missing))

    if discovery is not None:
        referenced = set(discovery["relatedPluginIDs"]) | set(discovery["alternativePluginIDs"])
        missing = sorted(referenced - known_plugin_ids)
        if missing:
            _fail(plugin_id, "discovery", "references unknown plugins: " + ", ".join(missing))

    projected = json.loads(json.dumps(manifest))
    if presentation is not None:
        projected["presentation"]["screenshots"] = [asset.catalog for asset in assets]
    projected.pop("build", None)
    projected.pop("package", None)
    return projected, assets


def load_known_plugin_ids(plugins_root: Path) -> set[str]:
    if (plugins_root / "plugin.json").is_file():
        return {
            json.loads((plugins_root / "plugin.json").read_text(encoding="utf-8"))["id"]
        }
    result = set()
    for path in plugins_root.glob("*/plugin.json"):
        plugin_id = json.loads(path.read_text(encoding="utf-8"))["id"]
        if plugin_id in result:
            raise ManifestValidationError(
                f"{plugin_id}: id: duplicates another plugin manifest under {plugins_root}"
            )
        result.add(plugin_id)
    return result
