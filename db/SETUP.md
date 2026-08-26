# Supabase project setup

Project `qprsavobltijpuhwqrhw`. Four things, all in the dashboard, none of them in code. The app
is finished and none of this is a code change — but sign-in cannot work until all four are done.

## 1. The schema

Run, in this order, in the SQL editor:

    db/schema.sql
    db/policies.sql
    db/supabase.sql

`db/check.sh` applies all three to a throwaway Postgres in Docker and asserts the result, including
a stubbed `auth.users` so the FK and the signup trigger are exercised. Run it before touching any
of them.

`supabase.sql` is the Supabase-only glue: it ties `public.users.id` to `auth.users.id` so
`auth.uid()` lines up with `current_user_id()` in every policy, and adds the trigger that creates a
profile row on signup. Without it every policy keyed on `auth.uid()` matches no row, so a signed-in
user sees an empty app — and the app's `refreshOrg()` queries tables that are not there.

## 2. The email template — this is what makes the code arrive

Authentication → Emails → **Magic Link**.

The stock template body is `{{ .ConfirmationURL }}` and nothing else, which is why an untouched
project sends a *link* and never a code, and why that link points at `http://localhost:3000` — the
default Site URL. There is no code in the email because the default template never asks for one.

`CloudClient.requestCode` calls `/auth/v1/otp` and `signIn` posts the six digits back to
`/auth/v1/verify`, so the template has to render the token:

    <h2>Your BisprBlow sign-in code</h2>
    <p style="font-size:28px;letter-spacing:4px"><strong>{{ .Token }}</strong></p>
    <p>It expires in an hour. If you didn't ask for it, ignore this.</p>

Both templates come off the same endpoint, so `{{ .Token }}` is the whole fix. Leave
`{{ .ConfirmationURL }}` out entirely: a desktop app has no website to land on, and a link that
opens localhost is worse than no link.

## 3. Google

- Google Cloud Console → OAuth client (Web application) → authorized redirect URI:
  `https://qprsavobltijpuhwqrhw.supabase.co/auth/v1/callback`
- Authentication → Providers → Google → paste the client ID and secret, enable.

Until this is on, `/auth/v1/settings` reports `"google": false` and `authorize` answers
`Unsupported provider: provider is not enabled`. `CloudClient.checkProviderEnabled` asks first and
surfaces that wording, rather than opening a browser onto a page of raw JSON.

## 4. Redirect allow-list

Authentication → URL Configuration → Redirect URLs → add:

    bisprblow://auth-callback

Miss this and Google itself succeeds while Supabase refuses the hand-back. The scheme is declared
in `Info.plist` under `CFBundleURLTypes` and read from `CloudConfig.callbackScheme`; change one and
you change all three.

## Checking it from the outside

    K=<publishable key>; U=https://qprsavobltijpuhwqrhw.supabase.co
    curl -s -H "apikey: $K" "$U/auth/v1/settings"   # which providers are actually on

Requesting an OTP sends a real email, so do it against an address you can read.
