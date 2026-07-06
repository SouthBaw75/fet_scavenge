# Go-Live Checklist

## Already done

- ✅ Supabase project `fet-scavenge` — schema applied, RLS verified end-to-end,
  Realtime enabled, answers/QR values unreachable from the browser
- ✅ Admin login created (see the person who set this up for credentials;
  rotate the password in Supabase Dashboard → Authentication → Users)
- ✅ Netlify project `fet-scavenger-hunt` created with
  `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` already set
- ✅ `netlify.toml` pins the Next.js runtime (Next 16 is supported natively)

## One remaining step: link the repo (≈2 minutes, one time)

1. Open https://app.netlify.com/projects/fet-scavenger-hunt
2. **Project configuration → Build & deploy → Continuous deployment →
   Link repository**
3. Choose GitHub → `SouthBaw75/fet_scavenge` → branch `main`
4. Accept the detected settings (build command `npm run build`) → Save

Every push to `main` now deploys automatically to
https://fet-scavenger-hunt.netlify.app

## Smoke test after first deploy

1. Visit `/admin/login` and sign in — confirms auth works
2. **Setup**: upload a small CSV (`full_name,department`), create a hunt,
   add one of each item type, set the hunt **Active**
3. On a phone: register a team, answer the items (scan a QR code generated
   from the item's exact QR value), finish
4. Watch `/admin/live` update in real time from another screen
5. Wipe test data: Supabase Dashboard → Table Editor → delete test hunt +
   teams (or ask Claude to do it)

## Event-day notes

- QR stops: generate printable QR codes from any QR generator — the encoded
  text must **exactly match** the item's "Value encoded in the physical QR
  code" field
- Only one hunt can be Active at a time (activating one closes others)
- A family that loses their page can reopen the site on the same phone —
  `/register` offers "Continue Your Hunt"
- Results export: `/admin/results` → Export CSV
