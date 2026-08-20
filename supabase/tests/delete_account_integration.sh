#!/usr/bin/env bash
#
# End-to-end test for the `delete-account` Edge Function, against the local Supabase stack.
#
# The pgTAP suite (account_deletion_test.sql) covers what the *database* guarantees: that the
# cascades really cascade, and that the storage enumeration cannot see across accounts. This covers
# the half that pgTAP structurally cannot reach — the function itself: that it refuses an
# unauthenticated caller, that it takes the account from the JWT rather than from anything the caller
# says, that real bytes leave real buckets, and that a second call after a partial run converges
# instead of failing.
#
# Usage:
#     supabase start
#     supabase functions serve --no-verify-jwt &     # the function's own 401 is what we test
#     supabase/tests/delete_account_integration.sh
#
# `--no-verify-jwt` deliberately removes the platform's gate so the request reaches the function and
# its own authentication runs. In production both are in force; this asserts the inner one.

set -uo pipefail

API="${SUPABASE_API_URL:-http://127.0.0.1:54321}"
DB_CONTAINER="${SUPABASE_DB_CONTAINER:-supabase_db_Journaltopia}"
ANON="${SUPABASE_ANON_KEY:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0}"
SRK="${SUPABASE_SERVICE_ROLE_KEY:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU}"

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
nope() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()   { [ "$2" = "$3" ] && ok "$1" || nope "$1" "$3" "$2"; }

sql() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -tAq -c "$1"; }

# --- fixtures ---------------------------------------------------------------------------------

create_user() {   # email password -> uid
    curl -s -X POST "$API/auth/v1/admin/users" \
        -H "Authorization: Bearer $SRK" -H "apikey: $SRK" -H "Content-Type: application/json" \
        -d "{\"email\":\"$1\",\"password\":\"$2\",\"email_confirm\":true}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))'
}

token_for() {     # email password -> access_token
    curl -s -X POST "$API/auth/v1/token?grant_type=password" \
        -H "apikey: $ANON" -H "Content-Type: application/json" \
        -d "{\"email\":\"$1\",\"password\":\"$2\"}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))'
}

upload() {        # bucket path token
    printf 'test-bytes' | curl -s -o /dev/null -w '%{http_code}' -X POST \
        "$API/storage/v1/object/$1/$2" \
        -H "Authorization: Bearer $3" -H "apikey: $ANON" \
        -H "Content-Type: image/jpeg" --data-binary @-
}

object_count() {  # uid -> number of storage objects owned by that uid, by path
    sql "select count(*) from storage.objects
         where bucket_id in ('journaltopia-media','generated-storyboards','journal-covers')
           and path_tokens[1] = '$1';"
}

delete_account() { # token -> http status
    curl -s -o /tmp/delete_account_body.json -w '%{http_code}' -X POST \
        "$API/functions/v1/delete-account" \
        -H "Authorization: Bearer $1" -H "apikey: $ANON" -H "Content-Type: application/json"
}

STAMP="$(date +%s)$$"
A_EMAIL="delete-a-$STAMP@example.com"
B_EMAIL="delete-b-$STAMP@example.com"
PW="throwaway-password-123"

echo "== fixtures =="
A_UID="$(create_user "$A_EMAIL" "$PW")"
B_UID="$(create_user "$B_EMAIL" "$PW")"
[ -n "$A_UID" ] && [ -n "$B_UID" ] || { echo "could not create users (is the stack up?)"; exit 1; }
A_TOKEN="$(token_for "$A_EMAIL" "$PW")"
B_TOKEN="$(token_for "$B_EMAIL" "$PW")"
[ -n "$A_TOKEN" ] && [ -n "$B_TOKEN" ] || { echo "could not sign in"; exit 1; }
echo "  A=$A_UID"
echo "  B=$B_UID"

# Signup seeds starter content, so both accounts already have journals and entries.
is "a new account arrives with starter journals" "$( [ "$(sql "select count(*) from public.journals where user_id='$A_UID';")" -gt 0 ] && echo yes || echo no )" "yes"

