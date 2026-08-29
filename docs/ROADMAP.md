# Roadmap

Rosy Bit does its job: an always-on OpenAI-compatible endpoint on Rosy, proven
against MacWhisper on real transcripts. These are the things that would make it
pleasant rather than merely working.

---

## 1. Inference indicator — done

A green dot beside the sakura while llama-server has a request in flight, and
`◐ Working — N requests` on the menu's status line.

It costs nothing to run. `ServerLogScanner` already reads llama-server's output
on its way to the log file, and that output announces both `launch_slot_ …
processing task` and `release: … stop processing`. Counting those is free, so
the indicator holds to the same rule as everything else here: **no timers, no
polling, nothing that wakes a fanless machine on a schedule.**

One thing to watch when it runs: `MenuBarExtra` may render its whole label as a
template image, which would flatten the green to monochrome. The dot is drawn
as a solid disc rather than a tint on the flower precisely so that it still
reads as an indicator if that happens — the shape carries the meaning and the
colour is a bonus. If it does come out grey, the fix is a second template asset
rather than fighting AppKit.

---

## 2. Settings window

The mechanism already exists as `defaults` keys: `contextSize`, `threads`,
`parallelSlots`, `kvCacheType`, `temperature`, `corsOrigins`, `port`. What is
missing is somewhere to see and change them.

A `Settings { }` scene coexists with `LSUIElement` — it opens a window on
demand without giving the app a Dock icon or a main window.

Design notes:

- **Temperature must be labelled a fallback, not a setting.** An
  OpenAI-compatible client that sends its own `temperature` overrides the
  server's, and most do. A slider that silently does nothing for MacWhisper
  would be worse than no slider.
- **Show the memory arithmetic.** `contextSize` × `parallelSlots` × 112 KiB per
  token is the number that actually matters, and it is not obvious. The window
  should say "8192 × 1 slot ≈ 0.9 GiB" as the values change.
- Changing anything requires restarting the server; the window should say so
  and offer to do it rather than leaving the user to guess.

---

## 3. Insights

The one that changes the architecture. Modelled on Osaurus's Insights pane: a
list of requests, and per request a Prompt view (system/user turns laid out),
the raw Request JSON, the Response, and Params (model, tokens in → out, tok/s,
finish reason, status, duration).

**Prompt, Request and Response all need the message bodies, and Rosy Bit cannot
see them.** Osaurus can because Osaurus *is* the server. We supervise someone
else's binary and never touch its traffic. Only the Params tab could be
reconstructed from the log, which already carries token counts and timings.

So there are two versions, and they are not the same project:

### 3a. Log-derived (cheap, no risk)

Parse what `ServerLogScanner` already sees: timestamps, prompt and generated
token counts, tok/s, durations. Roughly the Params tab and the request list.
**No prompts, no responses.** Nothing in the request path changes, so this
cannot break the endpoint.

### 3b. Reverse proxy (the real thing)

Move llama-server to a private port and have Rosy Bit take 1337, forwarding
each request and recording both sides. Full fidelity — everything in the
screenshots.

The costs, stated plainly:

- **It puts the app in the hot path.** Today Rosy Bit is a supervisor: if it
  crashes, llama-server carries on serving. As a proxy, an app bug becomes an
  outage.
- **Streaming must be forwarded, not buffered.** Clients send `"stream": true`
  and expect Server-Sent Events to arrive incrementally. Buffer them by
  accident and every response appears to hang until it is complete — which, at
  2 tok/s on a long generation, looks exactly like a crash.
- Token counts have to be parsed out of the final SSE chunk rather than read
  from the log.

### What to carry over from Osaurus

Worth stealing outright, from `Packages/OsaurusCore/Managers/InsightsService.swift`:

- **A ring buffer, in memory, never written to disk** (Osaurus keeps 500).
  This matters more here than there: Rosy goes to the courthouse, and an
  Insights buffer would be holding meeting transcripts. Memory-only plus a
  Clear button means quitting the app is enough to erase them.
- **Redact credentials from every body before storing it**, as defence in
  depth, rather than trusting each call site to have scrubbed its own.
- **Truncate large bodies but report the original size**, so a clipped prompt
  is obviously clipped.
- **Debounce the filter pipeline.** Osaurus's own comment records that
  recomputing filters inside the view body was a measurable problem under
  load; they settled on 200 ms.

---

## Order

1 → 2 → 3a → decide on 3b.

3b is the only item that can break something that currently works, so it should
sit on a stable base and be the one thing changing when it lands.
