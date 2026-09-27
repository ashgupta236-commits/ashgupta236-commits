# Token budget for cloud sessions

Why a session on this repository spends tokens fast, measured on 2026-09-27,
and what to change. Nothing here touches build parallelism or the Docker
hook, so `docs/cloud-environment.md` still applies unchanged.

## What was measured

Every request Claude makes re-reads the whole conversation context. The
context of the first request of a session, before any file was opened or
any command was run:

| Item | Tokens |
| --- | --- |
| Cached prefix read back | 40,236 |
| New prefix written to cache | 49,669 |
| The user's message itself | 29 |

So a session starts at roughly 90,000 tokens of fixed overhead, and every
later turn re-reads at least that much. By the ninth request the re-read
prefix was 96,479 tokens, and it only grows.

The repository contributes almost none of it. It has no `CLAUDE.md`, no
project skills, agents or commands, and the four tracked files total about
6 KB. The `SessionStart` hook writes to a log file, not to the context, so it
costs zero tokens per turn.

## Where the overhead comes from

The session had 21 MCP connectors attached, exposing 941 tools:

| Connector | Tools |
| --- | --- |
| Vercel | 243 |
| Ahrefs | 135 |
| higgsfield | 94 |
| github | 56 |
| Canva, Shopify, Figma, Lovable | 40 each |
| Sanity | 38 |
| Webflow | 34 |
| Gmail | 30 |
| Coupler.io | 25 |
| Claude Code Remote | 24 |
| Gamma | 20 |
| Slack | 19 |
| Zapier (attached twice) | 17 + 17 |
| Google Drive, Google Calendar, Claude Docs | 11, 9, 8 |

Each connector adds three things to every request: its tool names (about
11,000 tokens for the names alone), its server instructions (Figma, Shopify,
Sanity, Vercel, Coupler.io, Zapier, higgsfield and Lovable each ship several
paragraphs), and the schemas of any tool loaded during the session. Seven
more connectors were attached but not signed in, and two failed to connect;
each still adds a notice on every turn.

For this repository, the only connectors that do any work are GitHub and
Claude Code Remote. Everything else is paid for on every request and never
used.

## The fix

Connectors are an account setting, read once when a session starts. They
cannot be turned off from this repository.

1. Open https://claude.ai/customize/connectors.
2. Disconnect, or disable for Claude Code, every connector that a coding
   session on this repository does not need. Keep GitHub. Remove the
   duplicate Zapier entry.
3. Disconnect the seven connectors that sit in the "needs sign-in" state,
   or sign in to them if they are wanted. Half-connected is the worst case:
   the cost stays and the tools do nothing.
4. Start a new session to be sure. A disconnect can reach a session that is
   already open, mid-conversation, but a fresh session is the only way to
   confirm the new set actually took.

With only GitHub and Claude Code Remote attached, the fixed prefix drops by
an estimated 25,000 to 35,000 tokens per request, roughly a third of the
session baseline. Response quality and speed are unaffected, since none of
the removed tools were ever called.

## Recheck after connector cleanup (2026-09-27)

Measured directly: a brand new session's first turn, right after the user
disconnected most connectors from https://claude.ai/customize/connectors.

| Item | Before | After |
| --- | --- | --- |
| New prefix written to cache | 49,669 | 13,153 |
| Cached prefix read back | 40,236 | 38,451 |
| The user's message itself | 2 | 2 |
| **Total** | **~89,900** | **~51,600** |

That is a drop of about 38,000 tokens, roughly 43% of the original fixed
overhead per request.

### Connectors still attached

Cleanup was partial. As of this recheck, these connectors are still
connected and loaded into chat, beyond GitHub, Claude Code Remote and
Claude Docs:

| Connector | Tools (prior count, if measured) |
| --- | --- |
| Vercel | 243 |
| Ahrefs | 135 |
| higgsfield | 94 |
| Canva | 40 |
| Shopify | 40 |
| Figma | 40 |
| Gmail | 30 |
| Gamma | 20 |
| Google Drive | 11 |
| Google Calendar | 9 |
| Netlify | not previously measured; newly connected |
| 21st Dev Magic | installed and enabled, but its MCP server fails to connect (HTTP 404) |
| playwright | installed and enabled, but its MCP server fails to connect (HTTP 502) |

None of these are used by work on this repository. The last two are dead
weight twice over: they add tool names and a per-turn "failed to connect"
notice to every request, without ever answering a call.

The duplicate Zapier entry, Lovable, Sanity, Webflow, Coupler.io, Slack and
MotherDuck are now disconnected, as recommended. Several other connectors
sit in a "needs reconnect" or "connect incomplete" state (3DOptix, Notion,
Replit, Sentry, Stripe, Cloudinary, Airtable, Klaviyo, Nimble, Runway):
each of those still adds a notice to every turn until it is either
reconnected or removed outright, so the same disconnect-or-sign-in choice
from **The fix** above still applies to them.

## Keeping the repository lean

These habits keep the per-turn cost from creeping back:

- Do not add a `CLAUDE.md` unless a rule is needed on every turn. It is
  re-sent with every request, so keep it under a screen if it ever exists.
- Keep `docs/` for humans. Files there are only read when a task needs them.
- Hooks must write to files or exit silently. A hook that prints to stdout
  injects that text into the context on every firing.
- Do not add project-level MCP servers (`.mcp.json`) unless the tools are
  actually used here.