# Real uploads, through the same policies the app uploads under: each account can only write its own
# prefix, which is what makes `<uid>/` ownership true rather than merely conventional.
upload journaltopia-media    "$A_UID/entries/e1/photo.jpg" "$A_TOKEN" >/dev/null
upload generated-storyboards "$A_UID/sb/page-1.jpg"        "$A_TOKEN" >/dev/null
upload journal-covers        "$A_UID/cover.jpg"            "$A_TOKEN" >/dev/null
upload journaltopia-media    "$B_UID/entries/e9/photo.jpg" "$B_TOKEN" >/dev/null

is "the account has 3 uploaded objects"       "$(object_count "$A_UID")" "3"
is "the other account has 1 uploaded object"  "$(object_count "$B_UID")" "1"

# A user cannot write into another user's prefix in the first place.
is "a user cannot upload into another user's folder" "$(upload journaltopia-media "$B_UID/stolen.jpg" "$A_TOKEN")" "400"

echo "== authorization =="
is "no Authorization header is refused"    "$(delete_account "")"             "401"
is "a garbage bearer token is refused"     "$(delete_account "not-a-jwt")"    "401"
is "the anon key is not a user session"    "$(delete_account "$ANON")"        "401"

# The function reads no body, so there is no user_id field to forge. The closest a caller can come is
# sending one, which changes nothing: B's session deletes B, never A.
FORGED=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/functions/v1/delete-account" \
    -H "Authorization: Bearer $B_TOKEN" -H "apikey: $ANON" -H "Content-Type: application/json" \
    -d "{\"user_id\":\"$A_UID\"}")
is "a forged user_id in the body is ignored (call succeeds as B)" "$FORGED" "200"
is "...and the named account is untouched"  "$(sql "select count(*) from auth.users where id='$A_UID';")" "1"
is "...while the caller's own account is gone" "$(sql "select count(*) from auth.users where id='$B_UID';")" "0"
is "...and the caller's storage went with it" "$(object_count "$B_UID")" "0"

echo "== deleting an account with content =="
# A third account, so the retry case gets a clean subject.
C_EMAIL="delete-c-$STAMP@example.com"
C_UID="$(create_user "$C_EMAIL" "$PW")"
C_TOKEN="$(token_for "$C_EMAIL" "$PW")"
upload journaltopia-media    "$C_UID/entries/e1/photo.jpg" "$C_TOKEN" >/dev/null
upload generated-storyboards "$C_UID/sb/page-1.jpg"        "$C_TOKEN" >/dev/null

# Half the storage removed behind the function's back, standing in for an attempt that died midway.
curl -s -o /dev/null -X DELETE "$API/storage/v1/object/journaltopia-media" \
    -H "Authorization: Bearer $SRK" -H "Content-Type: application/json" \
    -d "{\"prefixes\":[\"$C_UID/entries/e1/photo.jpg\"]}"
is "one object was already gone before the call" "$(object_count "$C_UID")" "1"

is "deleting an account that is already half-swept succeeds" "$(delete_account "$C_TOKEN")" "200"
is "...and the remaining objects are gone"     "$(object_count "$C_UID")" "0"
is "...and the auth user is gone"              "$(sql "select count(*) from auth.users where id='$C_UID';")" "0"

echo "== cascades =="
is "profiles removed"          "$(sql "select count(*) from public.profiles where id='$C_UID';")" "0"
is "entries removed"           "$(sql "select count(*) from public.entries where user_id='$C_UID';")" "0"
is "journals removed"          "$(sql "select count(*) from public.journals where user_id='$C_UID';")" "0"
is "journal_entries removed"   "$(sql "select count(*) from public.journal_entries where user_id='$C_UID';")" "0"

echo "== the untouched account =="
is "account A still exists"        "$(sql "select count(*) from auth.users where id='$A_UID';")" "1"
is "account A keeps its storage"   "$(object_count "$A_UID")" "3"
is "account A keeps its journals"  "$( [ "$(sql "select count(*) from public.journals where user_id='$A_UID';")" -gt 0 ] && echo yes || echo no )" "yes"

echo "== retrying a completed deletion =="
# The session's user no longer exists, so the JWT no longer identifies anybody. A 401 is the correct
# and safe answer: there is nothing left to delete, and the app treats it as signed-out.
is "retrying with the deleted account's token is refused" "$(delete_account "$C_TOKEN")" "401"

