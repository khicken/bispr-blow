#!/usr/bin/env bash
# E2E of BisprBlow team + sync flows against a LOCAL Supabase stack. Usage: e2e/run.sh
# Mirrors CloudClient.swift / SyncEngine.swift HTTP calls. Never touches a remote project.
set -uo pipefail
cd "$(dirname "$0")"
DB_DIR="$(cd .. && pwd)/db"
API=http://127.0.0.1:58321
DBC=supabase_db_bispr-e2e   # psql runs inside the container, never via a host port
FAILS=0

cleanup() { echo "-- stopping stack"; supabase stop --no-backup >/dev/null 2>&1; }
trap cleanup EXIT

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; echo "      body: ${2:-}"; FAILS=$((FAILS+1)); }
# check "name" "<jq -e filter>" "<json>"
check() { if jq -e "$2" <<<"$3" >/dev/null 2>&1; then pass "$1"; else fail "$1" "$3"; fi; }

echo "-- starting local stack (first run pulls images)"
supabase stop --no-backup >/dev/null 2>&1
supabase start -x realtime,storage-api,imgproxy,mailpit,studio,edge-runtime,logflare,vector,supavisor,postgres-meta >/tmp/bispr-e2e-start.log 2>&1 \
  || { echo "supabase start failed:"; tail -20 /tmp/bispr-e2e-start.log; exit 2; }
ANON=$(supabase status -o env 2>/dev/null | sed -n 's/^ANON_KEY="\(.*\)"/\1/p')
[ -n "$ANON" ] || { echo "no anon key"; exit 2; }

echo "-- applying db/schema.sql, policies.sql, supabase.sql"
for f in schema policies supabase; do
  sed -E 's/^create function /create or replace function /; s/^create trigger /create or replace trigger /' "$DB_DIR/$f.sql" \
    | docker exec -i "$DBC" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q -f - >/tmp/bispr-e2e-$f.log 2>&1 \
    || { echo "apply $f.sql failed:"; tail -10 /tmp/bispr-e2e-$f.log; exit 2; }
done
# PostgREST caches the schema; reload it.
docker exec "$DBC" psql -U postgres -d postgres -q -c "notify pgrst, 'reload schema'" >/dev/null
sleep 2

# --- helpers: same headers as CloudClient.auth / rest
auth() { curl -s "$API/auth/v1/$1" -H "apikey: $ANON" -H 'Content-Type: application/json' -d "$2"; }
# rest METHOD PATH TOKEN [json] [prefer]  (path may include ?query). Prints body then "\n<status>".
rest() {
  local args=(-s -w '\n%{http_code}' -X "$1" "$API/rest/v1/$2" -H "apikey: $ANON" -H "Authorization: Bearer $3")
  [ -n "${4:-}" ] && args+=(-H 'Content-Type: application/json' -d "$4")
  [ -n "${5:-}" ] && args+=(-H "Prefer: $5")
  curl "${args[@]}"
}
body() { sed '$d' <<<"$1"; }
code() { tail -n1 <<<"$1"; }

PW='Passw0rd-e2e!'

