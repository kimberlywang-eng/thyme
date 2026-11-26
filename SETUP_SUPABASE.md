# Turning on shared events ("Together") with Supabase

Shared events let a host and helpers cook one menu from separate phones. Everyone
joins by link or code, no accounts. It needs a free Supabase project. About 5 minutes.

1. Go to https://supabase.com and sign up (free, no card needed).
2. Click **New project**. Name it `thyme`, pick any region near you, create a database
   password (you will not need it again), and click **Create**. Wait until it says the project is ready.
3. In the left menu open **SQL Editor** → **New query**. Open `supabase/schema.sql`
   from this repo, copy everything, paste it in, and click **Run**. It should say "Success".
4. In the left menu open **Project Settings** → **API**. Copy two values:
   - **Project URL** (looks like `https://abcdxyz.supabase.co`)
   - **anon public** key (a long string starting `eyJ`)
5. Put them in `config.js` (or send them to Claude to do it):
   ```js
   window.THYME_CONFIG = { supabaseUrl: "https://....supabase.co", supabaseAnonKey: "eyJ..." };
   ```
   Commit and push; the Together tab switches on.

**Never share or use the `service_role` key.** The anon key is meant to be public;
the schema locks all tables and exposes only checked functions.

Notes: free projects pause after about a week of no use (open the Supabase dashboard
and click Restore). Events delete themselves after 14 days.