echo "== Sign in with Apple =="
# An account with an Apple identity, built the way GoTrue builds one. Real Apple revocation cannot be
# exercised locally — it needs Apple's servers, a real authorization code and the team's private key —
# but the part that carries the compliance risk is testable here and is what these assert: that an
# Apple-linked account is never deleted without a revocation having succeeded first.
D_EMAIL="delete-d-$STAMP@example.com"
D_UID="$(create_user "$D_EMAIL" "$PW")"
D_TOKEN="$(token_for "$D_EMAIL" "$PW")"
APPLE_SUB="000123.abcdef$STAMP.1234"

sql "insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
     values ('$APPLE_SUB', '$D_UID', jsonb_build_object('sub','$APPLE_SUB','email','$D_EMAIL'), 'apple', now(), now(), now());" >/dev/null

upload journaltopia-media "$D_UID/entries/e1/photo.jpg" "$D_TOKEN" >/dev/null
is "the Apple-linked account has an apple identity" \
   "$(sql "select count(*) from auth.identities where user_id='$D_UID' and provider='apple';")" "1"

# No code in the body: the server must refuse before it deletes anything.
APPLE_NO_CODE=$(delete_account "$D_TOKEN")
is "an Apple account is refused without a fresh authorization code" "$APPLE_NO_CODE" "400"
is "...with a code the app can act on" \
   "$(python3 -c 'import json;print(json.load(open("/tmp/delete_account_body.json")).get("code",""))')" \
   "apple_reauthorization_required"
is "...and the account still exists"      "$(sql "select count(*) from auth.users where id='$D_UID';")" "1"
is "...and its storage is untouched"      "$(object_count "$D_UID")" "1"
is "...and its journals are untouched"    "$( [ "$(sql "select count(*) from public.journals where user_id='$D_UID';")" -gt 0 ] && echo yes || echo no )" "yes"

# A code that Apple will never accept. Whatever the failure is, the account must survive it: revocation
# runs before storage and before the auth user, so a refusal costs nothing.
APPLE_BAD=$(curl -s -o /tmp/delete_account_body.json -w '%{http_code}' -X POST \
    "$API/functions/v1/delete-account" \
    -H "Authorization: Bearer $D_TOKEN" -H "apikey: $ANON" -H "Content-Type: application/json" \
    -d '{"appleAuthorizationCode":"not-a-real-apple-code"}')
is "a code Apple refuses does not delete the account" \
   "$( [ "$APPLE_BAD" -ge 400 ] && echo refused || echo "$APPLE_BAD" )" "refused"
is "...the account survives an Apple failure"  "$(sql "select count(*) from auth.users where id='$D_UID';")" "1"
is "...its storage survives an Apple failure"  "$(object_count "$D_UID")" "1"
is "...and the failure names Apple"            \
   "$(python3 -c 'import json;c=json.load(open("/tmp/delete_account_body.json")).get("code","");print("apple" if c.startswith("apple_") else c)')" \
   "apple"

# The other side of the same coin: an account with no Apple identity never goes near Apple, and
# deletes with an empty body exactly as before. (Accounts A/B/C above are all email-only and did.)
is "an email-only account has no apple identity" \
   "$(sql "select count(*) from auth.identities where user_id='$A_UID' and provider='apple';")" "0"

echo "== cleanup =="
curl -s -o /dev/null -X DELETE "$API/auth/v1/admin/users/$A_UID" -H "Authorization: Bearer $SRK" -H "apikey: $SRK"
curl -s -o /dev/null -X DELETE "$API/auth/v1/admin/users/$D_UID" -H "Authorization: Bearer $SRK" -H "apikey: $SRK"
for b in journaltopia-media; do
    curl -s -o /dev/null -X DELETE "$API/storage/v1/object/$b" -H "Authorization: Bearer $SRK" \
        -H "Content-Type: application/json" -d "{\"prefixes\":[\"$D_UID/entries/e1/photo.jpg\"]}"
done
for b in journaltopia-media generated-storyboards journal-covers; do
    curl -s -o /dev/null -X DELETE "$API/storage/v1/object/$b" -H "Authorization: Bearer $SRK" \
        -H "Content-Type: application/json" \
        -d "{\"prefixes\":[\"$A_UID/entries/e1/photo.jpg\",\"$A_UID/sb/page-1.jpg\",\"$A_UID/cover.jpg\"]}"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
