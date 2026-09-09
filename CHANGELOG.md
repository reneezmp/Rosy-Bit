# Changelog

Rosy Bit follows semantic versioning from the first public baseline. This file
records user-visible changes; the detailed engineering history remains in Git.

## Unreleased

- Registered cloud providers now appear as checkable choices under
  **Model → Cloud Models**. Switching back from a local GGUF no longer requires
  reopening the provider window; configuration remains a separate menu action.
- Added **Model → Import from Hugging Face…**. Rosy accepts repository IDs,
  repository URLs, and direct GGUF links; lists every GGUF file before download;
  validates the finished file; then selects it and restarts the local server.
  Standard Transformers repositories are identified clearly instead of being
  mistaken for llama.cpp-ready models.

### Added

- **Skills → Tool Routing** now offers mutually exclusive **Guided** and
  **Model-led** modes. Guided preserves deterministic Bonsai fast paths;
  Model-led exposes validated action schemas for capable local/cloud models and
  explicitly enables tool calling for otherwise-unmeasured local models.
- Model-led volume, timer, Apps/Finder, and Reminders actions reuse Rosy's
  native allowlists and bounds and require no extra confirmation exchange.
- Model-led routing can now chain tool calls within one answer instead of
  stopping after the first — search the web, then read the most promising
  result, for example. The loop streams, executes whatever the model asked
  for, appends the result, and streams again until the model answers or the
  budget runs out. Guided routing is unchanged and still uses exactly one
  tool call, whatever the setting says; that is the shape Bonsai 1.7B Q1_0
  was measured on, and a 1-bit model chaining tools unsupervised is not
  something this project has evidence for.
- Added **Settings → Tool Calls → "Limit per answer"**, a stepper from 1 to
  8 with a default of 3, backed by the `maxToolCalls` default. It lives in
  Settings rather than the Skills menu because it governs cost and patience
  rather than consent — which capabilities exist at all stays a menu-bar
  decision. Every extra call is another full generation on this fanless
  two-core Mac and, with Web Search enabled, possibly another billed Kagi
  request; Settings states this plainly.
- One assistant message can now carry several tool calls at once; Rosy
  previously refused these outright. All the calls in a message share one
  assistant turn and count against the same budget, and each still gets its
  own validated execution and its own reply.
- A call that would exceed the remaining budget is not run, but it still
  appears in the replayed transcript with a `tool` reply saying it was not
  run and why: an OpenAI-shaped history where a `tool_calls` entry has no
  matching `tool` reply is malformed, and providers reject it. Executed
  calls replay the arguments Rosy validated; refused calls were never
  validated, so their arguments are echoed back capped at 2,000 characters.
- Once the budget is spent, the next request is sent with
  `tool_choice: "none"`. A runtime that ignores this and asks for a tool
  anyway is refused with a new `toolCallLimitIgnored` error rather than
  allowed to keep spending.
- A new **Skills** submenu below **Model** independently toggles Dictionary,
  Volume Control, Calculator & Units, Timers, and Battery & System for Rosy's
  own local and cloud conversations. Choices persist across relaunches and
  default to enabled.
- Disabled skills disappear from the request schema and cannot execute through
  deterministic or model-routed paths. When all are disabled, Rosy omits the
  complete `tools` and `tool_choice` segment; local prefix warming immediately
  refills the new schema-free prefix.
- Calculator & Units evaluates bounded arithmetic, percentages, and common
  length, mass, volume, time, data, and temperature conversions in native code.
  Its parser accepts the whole expression or rejects it; it cannot execute
  scripts or arbitrary code.
- Battery & System reads battery charge, charging state, current power source,
  startup-disk capacity, and installed memory from native macOS APIs only when
  requested—never through background polling.
- Exact timer commands create named local notifications, list active Rosy
  timers, or cancel one/all without a model round-trip. Minimal timer metadata
  persists so notifications and cancellation survive relaunches; the model can
  only call the read-only list operation.
- Apps & Finder adds exact one-line app launch/quit, standard-folder opening,
  Finder reveal, and read-only installed-app lookup.
- File Search provides bounded read-only Spotlight results without invoking a
  shell, and Reminders uses EventKit for native list/create/complete/delete
  operations with one-time macOS permission.
- **Model → Cloud Model…** now opens a compact provider window for either
  DeepSeek or a custom OpenAI-compatible HTTPS endpoint. A saved cloud profile
  can be selected without deleting the installed local model, and choosing a
  local model switches inference home again.
