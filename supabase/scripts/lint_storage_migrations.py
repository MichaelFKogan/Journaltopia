#!/usr/bin/env python3
"""Fail on SQL that tries to move a Storage object by rewriting its metadata row.

Why this exists
---------------
`storage.objects` is the index over an object store, not a table of paths. The bytes live under a
key derived from `bucket_id/name/version`. Rewriting `name` or `bucket_id` in SQL moves the row and
leaves the payload where it was, so the object still lists — correct size, correct mime type — and
every read 404s with NoSuchKey. It looks like a permissions problem and is not one.

This has happened twice in this project, both times in the same migration:

    20260819000000  update storage.objects set bucket_id = 'journaltopia-media' ...   (86 objects)
    20260819000000  update storage.objects set name = regexp_replace(...) ...         (35 objects)

The second was found and walked back within hours by 20260822090000. The first went unnoticed for
ten days and took every reference photo, entry thumbnail and character portrait in the app with it.
Nothing in the tooling objected either time, because nothing was looking.

Moving or renaming a Storage object has to go through the Storage API, which copies the bytes to the
new key before it rewrites the row:

    POST /storage/v1/object/move    {bucketId, sourceKey, destinationBucket, destinationKey}
    POST /storage/v1/object/copy    {bucketId, sourceKey, destinationBucket, destinationKey}

There is no SQL equivalent and there is no way to add one. A migration that needs objects moved has
to hand that half to a script — supabase/scripts/repair_media_bucket_paths.py is the worked example.

What this does and does not catch
---------------------------------
It reads the migration text, so it catches the mistake where it was made: in a file, at review time,
before it reaches a database. It cannot catch the same statement typed into the dashboard SQL editor
— that is what the note in Config and the prose in these migrations are for.

Comments are stripped before matching, so migrations that quote the bad statement while explaining
it — 20260822090000 does, at length — do not trip the check.

Usage
-----
    python3 supabase/scripts/lint_storage_migrations.py

Exit 0 clean, 1 on a violation. No arguments, no credentials, no network: it only reads files.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

SQL_ROOT = Path(__file__).resolve().parents[1]

# The two statements that caused the outage, and the walk-back that repaired half of it. They are
# applied history: editing them would change what a fresh `db reset` builds and would not un-run
# them anywhere. They are grandfathered by name so that everything written from here on is checked.
GRANDFATHERED = {
    "20260819000000_rename_storytopia_contracts_to_journaltopia.sql",
    "20260822090000_restore_sample_storage_object_names.sql",
}

# pgTAP tests run against a local stack that is reset between runs and has no object store behind
# it, so a fixture row with no payload is the point rather than the hazard — account_deletion_test
# builds them deliberately to check *which* rows the enumeration picks. Nothing here can reach a
# real bucket.
EXEMPT_DIRECTORIES = {"tests"}

# `update storage.objects ... set ... name/bucket_id ...`, across newlines, schema optional.
FORBIDDEN = re.compile(
    r"update\s+(?:storage\s*\.\s*)?objects\b[^;]*?\bset\b[^;]*?\b(name|bucket_id)\s*=",
    re.IGNORECASE | re.DOTALL,
)
# Writing rows straight into the index is the same class of mistake from the other direction: a row
# with no payload behind it.
FORBIDDEN_INSERT = re.compile(
    r"insert\s+into\s+storage\s*\.\s*objects\b",
    re.IGNORECASE,
)

COMMENT_LINE = re.compile(r"--[^\n]*")
COMMENT_BLOCK = re.compile(r"/\*.*?\*/", re.DOTALL)
DOLLAR_QUOTED = re.compile(r"\$\$.*?\$\$", re.DOTALL)


def strip_noise(sql: str) -> str:
    """Comments out, and dollar-quoted function bodies blanked.

    Function bodies are excluded because a `security definer` helper that parks one row is the
    supported escape hatch — 20260826090000 was exactly that, reviewed and dropped when it was done.
    The thing worth catching is a bare statement in a migration, which is how this went wrong twice.
    Newlines are preserved so reported line numbers stay honest.
    """
    def blank(match: re.Match) -> str:
        return re.sub(r"[^\n]", " ", match.group(0))

    sql = COMMENT_BLOCK.sub(blank, sql)
    sql = COMMENT_LINE.sub(blank, sql)
    return DOLLAR_QUOTED.sub(blank, sql)


def line_of(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def main() -> int:
    files = sorted(SQL_ROOT.rglob("*.sql"))
    if not files:
        print("No SQL found under {}".format(SQL_ROOT), file=sys.stderr)
        return 1

    violations = []
    checked = 0
    for path in files:
        if path.name in GRANDFATHERED:
            continue
        if EXEMPT_DIRECTORIES.intersection(part for part in path.relative_to(SQL_ROOT).parts[:-1]):
            continue
        checked += 1

        text = strip_noise(path.read_text())
        for pattern, description in (
            (FORBIDDEN, "rewrites storage.objects.name or .bucket_id"),
            (FORBIDDEN_INSERT, "inserts directly into storage.objects"),
        ):
            for match in pattern.finditer(text):
                violations.append((path, line_of(text, match.start()), description,
                                   " ".join(match.group(0).split())[:100]))

    print("Checked {} SQL file(s) under {}".format(checked, SQL_ROOT))

    if not violations:
        print("No direct Storage metadata rewrites. Clean.")
        return 0

    print("\n{} violation(s):\n".format(len(violations)), file=sys.stderr)
    for path, line, description, excerpt in violations:
        print("  {}:{}".format(path.relative_to(SQL_ROOT.parent), line), file=sys.stderr)
        print("    {}".format(description), file=sys.stderr)
        print("    {}…".format(excerpt), file=sys.stderr)
        print(file=sys.stderr)
    print("Moving a Storage object means copying its bytes to the new key. Only the Storage API\n"
          "does that; SQL rewrites the row and orphans the payload. See the docstring in\n"
          "supabase/scripts/repair_media_bucket_paths.py for what that costs to undo.",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
