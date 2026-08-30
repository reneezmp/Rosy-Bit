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

Getting the colour required moving the menu bar item off `MenuBarExtra`. A menu
bar icon has to be a template image so macOS can tint and invert it, and a
template image is monochrome — anything coloured inside a `MenuBarExtra` label
is flattened with the rest. Osaurus's answer is to leave the image a template
and add the dot as a sibling `NSView` on the status bar button, where its layer
keeps its own colour; `MenuBarExtra` never exposes its `NSStatusItem`, so the
menu is built with `NSMenu` in `StatusItemController` instead.

---

## 2. Settings window — done

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
- **Show the memory arithmetic.** `contextSize` × 112 KiB per token is the
  number that actually matters, and it is not obvious from a token count. The
  window should update it as the values change. Whether slots multiply it is
  unverified — do not state a figure that has not been measured.
- Changing anything requires restarting the server; the window should say so
  and offer to do it rather than leaving the user to guess.

---

## 3. Insights — done (proxy route)

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

## 4. First-run model download — done

The model lives outside the bundle so it can be swapped without rebuilding,
which left a fresh install needing `fetch-model.sh` by hand — the only script
an app *user*, as opposed to someone building or validating, had to touch.

`ModelDownloader` mirrors that script: ask the Hugging Face API which files
exist rather than guessing the filename, then verify before moving into place.
Verification is the GGUF magic bytes as well as the HTTP status, so a 404 page
or a truncated transfer fails with a clear message instead of becoming a
confusing llama-server crash later.

One manual step remains on a fresh install and it is not ours to remove: an
ad-hoc signed app still needs `xattr -dr com.apple.quarantine`. That needs a
Developer ID and notarisation.

---

## 5. Ask bar — done

⌥Space opens a Spotlight-shaped panel, streams an answer, dismisses on click
away. `GlobalHotKey` uses Carbon's `RegisterEventHotKey` rather than
`NSEvent.addGlobalMonitorForEvents`, which would need Accessibility permission,
or the popular third-party package, which would be this project's first
dependency.

---

## 6. Chat window — next

The remaining item. `ChatClient` already exists and is proven by the ask bar, so
this is mostly UI: `NavigationSplitView` gives the collapsible sidebar on
macOS 13, and a system prompt is already a stored setting.

**The open question is history storage.** Insights is memory-only by deliberate
choice, because it holds meeting transcripts. Chat history written to disk would
quietly contradict that — conversations would outlive the app. Decide that
before building it, not after.

Worth knowing before judging the speed: llama-server caches the KV of the
previous prompt per slot and reuses the longest common prefix. A conversation is
exactly that shape, so turn N only processes the new message rather than the
whole history — provided nothing else hits the server in between and evicts it.

---

## Order

Five of six have landed; the chat window is the one left. 3b (the proxy) was
taken directly rather than shipping 3a first, because the Prompt, Request and
Response tabs are the point and only the proxy can supply them.

**None of items 3 to 5 has ever run.** They were written without a compiler
while the machines that can build them were unavailable. `docs/TESTING.md` is
the list, ordered so an early failure explains the later ones.
