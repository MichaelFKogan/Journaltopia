#!/usr/bin/env python3
"""Recover the journaltopia-media objects orphaned by 20260819000000.

STATUS: done, and this script will not run as-is. All 86 objects were recovered and verified, and
20260827090000 dropped the three helper functions it calls — park_media_object, unpark_media_object
and media_object_inventory — because a function that can hide any object from the app is not one to
leave deployed once it is no longer needed. Re-apply 20260826090000 to use this again. It is kept in
the tree as the record of how the recovery was performed, and as the worked example of the only
correct way to move a Storage object: park the row, then let the Storage API move the bytes.

Background
----------
20260819000000 renamed the media bucket by updating `storage.objects.bucket_id` in SQL:

    update storage.objects set bucket_id = 'journaltopia-media' where bucket_id = 'storytopia-media';

That row is an index over an object store, not a path column. The bytes live under a key derived
from `bucket_id/name/version`, so the rows moved and the payloads did not. Every object in
journaltopia-media lists correctly — right size, right mime type — and 404s with NoSuchKey on read.
It is the same failure 20260822090000 documents for `name` in sample-story-assets, in a second
column of the same migration.

Walking bucket_id back in SQL would make the objects readable again, but only under the legacy
bucket, and the app addresses `journaltopia-media` through a hardcoded constant in four services.
So each object has to be relocated for real, and only the Storage API can do that: it copies the
bytes to the new key before it rewrites the row.

Hence two phases per object:

    1. park      journaltopia-media -> storytopia-media, in SQL, via park_media_object().
                 Metadata only. This is what makes the bytes reachable, because it puts the row
                 back on the bucket its payload is actually keyed under.
    2. relocate  storytopia-media -> journaltopia-media, through the Storage API, which moves the
                 bytes and rewrites the row itself.

Phase 1 is SQL because no API call can address an object whose bytes its row cannot find. Phase 2
is the API because no SQL statement can move bytes. Neither phase touches application tables:
entry_characters, entry_reference_photos and entries are never read or written here. The storage
rows keep their `version`, which is half the S3 key and the only thing that cannot be reconstructed.

Strategy
--------
`--strategy copy` (the default) leaves the parked row and its original bytes in storytopia-media and
creates a fresh readable object in journaltopia-media. Nothing is deleted and the originals remain
as a backup. `--strategy move` relocates the single row instead, leaving no copy behind. Copy is the
default because 86 small images cost nothing to keep twice, and because a repair that cannot lose
data is worth more than a tidy legacy bucket. Neither strategy deletes the storytopia-media bucket.

Idempotence and resumability
----------------------------
Every object is probed before it is touched: anything already readable in journaltopia-media is
recorded as healthy and skipped, so a re-run after a partial failure re-does nothing. Progress is
written to a ledger after every state transition, and a resumed run picks each object up at the
stage it stopped. If a run is interrupted between park and relocate, the affected rows sit on
storytopia-media and are invisible to the app until `rollback` (or another `repair` run) moves them
on; `rollback` unparks exactly those rows and nothing else.

Usage
-----
    export SUPABASE_SERVICE_ROLE_KEY=...      # Project Settings -> API -> service_role

    python3 supabase/scripts/repair_media_bucket_paths.py scan          # read-only census
    python3 supabase/scripts/repair_media_bucket_paths.py snapshot      # required before repair
    python3 supabase/scripts/repair_media_bucket_paths.py repair        # dry run
    python3 supabase/scripts/repair_media_bucket_paths.py repair --apply --limit 1
    python3 supabase/scripts/repair_media_bucket_paths.py repair --apply
    python3 supabase/scripts/repair_media_bucket_paths.py verify
    python3 supabase/scripts/repair_media_bucket_paths.py rollback --apply   # if interrupted

`repair` refuses to run without a snapshot on disk. Artifacts land in --work-dir (default
./media-repair): snapshot.json, ledger.json, scan.json. The service role key bypasses RLS; keep it
out of the client and out of git.

Requires 20260826090000_add_media_object_repair_helpers.sql. Once the repair verifies clean, drop
the helpers — they are tooling, not schema:

    drop function if exists public.park_media_object(text);
    drop function if exists public.unpark_media_object(text);
    drop function if exists public.media_object_inventory();
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BUCKET = "journaltopia-media"
LEGACY_BUCKET = "storytopia-media"
XCCONFIG = Path(__file__).resolve().parents[2] / "Config" / "Supabase.xcconfig"

# Ledger states. Only VERIFIED is terminal; PARKED is the one that means a row is currently
# invisible to the application and a rollback has something to do.
HEALTHY = "healthy"        # readable before this tool touched it
PARKED = "parked"          # row sits on storytopia-media, mid-flight
RELOCATED = "relocated"    # Storage API call succeeded, not yet confirmed
VERIFIED = "verified"      # readable in journaltopia-media
FAILED = "failed"


# --- transport --------------------------------------------------------------------------------

def read_xcconfig(key: str) -> str | None:
    if not XCCONFIG.exists():
        return None
    for line in XCCONFIG.read_text().splitlines():
        name, sep, value = line.partition("=")
        if sep and name.strip() == key:
            # SUPABASE_URL carries a `$()` splice so xcconfig does not eat the `//`.
            return value.strip().replace("$()", "")
    return None


def request(method, url, key, body=None, headers=None):
    data = json.dumps(body).encode() if body is not None else None
    request_headers = {"apikey": key, "Authorization": "Bearer " + key}
    if data is not None:
        request_headers["Content-Type"] = "application/json"
    if headers:
        request_headers.update(headers)

    req = urllib.request.Request(url, data=data, headers=request_headers, method=method)
    try:
        with urllib.request.urlopen(req) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()
    except urllib.error.URLError as error:
        return 0, str(error).encode()


def rpc(base, key, function, body=None):
    status, raw = request("POST", base + "/rest/v1/rpc/" + function, key, body or {})
    text = raw.decode(errors="replace")
    if status not in (200, 204):
        return status, None, text
    try:
        return status, json.loads(text) if text else [], ""
    except ValueError:
        return status, None, text


# --- storage ----------------------------------------------------------------------------------

def list_objects(base, key, bucket):
    """Every object in a bucket. `list` is one directory level at a time, so this walks it."""
    found = []

    def walk(prefix):
        offset = 0
        while True:
            status, raw = request(
                "POST",
                base + "/storage/v1/object/list/" + bucket,
                key,
                {"prefix": prefix, "limit": 100, "offset": offset},
            )
            if status != 200:
                raise SystemExit("list {!r} failed ({}): {}".format(prefix, status, raw.decode(errors="replace")))

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
    return sorted(found)


def probe(base, key, bucket, name):
    """Is this object's payload actually retrievable? Returns (state, detail).

    A Range request so a census does not pull 86 full images. The distinction that matters is
    NoSuchKey — row present, bytes unreachable, which is this bug — against a plain 404, which is
    a path with no row at all and not something this tool can fix.
    """
    url = "{}/storage/v1/object/authenticated/{}/{}".format(base, bucket, urllib.parse.quote(name, safe="/"))
    status, raw = request("GET", url, key, headers={"Range": "bytes=0-0"})
    if status in (200, 206):
        return "readable", ""

    text = raw.decode(errors="replace")
    if "NoSuchKey" in text:
        return "nosuchkey", text
    if status == 404:
        return "missing", text
    return "error", "{}: {}".format(status, text)


def relocate(base, key, name, strategy):
    """Phase 2: the Storage API moves the bytes and rewrites the row. Never SQL."""
    endpoint = "move" if strategy == "move" else "copy"
    status, raw = request(
        "POST",
        base + "/storage/v1/object/" + endpoint,
        key,
        {
            "bucketId": LEGACY_BUCKET,
            "sourceKey": name,
            "destinationBucket": BUCKET,
            "destinationKey": name,
        },
    )
    if status in (200, 201):
        return True, ""
    return False, "{} {} failed ({}): {}".format(endpoint, name, status, raw.decode(errors="replace"))


# --- ledger -----------------------------------------------------------------------------------

class Ledger:
    """Per-object progress, flushed after every transition so a kill -9 loses at most one step."""

    def __init__(self, path):
        self.path = path
        self.entries = {}
        if path.exists():
            self.entries = json.loads(path.read_text()).get("objects", {})

    def state(self, name):
        return self.entries.get(name, {}).get("state")

    def record(self, name, state, detail="", **extra):
        entry = self.entries.setdefault(name, {})
        entry["state"] = state
        entry["detail"] = detail
        entry["at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        entry.update(extra)
        self.flush()

    def names_in_state(self, state):
        return sorted(name for name, entry in self.entries.items() if entry.get("state") == state)

    def flush(self):
        payload = {"bucket": BUCKET, "legacy_bucket": LEGACY_BUCKET, "objects": self.entries}
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(payload, indent=2, sort_keys=True))
        temporary.replace(self.path)


# --- commands ---------------------------------------------------------------------------------

def command_scan(base, key, work_dir):
    """Read-only. Nothing here writes to the database or to storage."""
    objects = list_objects(base, key, BUCKET)
    if not objects:
        print(BUCKET + " is empty.")
        return 0

    broken, healthy, other = [], [], []
    for name in objects:
        state, detail = probe(base, key, BUCKET, name)
        if state == "readable":
            healthy.append(name)
        elif state == "nosuchkey":
            broken.append(name)
        else:
            other.append((name, state, detail))
        print("  {:<11} {}".format(state, name))

    report = {
        "scanned_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "bucket": BUCKET,
        "total": len(objects),
        "broken": broken,
        "healthy": healthy,
        "other": [{"name": n, "state": s, "detail": d} for n, s, d in other],
    }
    path = work_dir / "scan.json"
    path.write_text(json.dumps(report, indent=2))

    print("\n{} objects in {}".format(len(objects), BUCKET))
    print("  readable            {}".format(len(healthy)))
    print("  broken (NoSuchKey)  {}".format(len(broken)))
    print("  inconclusive        {}".format(len(other)))
    print("\nWrote " + str(path))
    if broken:
        print("Next: `snapshot`, then `repair` for a dry run.")
    return 0


def command_snapshot(base, key, work_dir, force):
    """Requirement 2: capture the rows before anything is modified. `version` is irreplaceable."""
    path = work_dir / "snapshot.json"
    if path.exists() and not force:
        print("{} already exists. Keep the original pre-repair snapshot; pass --force only if you\n"
              "are certain you want to overwrite it.".format(path), file=sys.stderr)
        return 1

    status, rows, error = rpc(base, key, "media_object_inventory")
    if rows is None:
        print("media_object_inventory failed ({}): {}\n"
              "Has 20260826090000 been pushed? A 404 here can also mean PostgREST has not reloaded\n"
              "its schema cache yet.".format(status, error), file=sys.stderr)
        return 1

    payload = {
        "captured_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "buckets": [BUCKET, LEGACY_BUCKET],
        "row_count": len(rows),
        "rows": rows,
    }
    path.write_text(json.dumps(payload, indent=2, sort_keys=True))

    counts = {}
    for row in rows:
        counts[row["bucket_id"]] = counts.get(row["bucket_id"], 0) + 1
    print("Snapshot of {} rows written to {}".format(len(rows), path))
    for bucket, count in sorted(counts.items()):
        print("  {:<20} {}".format(bucket, count))
    return 0


def repair_object(base, key, name, ledger, strategy, apply):
    """One object, resumable at any stage. Returns a short outcome tag."""
    if ledger.state(name) == VERIFIED:
        return "skipped"

    # Cheapest idempotence there is: if it reads, it is not broken, whatever the ledger thinks.
    state, detail = probe(base, key, BUCKET, name)
    if state == "readable":
        if apply:
            # Readable and previously mid-flight means this run's work landed; readable and never
            # touched means it was never broken. The distinction drives the final summary.
            touched = ledger.state(name) in (PARKED, RELOCATED)
            ledger.record(name, VERIFIED if touched else HEALTHY, "readable")
        return "repaired" if ledger.state(name) == VERIFIED else "healthy"
    if state not in ("nosuchkey", "missing"):
        if apply:
            ledger.record(name, FAILED, "probe: " + detail)
        return "failed"

    if not apply:
        return "would_repair"

    # --- phase 1: park ---
    if ledger.state(name) != PARKED:
        legacy_state, _ = probe(base, key, LEGACY_BUCKET, name)
        if legacy_state == "readable":
            # Parked by a previous run that died before it could write the ledger.
            ledger.record(name, PARKED, "already parked, adopted on resume")
        else:
            status, rows, error = rpc(base, key, "park_media_object", {"object_name": name})
            if rows is None and "already_parked" not in error:
                ledger.record(name, FAILED, "park: {} {}".format(status, error))
                return "failed"
            version = rows[0]["version"] if rows else None
            ledger.record(name, PARKED, "parked", version=version)

    # --- confirm the bytes are where we believe they are ---
    legacy_state, detail = probe(base, key, LEGACY_BUCKET, name)
    if legacy_state != "readable":
        # Not our failure mode: the payload is missing from both keys. Put the row back exactly
        # where it was and leave it for a human — this object is not recoverable from storage.
        status, rows, error = rpc(base, key, "unpark_media_object", {"object_name": name})
        note = "bytes unreachable in both buckets ({})".format(detail[:120])
        if rows is None:
            note += "; unpark also failed: {} {} — row is still parked".format(status, error)
        ledger.record(name, PARKED if rows is None else FAILED, note)
        return "failed"

    # --- phase 2: relocate through the Storage API ---
    if ledger.state(name) != RELOCATED:
        ok, error = relocate(base, key, name, strategy)
        if not ok:
            # Put the row back so a failed relocation does not leave the object hidden. If even
            # that fails it stays PARKED, which is what `rollback` looks for.
            status, rows, unpark_error = rpc(base, key, "unpark_media_object", {"object_name": name})
            if rows is not None:
                ledger.record(name, FAILED, error)
            else:
                ledger.record(name, PARKED, error + " | unpark failed: " + unpark_error)
            return "failed"
        ledger.record(name, RELOCATED, "relocated via " + strategy)

    # --- verify at the destination ---
    state, detail = probe(base, key, BUCKET, name)
    if state == "readable":
        ledger.record(name, VERIFIED, "readable in " + BUCKET)
        return "repaired"

    # Relocated but still unreadable. Deliberately not unparked: under `copy` the original row is
    # still on the legacy bucket and untouched, and under `move` there is nothing left to unpark.
    ledger.record(name, FAILED, "relocated but unreadable: " + detail)
    return "failed"


def command_repair(base, key, work_dir, apply, strategy, limit, only, sleep, max_failures):
    snapshot = work_dir / "snapshot.json"
    if not snapshot.exists():
        print("No snapshot at {}. Run `snapshot` first — the pre-repair rows, and `version` in\n"
              "particular, are the only map back to the bytes.".format(snapshot), file=sys.stderr)
        return 1

    objects = [only] if only else list_objects(base, key, BUCKET)
    if limit:
        objects = objects[:limit]

    ledger = Ledger(work_dir / "ledger.json")
    outcomes = {}
    failures = 0

    print("{} {} object(s), strategy={}\n".format("Repairing" if apply else "DRY RUN over", len(objects), strategy))
    for index, name in enumerate(objects, start=1):
        outcome = repair_object(base, key, name, ledger, strategy, apply)
        outcomes[outcome] = outcomes.get(outcome, 0) + 1
        print("  [{}/{}] {:<12} {}".format(index, len(objects), outcome, name))

        if outcome == "failed":
            failures += 1
            if failures >= max_failures:
                print("\nStopping after {} failures. Nothing further is attempted; already repaired\n"
                      "objects stay repaired and a re-run resumes where this left off.".format(failures),
                      file=sys.stderr)
                break
        if sleep:
            time.sleep(sleep)

    print()
    for outcome, count in sorted(outcomes.items()):
        print("  {:<14} {}".format(outcome, count))

    if not apply:
        print("\nDry run — nothing was parked, relocated or written. Re-run with --apply.")
        return 0

    parked = ledger.names_in_state(PARKED)
    if parked:
        print("\n{} object(s) are parked on {} and invisible to the app until they are\n"
              "relocated or rolled back:".format(len(parked), LEGACY_BUCKET), file=sys.stderr)
        for name in parked[:10]:
            print("  " + name, file=sys.stderr)
        print("Run `repair --apply` again to finish them, or `rollback --apply` to put them back.",
              file=sys.stderr)

    print()
    return command_verify(base, key, work_dir)


def command_rollback(base, key, work_dir, apply):
    """Undo an interrupted run: unpark every row this tool left on the legacy bucket.

    Strictly ledger-driven. Rows that reached RELOCATED or VERIFIED under `--strategy copy` are
    supposed to remain on storytopia-media as backups and are never touched here.
    """
    ledger = Ledger(work_dir / "ledger.json")
    parked = ledger.names_in_state(PARKED)
    if not parked:
        print("Nothing is parked. No rollback needed.")
        return 0

    print("{} parked object(s){}".format(len(parked), ":" if apply else " (dry run):"))
    if not apply:
        for name in parked:
            print("  would unpark  " + name)
        print("\nDry run. Re-run with --apply.")
        return 0

    failed = 0
    for name in parked:
        status, rows, error = rpc(base, key, "unpark_media_object", {"object_name": name})
        if rows is None:
            failed += 1
            ledger.record(name, FAILED, "unpark: {} {}".format(status, error))
            print("  FAILED   {}  ({} {})".format(name, status, error))
        else:
            ledger.record(name, HEALTHY, "unparked; still broken, as before the run")
            print("  unparked {}".format(name))

    print("\n{} unparked, {} failed.".format(len(parked) - failed, failed))
    print("These objects are back exactly as they were before the repair: listed in {}, and still\n"
          "unreadable. That is the pre-existing bug, not damage from the rollback.".format(BUCKET))
    return 1 if failed else 0


def command_verify(base, key, work_dir):
    """Requirement 8: the summary, recomputed from storage rather than from the ledger."""
    ledger = Ledger(work_dir / "ledger.json")
    scan = work_dir / "scan.json"
    broken_before = None
    if scan.exists():
        broken_before = len(json.loads(scan.read_text()).get("broken", []))

    objects = list_objects(base, key, BUCKET)
    readable, unreadable = [], []
    for name in objects:
        state, _ = probe(base, key, BUCKET, name)
        (readable if state == "readable" else unreadable).append(name)

    repaired = sum(1 for name in readable if ledger.state(name) in (VERIFIED, RELOCATED))
    already_healthy = sum(1 for name in readable if ledger.state(name) == HEALTHY or ledger.state(name) is None)

    print("Verification summary")
    print("  total scanned          {}".format(len(objects)))
    print("  broken before repair   {}".format("unknown (no scan.json)" if broken_before is None else broken_before))
    print("  successfully repaired  {}".format(repaired))
    print("  still unreadable       {}".format(len(unreadable)))
    print("  already healthy        {}".format(already_healthy))

    parked = ledger.names_in_state(PARKED)
    if parked:
        print("  parked (mid-flight)    {}   <- run `repair --apply` or `rollback --apply`".format(len(parked)))
    if unreadable:
        print("\nStill unreadable:")
        for name in unreadable[:10]:
            print("  " + name)
        if len(unreadable) > 10:
            print("  … and {} more".format(len(unreadable) - 10))
    return 1 if unreadable else 0


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("command", choices=["scan", "snapshot", "repair", "rollback", "verify"])
    parser.add_argument("--apply", action="store_true", help="perform changes (default is a dry run)")
    parser.add_argument("--strategy", choices=["copy", "move"], default="copy",
                        help="copy keeps the original in %s as a backup (default); move does not" % LEGACY_BUCKET)
    parser.add_argument("--work-dir", default="media-repair", help="where snapshot/ledger/scan live")
    parser.add_argument("--limit", type=int, default=0, help="only process the first N objects")
    parser.add_argument("--only", help="process exactly one object, by full path")
    parser.add_argument("--sleep", type=float, default=0.0, help="seconds between objects")
    parser.add_argument("--max-failures", type=int, default=3, help="stop after this many failures")
    parser.add_argument("--force", action="store_true", help="snapshot: overwrite an existing snapshot")
    args = parser.parse_args()

    base = (os.environ.get("SUPABASE_URL") or read_xcconfig("SUPABASE_URL") or "").rstrip("/")
    if not base:
        print("SUPABASE_URL not set and not found in Config/Supabase.xcconfig", file=sys.stderr)
        return 2

    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not key:
        print("SUPABASE_SERVICE_ROLE_KEY is required: the media bucket is private and the repair\n"
              "helpers are service-role only.", file=sys.stderr)
        return 2

    work_dir = Path(args.work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)

    if args.command == "scan":
        return command_scan(base, key, work_dir)
    if args.command == "snapshot":
        return command_snapshot(base, key, work_dir, args.force)
    if args.command == "repair":
        return command_repair(base, key, work_dir, args.apply, args.strategy,
                              args.limit, args.only, args.sleep, args.max_failures)
    if args.command == "rollback":
        return command_rollback(base, key, work_dir, args.apply)
    return command_verify(base, key, work_dir)


if __name__ == "__main__":
    sys.exit(main())