- Cloud API credentials are stored in macOS Keychain rather than preferences,
  logs, Insights, or request payloads. Custom providers may intentionally be
  configured without a key when their endpoint does not require one.
- Cloud requests preserve Rosy's system/user message order, stream answers and
  metrics through the existing chat interface, and retain the bounded native
  dictionary and volume tools. DeepSeek requests use canonical JSON and
  explicitly disable thinking mode, avoiding its special requirement to replay
  private `reasoning_content` throughout tool-call history.
- Added a ninth skill, **Web Search (Kagi)**, the only one that defaults to
  off and the only one whose capability leaves the machine—every other skill
  reads something already on this Mac. Two tools appear once a key is saved:
  `web_search` (Kagi Search) and `web_fetch` (Kagi Extract, which returns a
  page as Markdown), built against Kagi's current v1 API rather than the
  Summarizer, FastGPT, and Enrichment endpoints Kagi's own MCP server has
  already withdrawn.
- The Kagi API token lives in its own Keychain entry, separate from the
  cloud-inference credential, so forgetting one can never silently disarm the
  other; it never reaches UserDefaults, Insights, or a log. Settings gains a
  **Web Search** section with the token field, results per search (1–10,
  default 5), how much extracted page text is kept (500–12,000 characters,
  default 2,400), and the honest cost: roughly $12 per thousand searches and
  $4 per thousand pages read.
- Deterministic routing recognises plainly authored requests such as “search
  the web for X” and “summarise https://…”, ordered ahead of File Search so
  an explicit web request is never answered from the Spotlight index instead.
  It is deliberately narrower than the other routers, because a wrong guess
  here spends money, and unlike the fully local skills it still runs a
  grounded second pass, because a search result is evidence to weigh rather
  than an answer to repeat.
- Search and page results are fenced between explicit BEGIN/END UNTRUSTED WEB
  CONTENT markers with a preamble stating the text was written by strangers
  and that any instruction inside it belongs to the document, not the user.
  Rosy still has no shell or filesystem write and stays inside the same
  per-answer tool-call limit as everything else, so a hostile page's blast
  radius stays a visible wrong answer; results are displayed to the user
  with their links intact, beside the model's answer, the same principle
  already used for dictionary entries.

### Fixed

- Credentials are read from the Keychain once per launch instead of on every
  Skills-menu open, every request, and every prefix warm. On a rebuilt ad-hoc
  signed app, whose code identity changes each time, those repeated reads each
  raised a fresh authorisation question — and a stream of questions leaves
  stale password dialogs on screen that accept no typing, because nothing is
  listening behind them.
- Saving an API key now replaces the stored Keychain item rather than updating
  it in place. `SecItemUpdate` must open the existing item, which needs a
  permission a rebuilt binary no longer holds; deleting and re-adding needs
  none and leaves the item owned by the binary actually running. Applied to
  both the Kagi token and the cloud-provider key, which shared the fault.

- Explicit searches for files **named** or **called** something now constrain
  Spotlight to filesystem names instead of returning documents whose contents
  merely mention the search term.
- Direct cloud requests now appear in memory-only Insights with their ordered
  prompt, redacted request body, streamed answer or tool call, provider status,
  token usage, duration, and the same chat-message correlation used by
  **Inspect response**. They previously bypassed the loopback recording proxy
  and disappeared from Insights entirely.
- Installing or warming a local model can no longer take inference back from a
  cloud profile that the user explicitly selected.
- Removed the leftover SwiftUI `Settings { EmptyView() }` scene, kept as a
  placeholder until a real settings window existed. That window was later
  built in AppKit instead, and the placeholder was never removed, so Rosy Bit
  opened **two windows both titled "Rosy Bit Settings,"** one of them
  permanently blank, plus a ⌘, that opened the blank one. The entry point is
  now a plain AppKit `main.swift`, with no SwiftUI App lifecycle left at all.
  That scene had also been quietly supplying the app's **Edit menu** — an
  `LSUIElement` app still needs one, because NSApplication dispatches key
  equivalents to the key window, which is the only reason ⌘X/⌘C/⌘V/⌘A worked
  inside a text field. Losing it silently would have made the DeepSeek and
  Kagi key fields impossible to paste into. `AppDelegate` now builds that menu
  by hand, and ⌘, opens the real settings window.
- Kagi's matched-term highlighting inside search snippets (`<b>`, `<strong>`)
  no longer reaches the user as literal angle brackets or the model as HTML
  noise competing with the words it needs to read. Titles, snippets, and
  extracted page text now pass through a tag-stripping and entity-decoding
  step; `&amp;` is decoded last so an escaped escape cannot become a working
  tag.
