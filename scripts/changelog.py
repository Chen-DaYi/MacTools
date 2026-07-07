#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import re
import sys
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[1]
CHANGELOG_PATH = ROOT_DIR / "CHANGELOG.md"
FRAGMENT_DIR = ROOT_DIR / "changes" / "unreleased"
FRONT_MATTER_RE = re.compile(r"\A---\n(.*?)\n---\n?", re.DOTALL)
VERSION_HEADER_RE = re.compile(r"(?m)^## \[([^\]]+)\](?: - .*)?$")
CJK_RE = re.compile(r"[\u3400-\u9fff]")

TYPE_ORDER = [
    "summary",
    "added",
    "changed",
    "deprecated",
    "removed",
    "fixed",
    "security",
    "maintenance",
]
TYPE_TITLES = {
    "summary": "Summary",
    "added": "Added",
    "changed": "Changed",
    "deprecated": "Deprecated",
    "removed": "Removed",
    "fixed": "Fixed",
    "security": "Security",
    "maintenance": "Maintenance",
}
RELEASE_TARGETS = {"app", "plugin"}
MAX_ENTRY_CHARS = 220
MAX_ENTRY_SENTENCES = 2
NEAR_DUPLICATE_THRESHOLD = 0.96


class ChangelogError(RuntimeError):
    pass


@dataclass(frozen=True)
class Fragment:
    path: Path
    release: str
    type: str
    area: str | None
    entries: list[str]


def fail(message: str) -> None:
    raise ChangelogError(message)


def relative(path: Path) -> str:
    return path.relative_to(ROOT_DIR).as_posix()


def strip_optional_quotes(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1].strip()
    return value


