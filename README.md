# Thyme

A voice-guided sous-chef for cooking several dishes at once. Enter your dishes and serve time; Thyme plans backward, interleaves steps for one cook, and talks you through it ("Okay, Thyme, let's begin").

Static site: no build step, no server. Open `index.html`, or host the repo root on GitHub Pages.

- Built-in recipes and rule-based cleanup of pasted steps work with no AI.
- Optional: users add their own Anthropic API key in Settings for dish lookup and free-form questions. The key stays in the browser's localStorage and is sent only to api.anthropic.com. Thyme ships with no key.
- Installable as a PWA (manifest + service worker).
- Voice input uses the browser's Web Speech API (Chrome, Edge; limited in Safari/Firefox).

## Paste any recipe
Paste recipe text on the Menu → Add dish. Thyme parses steps, ingredients, times and temperatures on your device (no AI key), shows an editable preview, then saves. If you added your own Anthropic key, an optional AI cleanup is offered.

## Together (shared events)
Host shares a menu; helpers join by link or code and take steps; progress syncs live. Needs a free Supabase project: see [SETUP_SUPABASE.md](SETUP_SUPABASE.md). Schema and access rules: `supabase/schema.sql`.
