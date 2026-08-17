#!/usr/bin/env python3
"""Check, and optionally finish, the sample-story-assets prefix rename.

Background
----------
20260819000000 renamed the sample asset prefix by updating `storage.objects.name` in SQL. That row
is an index over an object store, not a path column: the bytes stayed at the old key and every read
started 404ing with NoSuchKey while `list` kept reporting the object as present. 20260822090000
puts the names back, which is what makes the images load again.

This script performs the rename the way it has to be performed — through the Storage API, which
copies the bytes to the new key before it rewrites the row — and re-points the sample tables
afterwards so nothing is left addressing the old prefix.

Running it is optional. After the migration the pack works under `storytopia-first-run/`; this is
only what collapses that back to a single prefix matching `authoringPackSlug` in
SupabaseSampleStoryService.

Usage
-----
    export SUPABASE_SERVICE_ROLE_KEY=...          # Project Settings -> API -> service_role
    python3 supabase/scripts/repair_sample_storage_paths.py check
    python3 supabase/scripts/repair_sample_storage_paths.py move --apply

`check` is read-only and needs no key beyond the anon one. `move` without --apply is a dry run.
The service role key bypasses RLS; keep it out of the client and out of git.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BUCKET = "sample-story-assets"
OLD_PREFIX = "storytopia-first-run/"
NEW_PREFIX = "journaltopia-first-run/"
XCCONFIG = Path(__file__).resolve().parents[2] / "Config" / "Supabase.xcconfig"

# The columns that address the bucket. sample_journals.cover_storage_path is here because
# 20260819000000 missed it; it is on the old prefix today and has to move with everything else.
PATH_COLUMNS = [
    ("sample_storyboard_pages", "storage_path"),
    ("sample_entry_assets", "storage_path"),
    ("sample_journals", "cover_storage_path"),
]


def read_xcconfig(key: str) -> str | None:
    if not XCCONFIG.exists():
        return None
    for line in XCCONFIG.read_text().splitlines():
        name, sep, value = line.partition("=")
        if sep and name.strip() == key:
            # SUPABASE_URL carries a `$()` splice so xcconfig does not eat the `//`.
            return value.strip().replace("$()", "")
    return None


def request(method: str, url: str, key: str, body: dict | None = None) -> tuple[int, bytes]:
    data = json.dumps(body).encode() if body is not None else None
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def list_objects(base: str, key: str) -> list[str]:
    """Every object in the bucket. `list` is one directory level at a time, so this walks it."""
    found: list[str] = []

    def walk(prefix: str) -> None:
        offset = 0
        while True:
            status, raw = request(
                "POST",
                f"{base}/storage/v1/object/list/{BUCKET}",
                key,
                {"prefix": prefix, "limit": 100, "offset": offset},
            )
            if status != 200:
                raise SystemExit(f"list {prefix!r} failed ({status}): {raw.decode(errors='replace')}")

            page = json.loads(raw)
            for entry in page:
                name = prefix + entry["name"]
                # A folder is synthesised by the API and carries no id.
                if entry.get("id"):
                    found.append(name)
                else:
                    walk(name + "/")

            if len(page) < 100:
                return
            offset += len(page)

    walk("")
    return found


def is_readable(base: str, name: str) -> bool:
    """A HEAD against the public endpoint. The bucket is public, so this needs no credentials."""
    url = f"{base}/storage/v1/object/public/{BUCKET}/{urllib.parse.quote(name)}"
    req = urllib.request.Request(url, method="HEAD")
    try:
        with urllib.request.urlopen(req):
            return True
    except urllib.error.HTTPError:
        return False


def command_check(base: str, key: str) -> int:
    objects = list_objects(base, key)
    if not objects:
        print(f"{BUCKET} is empty.")
        return 0

    broken = [name for name in objects if not is_readable(base, name)]
    prefixes: dict[str, int] = {}
    for name in objects:
        prefixes[name.split("/", 1)[0] + "/"] = prefixes.get(name.split("/", 1)[0] + "/", 0) + 1

    print(f"{len(objects)} objects in {BUCKET}")
    for prefix, count in sorted(prefixes.items()):
        print(f"  {prefix:<28} {count}")
    print()

    if broken:
        print(f"{len(broken)} listed but not readable — metadata and bytes disagree:")
        for name in broken[:10]:
            print(f"  {name}")
        if len(broken) > 10:
            print(f"  … and {len(broken) - 10} more")
        print("\nApply 20260822090000 (supabase db push) before running `move`.")
        return 1

    print("All objects readable.")
    return 0


def command_move(base: str, key: str, apply: bool) -> int:
    objects = list_objects(base, key)
    stale = sorted(name for name in objects if name.startswith(OLD_PREFIX))
    if not stale:
        print(f"Nothing on {OLD_PREFIX} — already renamed.")
        return 0

    unreadable = [name for name in stale if not is_readable(base, name)]
    if unreadable:
        print(
            f"{len(unreadable)} of {len(stale)} objects are listed but not readable.\n"
            "Their rows still disagree with their bytes, and moving a row whose object cannot be\n"
            "read would lose the object. Apply 20260822090000 first, then re-run.",
            file=sys.stderr,
        )
        return 1

    print(f"{len(stale)} objects to move from {OLD_PREFIX} to {NEW_PREFIX}")
    if not apply:
        for name in stale[:10]:
            print(f"  {name}  ->  {NEW_PREFIX + name[len(OLD_PREFIX):]}")
        if len(stale) > 10:
            print(f"  … and {len(stale) - 10} more")
        print("\nDry run. Re-run with --apply to perform the moves.")
        return 0

    moved = 0
    for name in stale:
        destination = NEW_PREFIX + name[len(OLD_PREFIX):]
        status, raw = request(
            "POST",
            f"{base}/storage/v1/object/move",
            key,
            {"bucketId": BUCKET, "sourceKey": name, "destinationKey": destination},
        )
        if status != 200:
            print(
                f"\nmove failed for {name} ({status}): {raw.decode(errors='replace')}\n"
                f"{moved} objects were moved before this point. The path columns have NOT been\n"
                "updated, so the pack is still serving from the old prefix for anything unmoved.\n"
                "Re-running is safe: already-moved objects are skipped.",
                file=sys.stderr,
            )
            return 1
        moved += 1
        print(f"  moved {name}")

    print(f"\n{moved} objects moved. Re-pointing the sample tables:")
    for table, column in PATH_COLUMNS:
        # PostgREST has no regexp_replace in a PATCH body, so each row is rewritten by value.
        status, raw = request(
            "GET",
            f"{base}/rest/v1/{table}?select=id,{column}"
            f"&{column}=like.{urllib.parse.quote(OLD_PREFIX + '*')}",
            key,
        )
        if status != 200:
            print(f"  {table}.{column}: read failed ({status}): {raw.decode(errors='replace')}", file=sys.stderr)
            return 1

        rows = json.loads(raw)
        for row in rows:
            updated = NEW_PREFIX + row[column][len(OLD_PREFIX):]
            status, raw = request(
                "PATCH",
                f"{base}/rest/v1/{table}?id=eq.{row['id']}",
                key,
                {column: updated},
            )
            if status not in (200, 204):
                print(
                    f"  {table}.{column} row {row['id']}: update failed ({status}): "
                    f"{raw.decode(errors='replace')}",
                    file=sys.stderr,
                )
                return 1
        print(f"  {table}.{column}: {len(rows)} rows")

    print("\nDone. Run `check` to confirm.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["check", "move"])
    parser.add_argument("--apply", action="store_true", help="perform the moves (default is a dry run)")
    args = parser.parse_args()

    base = (os.environ.get("SUPABASE_URL") or read_xcconfig("SUPABASE_URL") or "").rstrip("/")
    if not base:
        print("SUPABASE_URL not set and not found in Config/Supabase.xcconfig", file=sys.stderr)
        return 2

    if args.command == "move":
        key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
        if not key:
            print("SUPABASE_SERVICE_ROLE_KEY is required for `move`", file=sys.stderr)
            return 2
        return command_move(base, key, args.apply)

    key = (
        os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
        or os.environ.get("SUPABASE_ANON_KEY")
        or read_xcconfig("SUPABASE_ANON_KEY")
    )
    if not key:
        print("No key available; set SUPABASE_ANON_KEY or fill Config/Supabase.xcconfig", file=sys.stderr)
        return 2
    return command_check(base, key)


if __name__ == "__main__":
    sys.exit(main())
