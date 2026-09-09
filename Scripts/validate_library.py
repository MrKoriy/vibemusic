#!/usr/bin/env python3
"""Валидация Sources/VibemusicCore/Resources/library.json.

Проверяет структуру категорий и треков, печатает итоговую статистику
и список повторяющихся videoID между категориями (это допустимо —
трек может входить в несколько режимов — но показывается для обзора).
"""
import json
import re
import sys
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LIBRARY_PATH = REPO_ROOT / "Sources" / "VibemusicCore" / "Resources" / "library.json"

ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")

errors = []


def fail(msg: str) -> None:
    errors.append(msg)


def main() -> int:
    if not LIBRARY_PATH.is_file():
        print(f"ERROR: library not found: {LIBRARY_PATH}", file=sys.stderr)
        return 1

    try:
        with open(LIBRARY_PATH, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"ERROR: cannot parse {LIBRARY_PATH}: {e}", file=sys.stderr)
        return 1

    categories = data.get("categories")
    if not isinstance(categories, list) or not categories:
        print("ERROR: 'categories' must be a non-empty list", file=sys.stderr)
        return 1

    category_ids = []
    all_track_ids = []
    tracks_total = 0

    for ci, cat in enumerate(categories, 1):
        if not isinstance(cat, dict):
            fail(f"category #{ci}: not an object")
            continue
        label = f"category '{cat.get('id') or f'#{ci}'}'"
        cat_id = cat.get("id")
        cat_title = cat.get("title")
        if not isinstance(cat_id, str) or not cat_id.strip():
            fail(f"{label}: empty or missing 'id'")
        else:
            category_ids.append(cat_id)
        if not isinstance(cat_title, str) or not cat_title.strip():
            fail(f"{label}: empty or missing 'title'")

        tracks = cat.get("tracks")
        if not isinstance(tracks, list) or not tracks:
            fail(f"{label}: 'tracks' must be a non-empty list")
            continue

        for ti, track in enumerate(tracks, 1):
            tlabel = f"{label} track #{ti}"
            if not isinstance(track, dict):
                fail(f"{tlabel}: not an object")
                continue
            tid = track.get("id")
            title = track.get("title")
            if not isinstance(tid, str) or not ID_RE.match(tid):
                fail(f"{tlabel}: 'id' must be 11 chars [A-Za-z0-9_-], got: {tid!r}")
            else:
                all_track_ids.append(tid)
            if not isinstance(title, str) or not title.strip():
                fail(f"{tlabel}: empty or missing 'title'")
            tracks_total += 1

    dup_cat_ids = sorted(
        cid for cid, n in Counter(category_ids).items() if n > 1
    )
    if dup_cat_ids:
        fail(f"duplicate category ids: {', '.join(dup_cat_ids)}")

    dup_track_ids = {tid: n for tid, n in Counter(all_track_ids).items() if n > 1}

    if errors:
        print("LIBRARY VALIDATION FAILED:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)

    print(f"CATEGORIES={len(categories)} TRACKS={tracks_total} UNIQUE_IDS={len(set(all_track_ids))}")
    if dup_track_ids:
        print("Duplicate track ids across categories (allowed, listed for review):")
        for tid, n in sorted(dup_track_ids.items()):
            print(f"  {tid} x{n}")

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