bootstrap() {
RUN=$RANDOM
EMAIL_A="a$RUN@e2e.test"; EMAIL_B="b$RUN@e2e.test"; EMAIL_C="c$RUN@e2e.test"

echo "== 1. sign up / sign in, profile rows"
for u in A B C; do
  eval "email=\$EMAIL_$u"
  su=$(auth signup "{\"email\":\"$email\",\"password\":\"$PW\"}")
  si=$(curl -s "$API/auth/v1/token?grant_type=password" -H "apikey: $ANON" -H 'Content-Type: application/json' -d "{\"email\":\"$email\",\"password\":\"$PW\"}")
  eval "TOK_$u=\$(jq -r .access_token <<<\"\$si\")"
  eval "REF_$u=\$(jq -r .refresh_token <<<\"\$si\")"
  eval "UID_$u=\$(jq -r .user.id <<<\"\$si\")"
  eval "tok=\$TOK_$u; id=\$UID_$u"
  check "user $u signed in with password" '.access_token and .refresh_token' "$si"
  r=$(rest GET "users?select=id,email" "$tok"); check "user $u has public.users row" ".[0].id == \"$id\" and .[0].email == \"$email\"" "$(body "$r")"
done

echo "== 2. refresh token"
rf=$(curl -s "$API/auth/v1/token?grant_type=refresh_token" -H "apikey: $ANON" -H 'Content-Type: application/json' -d "{\"refresh_token\":\"$REF_A\"}")
check "refresh_token grant returns new tokens" '.access_token and .refresh_token' "$rf"
NEW=$(jq -r .access_token <<<"$rf"); [ "$NEW" != null ] && TOK_A=$NEW

echo "== 3. create_org"
r=$(rest POST rpc/create_org "$TOK_A" '{"name":"E2E Team"}'); ORG=$(body "$r" | jq -r . 2>/dev/null)
check "A create_org returns uuid" 'test("^[0-9a-f-]{36}$")' "$(body "$r")"
r=$(rest GET "org_members?user_id=eq.$UID_A&select=role,orgs(id,name)&order=joined_at.asc&limit=1" "$TOK_A")
check "A sees org via org_members (refreshOrg query) as owner" ".[0].role==\"owner\" and .[0].orgs.id==\"$ORG\" and .[0].orgs.name==\"E2E Team\"" "$(body "$r")"

echo "== 4. invite + accept"
INVCODE=$(LC_ALL=C tr -dc '23456789ABCDEFGHJKMNPQRSTUVWXYZ' </dev/urandom | head -c 8)
EXP=$(date -u -v+14d '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null || date -u -d '+14 days' '+%Y-%m-%dT%H:%M:%S.000Z')
r=$(rest POST invites "$TOK_A" "[{\"org_id\":\"$ORG\",\"email\":\"$EMAIL_B\",\"code\":\"$INVCODE\",\"invited_by\":\"$UID_A\",\"expires_at\":\"$EXP\"}]" "return=minimal")
[[ "$(code "$r")" == 201 ]] && pass "A createInvite (201)" || fail "A createInvite" "$(code "$r") $(body "$r")"
r=$(rest POST rpc/accept_invite "$TOK_B" "{\"invite_code\":\"bad$INVCODE\"}")
check "bad code -> readable message" '.message=="invite code is not valid"' "$(body "$r")"
r=$(rest POST rpc/accept_invite "$TOK_C" "{\"invite_code\":\"$INVCODE\"}")
check "wrong-address user C rejected readably" '.message|test("different address")' "$(body "$r")"
r=$(rest POST rpc/accept_invite "$TOK_B" "{\"invite_code\":\"$INVCODE\"}")
check "B accept_invite returns org id" ". == \"$ORG\"" "$(body "$r")"
r=$(rest GET "org_members?org_id=eq.$ORG&select=user_id,display_name,role&order=joined_at.asc" "$TOK_B")
check "B sees both members, B is member" "length==2 and (map(select(.user_id==\"$UID_B\"))[0].role==\"member\")" "$(body "$r")"
r=$(rest GET "org_members?user_id=eq.$UID_B&select=role,orgs(id,name)&limit=1" "$TOK_B")
check "B refreshOrg sees org" ".[0].orgs.id==\"$ORG\"" "$(body "$r")"

}

sync_suite() {
echo "== 5. sync + leaderboard + text privacy"
NOW=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
mkrow() { # id user org words
  echo "{\"id\":\"$1\",\"user_id\":\"$2\",\"created_at\":\"$NOW\",\"word_count\":$4,\"duration_seconds\":30.5,\"app_name\":\"Notes\",\"bundle_id\":\"com.apple.Notes\",\"provider\":\"local\",\"org_id\":\"$3\"}"; }
DA=$(uuidgen | tr A-Z a-z); DB=$(uuidgen | tr A-Z a-z)
P="resolution=merge-duplicates,return=minimal"
r=$(rest POST dictations "$TOK_A" "[$(mkrow $DA $UID_A $ORG 100)]" "$P"); [[ "$(code "$r")" == 201 ]] && pass "A upsert dictations" || fail "A upsert dictations" "$(code "$r") $(body "$r")"
r=$(rest POST dictations "$TOK_B" "[$(mkrow $DB $UID_B $ORG 50)]" "$P"); [[ "$(code "$r")" == 201 ]] && pass "B upsert dictations" || fail "B upsert dictations" "$(code "$r") $(body "$r")"
r=$(rest POST dictations "$TOK_A" "[$(mkrow $DA $UID_A $ORG 120)]" "$P"); [[ "$(code "$r")" =~ ^20[014]$ ]] && pass "A re-upsert (merge-duplicates) idempotent" || fail "A re-upsert" "$(code "$r") $(body "$r")"
r=$(rest GET "leaderboard?org_id=eq.$ORG&period=eq.week&select=user_id,display_name,words,wpm,day_streak&order=words.desc" "$TOK_B")
check "leaderboard shows both (A=120, B=50)" "length==2 and .[0].user_id==\"$UID_A\" and .[0].words==120 and .[1].words==50" "$(body "$r")"
r=$(rest POST dictation_texts "$TOK_A" "[{\"dictation_id\":\"$DA\",\"raw\":\"secret raw\",\"cleaned\":\"secret cleaned\"}]" "$P")
[[ "$(code "$r")" == 201 ]] && pass "A upsert dictation_texts" || fail "A upsert dictation_texts" "$(code "$r") $(body "$r")"
r=$(rest GET "dictation_texts?select=*" "$TOK_A"); check "A reads own text" 'length==1' "$(body "$r")"
r=$(rest GET "dictation_texts?select=*" "$TOK_B"); check "B cannot read A text" '.==[]' "$(body "$r")"
r=$(rest GET "dictations?select=id" "$TOK_B"); check "B sees only own dictations rows" "length==1 and .[0].id==\"$DB\"" "$(body "$r")"
r=$(rest POST dictations "$TOK_B" "[$(mkrow $(uuidgen | tr A-Z a-z) $UID_A $ORG 5)]" "$P")
[[ "$(code "$r")" =~ ^4 ]] && pass "B cannot insert row as A" || fail "B insert as A allowed" "$(code "$r") $(body "$r")"

echo "== 6. outsider C sees nothing"
r=$(rest GET "orgs?select=id" "$TOK_C"); check "C sees no orgs" '.==[]' "$(body "$r")"
r=$(rest GET "org_members?org_id=eq.$ORG&select=user_id" "$TOK_C"); check "C sees no members" '.==[]' "$(body "$r")"
r=$(rest GET "dictations?select=id" "$TOK_C"); check "C sees no dictations" '.==[]' "$(body "$r")"
r=$(rest GET "leaderboard?org_id=eq.$ORG&period=eq.all&select=user_id" "$TOK_C"); check "C sees no leaderboard rows" '.==[]' "$(body "$r")"
r=$(rest GET "dictation_texts?select=*" "$TOK_C"); check "C sees no texts" '.==[]' "$(body "$r")"
r=$(rest GET "member_days?select=*" "$TOK_C"); [[ "$(code "$r")" =~ ^4 ]] && pass "member_days not readable" || fail "member_days readable" "$(code "$r") $(body "$r")"
r=$(rest GET "leaderboard?select=user_id" "$TOK_C"); check "C unfiltered leaderboard empty" '.==[]' "$(body "$r")"
r=$(curl -s -w '\n%{http_code}' "$API/rest/v1/dictations?select=id" -H "apikey: $ANON"); [[ "$(code "$r")" =~ ^(401|403)$ ]] && pass "anon key alone denied" || fail "anon key alone" "$(code "$r") $(body "$r")"

}

features_suite() {
echo "== 7. rename team, roster emails, shared dictionaries"
r=$(rest PATCH "orgs?id=eq.$ORG" "$TOK_B" '{"name":"Hijacked"}' "return=representation")
check "B (member) rename touches no row" '.==[]' "$(body "$r")"
r=$(rest PATCH "orgs?id=eq.$ORG" "$TOK_A" '{"name":"   "}')
[[ "$(code "$r")" =~ ^4 ]] && pass "A blank rename rejected" || fail "A blank rename" "$(code "$r") $(body "$r")"
r=$(rest PATCH "orgs?id=eq.$ORG" "$TOK_A" '{"name":"Renamed Team"}' "return=representation")
check "A (owner) rename works" '.[0].name=="Renamed Team"' "$(body "$r")"
r=$(rest GET "orgs?id=eq.$ORG&select=name" "$TOK_B"); check "B sees new name" '.[0].name=="Renamed Team"' "$(body "$r")"

r=$(rest GET "org_members?org_id=eq.$ORG&select=user_id,display_name,role,joined_at,users(email,display_name)" "$TOK_B")
check "B roster embed has emails of A and B" "length==2 and (map(select(.user_id==\"$UID_A\"))[0].users.email==\"$EMAIL_A\") and (map(select(.user_id==\"$UID_B\"))[0].users.email==\"$EMAIL_B\")" "$(body "$r")"
r=$(rest GET "users?select=email" "$TOK_C"); check "C (outsider) sees only own email" "length==1 and .[0].email==\"$EMAIL_C\"" "$(body "$r")"
r=$(rest GET "org_members?org_id=eq.$ORG&select=user_id,users(email)" "$TOK_C"); check "C roster embed empty" '.==[]' "$(body "$r")"

r=$(rest POST dictionary_words "$TOK_A" "[{\"user_id\":\"$UID_A\",\"word\":\"Zebra\"},{\"user_id\":\"$UID_A\",\"word\":\"Apple\"},{\"user_id\":\"$UID_A\",\"word\":\"Mango\"}]" "resolution=merge-duplicates,return=minimal")
[[ "$(code "$r")" == 201 ]] && pass "A upsert words" || fail "A upsert words" "$(code "$r") $(body "$r")"
r=$(rest POST dictionary_words "$TOK_A" "[{\"user_id\":\"$UID_A\",\"word\":\"Apple\"}]" "resolution=merge-duplicates,return=minimal")
[[ "$(code "$r")" =~ ^20[014]$ ]] && pass "A re-upsert word idempotent" || fail "A re-upsert word" "$(code "$r") $(body "$r")"
r=$(rest GET "dictionary_words?user_id=eq.$UID_A&select=word&order=word.asc" "$TOK_B")
check "B reads A's words sorted" '. == [{"word":"Apple"},{"word":"Mango"},{"word":"Zebra"}]' "$(body "$r")"
r=$(rest GET "dictionary_words?user_id=eq.$UID_A&select=word&order=word.asc" "$TOK_C"); check "C gets no words of A" '.==[]' "$(body "$r")"
r=$(rest POST dictionary_words "$TOK_B" "[{\"user_id\":\"$UID_A\",\"word\":\"Planted\"}]" "resolution=merge-duplicates,return=minimal")
[[ "$(code "$r")" =~ ^4 ]] && pass "B cannot write A's words" || fail "B wrote A's words" "$(code "$r") $(body "$r")"
r=$(rest DELETE "dictionary_words?user_id=eq.$UID_A&word=in.(Apple)" "$TOK_B" "" "return=representation")
check "B delete of A's word removes nothing" '.==[]' "$(body "$r")"
r=$(rest POST dictionary_words "$TOK_A" "[{\"user_id\":\"$UID_A\",\"word\":\"   \"}]" "resolution=merge-duplicates,return=minimal")
[[ "$(code "$r")" =~ ^4 ]] && pass "blank word rejected" || fail "blank word accepted" "$(code "$r") $(body "$r")"
r=$(rest DELETE "dictionary_words?user_id=eq.$UID_A&word=in.(Apple,Zebra)" "$TOK_A")
[[ "$(code "$r")" =~ ^20[04]$ ]] && pass "A deletes own words" || fail "A delete words" "$(code "$r") $(body "$r")"
r=$(rest GET "dictionary_words?user_id=eq.$UID_A&select=word&order=word.asc" "$TOK_B"); check "B sees remaining word only" '. == [{"word":"Mango"}]' "$(body "$r")"
r=$(curl -s -w '\n%{http_code}' "$API/rest/v1/dictionary_words?select=word" -H "apikey: $ANON"); [[ "$(code "$r")" =~ ^(401|403)$ ]] && pass "anon cannot read words" || fail "anon read words" "$(code "$r") $(body "$r")"
}

bootstrap
sync_suite
features_suite

echo
echo "################ migration on top of the OLD schema (HEAD) ################"
# Rebuild public the way live looks: HEAD's schema/policies/supabase, applied once.
# Supabase default privileges (all to anon/authenticated on new objects) are
# restored so the revokes in policies.sql matter, as they do live.
HEAD_DIR=$(mktemp -d)
git -C "$DB_DIR/.." show HEAD:db/schema.sql | sed '/^-- `users.id` IS `auth.users.id`/,$d' >"$HEAD_DIR/schema.sql"
git -C "$DB_DIR/.." show HEAD:db/policies.sql >"$HEAD_DIR/policies.sql"
git -C "$DB_DIR/.." show HEAD:db/supabase.sql >"$HEAD_DIR/supabase.sql"
psqlc() { docker exec -i "$DBC" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q "$@"; }
psqlc -c "drop schema public cascade; create schema public;
  grant usage on schema public to anon, authenticated, service_role;
  alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
  alter default privileges in schema public grant all on functions to anon, authenticated, service_role;" >/dev/null \
  || { echo "reset public failed"; exit 2; }
for f in schema policies supabase; do
  sed -E 's/^create function /create or replace function /; s/^create trigger /create or replace trigger /' "$HEAD_DIR/$f.sql" \
    | psqlc -f - >/tmp/bispr-e2e-old-$f.log 2>&1 || { echo "apply old $f.sql failed:"; tail -10 /tmp/bispr-e2e-old-$f.log; exit 2; }
done
# What the Security Advisor "fix" did to live.
psqlc -c "alter view leaderboard set (security_invoker = on);" >/dev/null
psqlc -c "notify pgrst, 'reload schema'" >/dev/null; sleep 2

bootstrap
r=$(rest GET "leaderboard?org_id=eq.$ORG&period=eq.week" "$TOK_B")
check "OLD+invoker: leaderboard reproduces 'permission denied for view member_days'" '.message|test("permission denied for view member_days")' "$(body "$r")"
r=$(rest PATCH "orgs?id=eq.$ORG" "$TOK_A" '{"name":"Renamed Team"}' "return=representation")
check "OLD: orgs update policy already let the owner rename" '.[0].name=="Renamed Team"' "$(body "$r")"
r=$(rest GET "dictionary_words?select=word" "$TOK_A"); [[ "$(code "$r")" =~ ^4 ]] && pass "OLD: dictionary_words absent" || fail "OLD: dictionary_words exists" "$(body "$r")"

for i in 1 2; do
  docker exec -i "$DBC" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q -f - <"$DB_DIR/migrations/20261120_team_features.sql" >/tmp/bispr-e2e-migration-$i.log 2>&1 \
    && pass "migration run $i applied" || { fail "migration run $i" "$(tail -5 /tmp/bispr-e2e-migration-$i.log)"; break; }
done
sleep 2

sync_suite
features_suite

echo
[ $FAILS -eq 0 ] && echo "ALL GREEN" || echo "$FAILS FAILED"
exit $((FAILS>0))