- Replaying a tool-calling turn no longer discards the model's own words. The
  assistant message used to be rebuilt with `content: null`, throwing away
  prose the model had already streamed to the user — "let me look that up" —
  so on a chained second round the model was shown its own previous turn as
  empty. Its words are now replayed; `content` falls back to null only when
  there genuinely were none.
- A retrieved block — a dictionary entry, search results — no longer runs
  straight into streamed prose that preceded it, which used to leave the
  block's first Markdown heading stuck mid-line instead of starting its own —
  "…for you. 💙### Web search: …". A blank line is now inserted whenever
  prose came first.
- DeepSeek's V4 models intermittently emit their internal tool-call markup —
  `<｜DSML｜>` wrapping `invoke`/`parameter` tags — as ordinary assistant
  content instead of a structured `tool_calls` field, with
  `finish_reason: "stop"` and nothing left to execute. This is an open,
  undocumented fault on DeepSeek's own hosted API — DSML appears nowhere in
  DeepSeek's own API documentation and is known only from community
  reverse-engineering — reported at roughly one turn in ten, and it is not
  caused by anything in Rosy's own request. Rosy now recognises the markup
  mid-stream, stops relaying it, and shows a short notice explaining that the
  call was not run, that this is a known DeepSeek fault rather than a bad
  request, and that asking again usually works. The complete reply still
  reaches Insights, so nothing is hidden from someone trying to diagnose it.
  Rosy deliberately does not parse the leaked markup back into an executable
  call: turning free-form text into an action is exactly what this project's
  guardrail against arbitrary execution forbids, and it would be worse here
  than usual, because tool results carry untrusted web content — a page that
  talked the model into echoing this shape would become an action Rosy
  performed rather than a wrong sentence.

## [1.1.0] — 2026-08-31

### Added

- The cached prefix is now prefilled when the server becomes ready, instead of
  being charged to whoever asks the first question. A question then prefills
  only its own words — 15 tokens rather than 203 in measurement. If one is
  submitted while that is still running it waits for it, which costs nothing:
  the prefill had to happen either way. The ask bar shows an unobtrusive
  "Preparing context…" while it runs and stays typeable throughout.
- The Ask bar can now ground word questions in the dictionaries already enabled
  on the Mac. The retrieved entry is shown verbatim in a visually distinct code
  block before Rosy’s short gloss; it is never replaced by model prose. The tool
  is local, read-only, limited to one call per turn, and enabled only for the
  measured Bonsai 1.7B Q1_0 build.
- Explicit definition phrasings such as “define X” and “what does X mean?” now
  route directly to Dictionary Services instead of asking the model whether it
  feels like calling the tool. Ambiguous and multi-line requests remain with
  normal model routing, avoiding both missed lookups and pasted-text triggers.
- Rosy can now report the Mac’s current output volume through a validated,
  read-only `volume_get` tool backed by Core Audio.
- Exact one-line commands can set volume from 0–100 or mute/unmute immediately,
  without a confirmation round-trip or model inference. Rosy Bit parses the
  value from the user’s own text and executes it natively; state-changing
  schemas are never exposed to the model. Vague requests get a local prompt
  for an exact level; out-of-range, decimal, and multi-line requests cannot
  mutate the Mac.
- Oversized dictionary articles are shortened locally before they reach the
  model, with the reduction disclosed beside the source excerpt. This keeps a
  bilingual mega-entry from consuming Rosy’s context window and both CPU cores.
- A memory-only chat window now supports multiple sessions, a collapsible
  conversation sidebar, streamed multi-turn replies, Markdown, cancellation,
  new and deleted sessions, and a visible reminder that history clears on quit.
- Full sessions remain visible while model context is bounded to the newest
  complete turns that fit. Long chats therefore do not make every later reply
  feed the entire transcript back through Rosy’s two cores.
- Completed Ask bar turns can move into a new chat session through **Continue
  in Chat**, beside Copy, without asking the model to regenerate either message.
- The chat window now uses an integrated native title bar and sidebar,
  date-grouped session rows, open-canvas assistant answers, compact right-aligned
  user capsules, per-answer Copy controls, and a floating composer with Rosy’s
  restrained sakura accent. Its 900×650 opening size remains compact enough to
  resize for the 12-inch display rather than inheriting a modern-screen void.
- Recent conversation prefixes can now survive slot reuse in a bounded,
  memory-only prompt cache. Rosy defaults to a 256 MB ceiling and 256-token
  checkpoints instead of llama-server's 8 GB / 8,192-token server defaults;
  both controls are visible in Performance settings and clear on quit.