def parse_front_matter(text: str, path: Path) -> tuple[dict[str, str], str]:
    match = FRONT_MATTER_RE.match(text)
    if not match:
        fail(f"{relative(path)} must start with YAML front matter.")

    metadata: dict[str, str] = {}
    for index, raw_line in enumerate(match.group(1).splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            fail(f"{relative(path)} front matter line {index} must use `key: value`.")
        key, value = line.split(":", 1)
        key = key.strip()
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", key):
            fail(f"{relative(path)} front matter key is invalid: {key}")
        metadata[key] = strip_optional_quotes(value)
    return metadata, text[match.end() :]


def clean_entry(value: str) -> str:
    value = re.sub(r"\s+", " ", value).strip()
    value = value.removeprefix("- ").strip()
    return value


def split_entries(body: str, path: Path) -> list[str]:
    lines = body.splitlines()
    bullet_entries: list[str] = []
    current: list[str] = []

    def flush_bullet() -> None:
        if not current:
            return
        entry = clean_entry(" ".join(current))
        if entry:
            bullet_entries.append(entry)
        current.clear()

    for raw_line in lines:
        line = raw_line.rstrip()
        stripped = line.strip()
        if stripped.startswith("- "):
            flush_bullet()
            current.append(stripped[2:])
            continue
        if current and (not stripped or line.startswith((" ", "\t"))):
            if stripped:
                current.append(stripped)
            continue
        if current:
            fail(f"{relative(path)} mixes bullet entries with plain text. Use one style.")
        if stripped.startswith("#"):
            fail(f"{relative(path)} must not include markdown headings.")
    flush_bullet()

    if bullet_entries:
        return bullet_entries

    paragraphs: list[str] = []
    current_paragraph: list[str] = []
    for raw_line in lines:
        stripped = raw_line.strip()
        if not stripped:
            if current_paragraph:
                paragraphs.append(clean_entry(" ".join(current_paragraph)))
                current_paragraph.clear()
            continue
        current_paragraph.append(stripped)
    if current_paragraph:
        paragraphs.append(clean_entry(" ".join(current_paragraph)))
    return [paragraph for paragraph in paragraphs if paragraph]


def sentence_count(entry: str) -> int:
    return len(re.findall(r"[.!?](?:\s|$)", entry))


def validate_entry(entry: str, path: Path) -> None:
    if CJK_RE.search(entry):
        fail(f"{relative(path)} entries must be written in English.")
    if len(entry) > MAX_ENTRY_CHARS:
        fail(
            f"{relative(path)} entry is too long ({len(entry)} chars, max {MAX_ENTRY_CHARS}): "
            f"{entry}"
        )
    if sentence_count(entry) > MAX_ENTRY_SENTENCES:
        fail(f"{relative(path)} entry should stay concise: {entry}")
    if entry.endswith((".", "!", "?")) is False:
        fail(f"{relative(path)} entry must end with punctuation: {entry}")


def parse_fragment(path: Path) -> Fragment:
    metadata, body = parse_front_matter(path.read_text(encoding="utf-8"), path)
    release = metadata.get("release", "").strip().lower()
    if release not in RELEASE_TARGETS:
        allowed = ", ".join(sorted(RELEASE_TARGETS))
        fail(f"{relative(path)} has invalid release `{release}`. Expected one of: {allowed}.")

    fragment_type = metadata.get("type", "").strip().lower()
    if fragment_type not in TYPE_TITLES:
        allowed = ", ".join(TYPE_ORDER)
        fail(f"{relative(path)} has invalid type `{fragment_type}`. Expected one of: {allowed}.")

    entries = split_entries(body, path)
    if not entries:
        fail(f"{relative(path)} has no changelog entries.")
    if fragment_type == "summary" and len(entries) > 1:
        fail(f"{relative(path)} summary fragments must contain one concise paragraph.")
    for entry in entries:
        validate_entry(entry, path)

    area = metadata.get("area") or None
    return Fragment(path=path, release=release, type=fragment_type, area=area, entries=entries)


def pending_fragment_paths() -> list[Path]:
    if not FRAGMENT_DIR.exists():
        return []
    return sorted(path for path in FRAGMENT_DIR.glob("*.md") if path.is_file())


def load_fragments(require_pending: bool, release: str | None) -> list[Fragment]:
    paths = pending_fragment_paths()
    fragments = [parse_fragment(path) for path in paths]
    validate_no_near_duplicates(fragments)
    if release is not None:
        fragments = [fragment for fragment in fragments if fragment.release == release]
    if require_pending and not fragments:
        scope = f" {release}" if release else ""
        fail(f"No pending{scope} changelog fragments found in changes/unreleased/*.md.")
    return fragments


def normalized_entry(entry: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", entry.lower()).strip()


def validate_no_near_duplicates(fragments: list[Fragment]) -> None:
    seen: list[tuple[str, Fragment, str]] = []
    for fragment in fragments:
        for entry in fragment.entries:
            normalized = normalized_entry(entry)
            for previous_normalized, previous_fragment, previous_entry in seen:
                if normalized == previous_normalized:
                    fail(
                        "Duplicate changelog entries found in "
                        f"{relative(previous_fragment.path)} and {relative(fragment.path)}: {entry}"
                    )
                score = SequenceMatcher(None, previous_normalized, normalized).ratio()
                if score >= NEAR_DUPLICATE_THRESHOLD:
                    fail(
                        "Near-duplicate changelog entries found in "
                        f"{relative(previous_fragment.path)} and {relative(fragment.path)}:\n"
                        f"- {previous_entry}\n"
                        f"- {entry}"
                    )
            seen.append((normalized, fragment, entry))


def grouped_entries(fragments: list[Fragment]) -> dict[str, list[str]]:
    grouped: dict[str, list[str]] = {entry_type: [] for entry_type in TYPE_ORDER}
    seen: set[str] = set()
    for fragment in fragments:
        for entry in fragment.entries:
            key = normalized_entry(entry)
            if key in seen:
                continue
            seen.add(key)
            grouped[fragment.type].append(entry)
    return {entry_type: entries for entry_type, entries in grouped.items() if entries}


def render_release(title: str, date: str, fragments: list[Fragment]) -> str:
    sections = grouped_entries(fragments)
    lines = [f"## [{title}] - {date}", ""]
    for entry_type in TYPE_ORDER:
        entries = sections.get(entry_type)
        if not entries:
            continue
        lines.extend([f"### {TYPE_TITLES[entry_type]}", ""])
        if entry_type == "summary":
            for entry in entries:
                lines.extend([entry, ""])
        else:
            lines.extend(f"- {entry}" for entry in entries)
            lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def default_changelog() -> str:
    return (
        "# Changelog\n\n"
        "All notable changes to this project are documented here. The format follows\n"
        "[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses\n"
        "[Semantic Versioning](https://semver.org/).\n\n"
        "Pending release notes live in `changes/unreleased/*.md` and are compiled during\n"
        "the app and plugin release processes.\n"
    )


def insert_release(content: str, title: str, release_text: str) -> str:
    if re.search(rf"(?m)^## \[{re.escape(title)}\](?: - .*)?$", content):
        fail(f"CHANGELOG.md already has an entry for {title}.")

    stripped = content.rstrip()
    match = VERSION_HEADER_RE.search(stripped)
    if match:
        return stripped[: match.start()].rstrip() + "\n\n" + release_text.rstrip() + "\n\n" + stripped[match.start() :].lstrip() + "\n"
    return stripped + "\n\n" + release_text.rstrip() + "\n"


def prepare(release: str, title: str, release_date: str, dry_run: bool) -> None:
    fragments = load_fragments(require_pending=True, release=release)
    release_text = render_release(title, release_date, fragments)
    if dry_run:
        sys.stdout.write(release_text)
        return

    content = CHANGELOG_PATH.read_text(encoding="utf-8") if CHANGELOG_PATH.exists() else default_changelog()
    CHANGELOG_PATH.write_text(insert_release(content, title, release_text), encoding="utf-8")
    for fragment in fragments:
        fragment.path.unlink()


def extract(title: str) -> str:
    if not CHANGELOG_PATH.exists():
        fail("CHANGELOG.md does not exist.")
    content = CHANGELOG_PATH.read_text(encoding="utf-8")
    matches = list(VERSION_HEADER_RE.finditer(content))
    for index, match in enumerate(matches):
        if match.group(1) != title:
            continue
        start = content.find("\n", match.end())
        if start == -1:
            fail(f"CHANGELOG.md entry for {title} is empty.")
        end = matches[index + 1].start() if index + 1 < len(matches) else len(content)
        notes = content[start + 1 : end].strip()
        if not notes:
            fail(f"CHANGELOG.md entry for {title} is empty.")
        return notes + "\n"
    fail(f"CHANGELOG.md has no entry for {title}.")


def validate(require_pending: bool, release: str | None) -> None:
    load_fragments(require_pending=require_pending, release=release)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Manage MacTools changelog fragments.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_parser = subparsers.add_parser("validate", help="Validate pending changelog fragments.")
    validate_parser.add_argument("--release", choices=sorted(RELEASE_TARGETS), help="Validate one release target.")
    validate_parser.add_argument(
        "--require-pending",
        action="store_true",
        help="Fail when changes/unreleased contains no markdown fragments.",
    )

    prepare_parser = subparsers.add_parser("prepare", help="Compile pending fragments into CHANGELOG.md.")
    prepare_parser.add_argument("--release", choices=sorted(RELEASE_TARGETS), required=True)
    prepare_parser.add_argument("--tag", required=True, help="Release tag, for example v1.0.28 or plugins-1.0.29.")
    prepare_parser.add_argument(
        "--date",
        default=dt.date.today().isoformat(),
        help="Release date in YYYY-MM-DD format. Defaults to today.",
    )
    prepare_parser.add_argument("--dry-run", action="store_true", help="Print the release entry only.")

    extract_parser = subparsers.add_parser("extract", help="Extract one version from CHANGELOG.md.")
    extract_parser.add_argument("--tag", required=True, help="Release tag, for example v1.0.28 or plugins-1.0.29.")
    extract_parser.add_argument("--output", help="Write notes to this file instead of stdout.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.command == "validate":
            validate(require_pending=args.require_pending, release=args.release)
        elif args.command == "prepare":
            prepare(args.release, args.tag, args.date, args.dry_run)
        elif args.command == "extract":
            notes = extract(args.tag)
            if args.output:
                Path(args.output).write_text(notes, encoding="utf-8")
            else:
                sys.stdout.write(notes)
        else:
            fail(f"Unknown command: {args.command}")
    except ChangelogError as error:
        print(f"[changelog] error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
