#!/usr/bin/env python3
import argparse
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional


def validate_catalog(catalog: dict) -> None:
    assets = catalog.get("assets", [])
    for asset in assets:
        asset_id = asset.get("id", "<unknown>")
        rendering_mode = asset.get("renderingMode")
        if rendering_mode not in {"original", "template"}:
            raise SystemExit(
                f"Icon gallery asset {asset_id!r} must declare renderingMode as 'original' or 'template'."
            )


def copy_gallery(source_dir: Path, output_dir: Path) -> None:
    if output_dir.exists():
        shutil.rmtree(output_dir)

    shutil.copytree(
        source_dir,
        output_dir,
        ignore=shutil.ignore_patterns(".DS_Store"),
    )


def rewrite_catalog(output_dir: Path, catalog_name: str, base_url: Optional[str]) -> Path:
    source_catalog = output_dir / "catalog.json"
    target_catalog = output_dir / catalog_name

    with source_catalog.open("r", encoding="utf-8") as file:
        catalog = json.load(file)

    validate_catalog(catalog)
    catalog["generatedAt"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    catalog["baseURL"] = base_url or (output_dir.as_uri() + "/")

    with target_catalog.open("w", encoding="utf-8") as file:
        json.dump(catalog, file, ensure_ascii=False, indent=2, sort_keys=True)
        file.write("\n")

    if target_catalog != source_catalog:
        source_catalog.unlink()

    return target_catalog


def main() -> None:
    parser = argparse.ArgumentParser(description="Copy the checked-in icon gallery for local debugging.")
    parser.add_argument("--gallery-dir", default="docs/icon-gallery")
    parser.add_argument("--output-dir", default="build/LocalIconGallery")
    parser.add_argument("--catalog-name", default="catalog.dev.json")
    parser.add_argument("--base-url", help="Catalog baseURL. Defaults to a file:// URL for the output directory.")
    args = parser.parse_args()

    source_dir = Path(args.gallery_dir).resolve()
    output_dir = Path(args.output_dir).resolve()

    if not (source_dir / "catalog.json").is_file():
        raise SystemExit(f"Icon gallery catalog not found: {source_dir / 'catalog.json'}")

    copy_gallery(source_dir, output_dir)
    catalog_path = rewrite_catalog(output_dir, args.catalog_name, args.base_url)

    with catalog_path.open("r", encoding="utf-8") as file:
        catalog = json.load(file)

    print(f"Icon catalog: {catalog_path}")
    print(f"Assets: {len(catalog.get('assets', []))}")


if __name__ == "__main__":
    main()