- Chat messages now carry Osaurus-inspired native controls without copying its
  interface wholesale. User actions (Copy, Edit, Delete, More) appear on hover;
  assistant actions (Copy, Regenerate, More) remain visible beside measured
  TTFT, generation speed, and output-token totals. More shows the timestamp and
  opens the exact memory-only Insights request for that response.
- Editing or deleting an earlier question trims the dependent branch rather
  than leaving answers attached to words that no longer exist. Editing then
  regenerates from the corrected turn; deleting asks before removing it.
- Large chat windows now let the conversation rail grow beyond its original
  720-point opening-width cap, up to a readable 960-point ceiling.
- User-turn timestamps now use Foundation's native short time-zone notation
  (`GMT-3` for São Paulo) instead of the hand-selected `BRT` abbreviation.

### Fixed

- Flattened Dictionary Services articles now regain readable structure in the
  source block: headword and pronunciation, numbered and bullet senses,
  indented examples, later parts of speech, and origin/derivative sections each
  receive appropriate line breaks. Formatting changes whitespace only and
  never rewrites the authoritative entry.
- Dictionary code blocks now wrap to the available Ask bar or chat width instead
  of becoming one indefinitely scrolling line.
- Long dictionary code blocks now stop at 180 points and scroll internally, so
  the authoritative source cannot push Rosy’s gloss out of the visible answer.
  Compact entries keep their natural height.
- Text inside user-message capsules is right-aligned as well as the capsule
  itself, so multi-line turns retain the intended conversational geometry.
- User-message capsules now hug short messages and grow only until their
  wrapping maximum, instead of rendering every turn at the maximum width.
- **New Chat** now shares the sidebar's top row with its collapse control, and
  collapsed mode lets the transcript and composer reclaim the released width.
  Its compact controls now align with the assistant/Copy content rail instead
  of preserving either a ghost-sidebar gutter or hugging the window edge.

- The Ask bar never appeared on macOS 13 and 15. Assigning a hosting controller
  with no sizing options let AppKit adopt a zero content size, so the panel
  opened at 0x0 — present, on screen, and invisible. It also now recovers its
  width rather than only its height, so a lost frame heals on the next open.
- `id_slot` was being sent on every internal request while having no effect.
  A single-slot server accepts `id_slot: 7` without complaint, so the field is
  not read on this endpoint; it now defaults to off.
- Insights showed "No response body" for every tool call. A tool response
  carries an empty `content` and puts the substance in `tool_calls`, which was
  never read; the empty string then shadowed the raw-body fallback. Tool calls
  are now shown, streamed ones included.

## [1.0.0] — 2026-08-30

The first complete release: a local-AI home for Rosy, the 2017 12-inch MacBook
that inspired the project.

### Added

- Universal macOS 13+ menu bar app for Intel and Apple Silicon.
- Bundled `llama-server` supervisor with an OpenAI-compatible loopback endpoint.
- First-run Bonsai model download and selectable 1.7B, 4B, and 8B downloads.
- Real installed GGUF sizes in the model menu.
- Configurable global Ask bar with streaming Markdown output.
- Compact local timestamps on user messages for temporal context.
- Bounded, scrollable answers that remain visible while generation is active.
- In-memory Insights for prompts, responses, parameters, and performance.
- Settings for inference, sampling, CORS, system prompt, ports, and shortcut.
- Active-inference indicator, request cancellation, launch at login, and logs.
- Automated regression coverage for the proxy, HTTP parsing, Markdown,
  timestamp formatting, and model display metadata.

### Fixed before release

- Replaced the Network framework proxy with BSD sockets for reliable operation
  on native Ventura as well as OCLP Sequoia.
- Corrected keep-alive, chunked transfer, trailers, HEAD, 204, and 304 handling.
- Prevented stale async starts, orphaned servers, unsafe port cleanup, and
  installer relaunch races.
- Prevented cancelled downloads from completing later or leaving partial GGUFs.
- Stopped the Ask bar selecting submitted questions, growing without limit,
  disappearing during generation, or exposing raw Markdown delimiters.
- Kept the system prompt stable while adding timestamp context to user turns.

### Attribution

- Added visible Prism ML/Bonsai credit and the requested Bonsai citation.
- Added third-party license notices to the repository and built app bundle.

[1.0.0]: https://github.com/reneezmp/Rosy-Bit/releases/tag/v1.0.0
[1.1.0]: https://github.com/reneezmp/Rosy-Bit/releases/tag/v1.1.0
