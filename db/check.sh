#!/bin/bash
# Applies the schema to a throwaway Postgres and runs db/check.sql. Needs Docker.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=wispr-check
psql() { docker exec "$NAME" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=x postgres:16-alpine >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

for _ in $(seq 1 40); do
    docker exec "$NAME" pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 2
done

docker cp db "$NAME":/db >/dev/null
psql -f /db/schema.sql
psql -f /db/policies.sql
psql -f /db/check.sql

# auth.users only exists on Supabase; a stub still proves the FK and trigger.
docker exec "$NAME" createdb -U postgres supacheck
psql -d supacheck -f /db/schema.sql
psql -d supacheck -f /db/policies.sql
psql -d supacheck -c "create schema auth;
    create table auth.users (id uuid primary key, email text, raw_user_meta_data jsonb);"
psql -d supacheck -f /db/supabase.sql
psql -d supacheck -c "
insert into auth.users (id, email, raw_user_meta_data)
values ('55555555-5555-5555-5555-555555555555', 'new@example.com', '{\"display_name\":\"Newbie\"}');
do \$\$
begin
    assert (select display_name from public.users
            where id = '55555555-5555-5555-5555-555555555555') = 'Newbie',
        'signing up must create the profile row';
end \$\$;
delete from auth.users where id = '55555555-5555-5555-5555-555555555555';
do \$\$
begin
    assert not exists (select 1 from public.users),
        'deleting the auth user cascades the profile away';
end \$\$;"

echo "CHECK PASSED"
