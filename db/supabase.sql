-- Supabase-only glue. Everything else in db/ is portable Postgres; this is the
-- part that ties our users table to Supabase's auth.users.
-- Apply after db/schema.sql and db/policies.sql:
--   psql "$WISPR_DATABASE_URL" -f db/supabase.sql

-- A user row is an auth user. Same id, so current_user_id() lines up with
-- auth.uid() everywhere, and deleting the account takes the data with it.
alter table users alter column id drop default;
alter table users add constraint users_auth_fk
    foreign key (id) references auth.users (id) on delete cascade;

create function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
    insert into public.users (id, email, display_name)
    values (new.id, new.email, new.raw_user_meta_data ->> 'display_name')
    on conflict (id) do nothing;
    return new;
end $$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function handle_new_user();
