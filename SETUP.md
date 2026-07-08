# SEC Survivor 2026 — Deployment Guide

## 1. Create the Supabase project
1. Go to supabase.com → New project. Note the **Project URL** and, under
   Settings → API, the **anon public key** and the **service_role key**
   (keep the service_role key secret — it's never used in the browser).
2. Open the SQL Editor → paste in the entire contents of `supabase/schema.sql`
   → Run. This creates every table, the opponent classification seed data,
   and all the RPC functions in one shot.

## 2. Create your commissioner account
1. In Supabase → Authentication → Users → Add user. Use your own email +
   a password. This is the *only* real login in the whole system — everyone
   else uses the token-link identity.
2. Copy that user's UUID (shown in the users table).
3. Back in the SQL Editor:
   ```sql
   insert into admins (user_id) values ('paste-your-uuid-here');
   ```
4. On the site, tap "Commissioner" at the bottom and sign in with that email
   and password to confirm it works.

## 3. Wire up the frontend
Open `index.html` and fill in the two placeholders near the top of the
`<script>` block:
```js
const SUPABASE_URL = 'https://YOUR-PROJECT.supabase.co';
const SUPABASE_ANON_KEY = 'YOUR-ANON-KEY';
```
The anon key is safe to ship in a public file — it only ever grants what the
RLS policies and RPC functions above allow, which is why all the actual
business logic lives in `schema.sql` rather than trusted client code.

## 4. Set up the GitHub repo
1. Push this whole folder to a new GitHub repo.
2. Repo → Settings → Secrets and variables → Actions → add two secrets:
   - `SUPABASE_URL` — same project URL as above
   - `SUPABASE_SERVICE_KEY` — the service_role key (NOT the anon key)
3. Repo → Settings → Pages → deploy from the `main` branch, root folder.
4. The workflow in `.github/workflows/update-scores.yml` will start running
   automatically on its schedule once merged. You can also trigger it by
   hand from the Actions tab (Run workflow → optionally type a week number)
   any time you want to force a refresh or backfill early weeks for testing.

## 5. Before the season — testing
Right now (7 weeks out), the `games` table is empty, so:
- Signup and "My Pick" will show no options until at least Week 1's games
  exist in the table.
- To test end-to-end today, manually trigger the GitHub Action once (Actions
  tab → Update SEC Survivor scores → Run workflow → week `1`) — this pulls
  the real Week 1 schedule (kickoff times included) even though the games
  haven't been played, letting you sign up and submit a real test pick.
- To remove a test pick/player entirely, either use the Commissioner panel's
  delete button, or just delete the row directly in Supabase's table editor
  — you have full access there regardless of what the app's UI exposes.

## 6. Season-start checklist
- [ ] Confirm the Week 1 games loaded correctly (Supabase table editor →
      `games`, filter week = 1) before announcing signup is open.
- [ ] Double check `week_deadline(1)` returns the Saturday you expect:
      run `select week_deadline(1);` in the SQL editor.
- [ ] Share the site URL with the group — no individual links needed, since
      signup is self-serve.
