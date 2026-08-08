"""Validation shared by MacTools E2E checkpoint and report generation."""

from __future__ import annotations

import hashlib
import json
import math
import os
import subprocess


def _has_positive_duration(payload: dict) -> bool:
    candidates = [
        stream.get("duration")
        for stream in payload.get("streams", [])
        if isinstance(stream, dict)
    ]
    file_format = payload.get("format")
    if isinstance(file_format, dict):
        candidates.append(file_format.get("duration"))
    for candidate in candidates:
        try:
            duration = float(candidate)
        except (TypeError, ValueError):
            continue
        if math.isfinite(duration) and duration > 0:
            return True
    return False


def _is_parseable_video(path: str, ffprobe: str) -> bool:
    if not os.path.isfile(ffprobe) or not os.access(ffprobe, os.X_OK):
        return False
    try:
        result = subprocess.run(
            [
                ffprobe,
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_entries",
                "stream=codec_type,width,height,duration:format=format_name,duration",
                "-of",
                "json",
                path,
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=20,
        )
        if result.returncode != 0:
            return False
        payload = json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return False

    streams = payload.get("streams")
    if not isinstance(streams, list):
        return False
    has_sized_video = any(
        isinstance(stream, dict)
        and stream.get("codec_type") == "video"
        and isinstance(stream.get("width"), int)
        and stream["width"] > 0
        and isinstance(stream.get("height"), int)
        and stream["height"] > 0
        for stream in streams
    )
    return has_sized_video and _has_positive_duration(payload)


def recording_artifact_status(
    session: str,
    pack_id: str,
    ffprobe: str,
    minimum_mtime: float = 0,
):
    video_names = [
        f"screencast.{pack_id}.mov",
        f"screencast.{pack_id}.mp4",
    ]
    checksum_name = f"screencast.{pack_id}.sha256"
    expected_names = video_names + [checksum_name]
    missing = [
        filename
        for filename in expected_names
        if not os.path.isfile(os.path.join(session, filename))
        or os.path.getsize(os.path.join(session, filename)) == 0
    ]
    if missing:
        return missing, []

    invalid = []
    for filename in expected_names:
        path = os.path.join(session, filename)
        try:
            if os.path.getmtime(path) < minimum_mtime:
                invalid.append(filename)
        except OSError:
            invalid.append(filename)
    recorded_hashes = {}
    try:
        with open(os.path.join(session, checksum_name), encoding="utf-8") as handle:
            for raw_line in handle:
                parts = raw_line.strip().split(maxsplit=1)
                if len(parts) != 2 or len(parts[0]) != 64:
                    invalid.append(checksum_name)
                    continue
                filename = os.path.basename(parts[1].lstrip("*"))
                if filename in recorded_hashes:
                    invalid.append(checksum_name)
                    continue
                recorded_hashes[filename] = parts[0].lower()
    except (OSError, UnicodeError):
        return [], [checksum_name]

    if set(recorded_hashes) != set(video_names):
        invalid.append(checksum_name)
    for filename in video_names:
        path = os.path.join(session, filename)
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        if recorded_hashes.get(filename) != digest.hexdigest():
            invalid.append(filename)
        if not _is_parseable_video(path, ffprobe):
            invalid.append(filename)
    return [], sorted(set(invalid))
