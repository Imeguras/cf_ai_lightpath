---
name: cloudflare-assignment
description: "~/cloudflarescreen is João's Cloudflare SRE Core (Lisbon) fast-track AI app; prompt history lives in ai-history/, redacted for public posting"
metadata:
  node_type: memory
  type: project
  originSessionId: b728a42c-339c-4a46-8e7e-0dd178f18ad2
  modified: 2026-11-02T11:10:41.063Z
---

This directory is for the optional fast-track assignment on Cloudflare's Systems Reliability Engineer – Core application (Lisbon/London, greenhouse job 8324908). It requires an AI app on Cloudflare with an LLM (Llama 3.3 on Workers AI recommended), workflow/coordination, chat or voice input, memory/state, and a submitted prompt history. The plan is to stay on the free Workers plan (10k Neurons/day, where going over errors and doesn't bill).

The conversation history goes in `PROMPTS.md` at the repo root (one section per session). `ai-history/memories/` holds redacted copies of the loaded instructions and memories. Both are published with the repo. Created 2026-11-02.

**Why:** the repo and its prompt history will be public on GitHub and read by Cloudflare recruiters.
**How to apply:** anything written to ai-history/ or the repo must leave out anything about the CV or other projects, other job applications, salary figures, third-party names, former-employer internals and home location. Redact with `[REDACTED: reason]`.
