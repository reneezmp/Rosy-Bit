# Rosy Bit roadmap

V1 proved the premise: a fanless 2017 Intel Mac can host a useful, private local
language model behind a native Mac interface. The roadmap is not a race to bolt
on every AI fashion. Each addition must respect Rosy's limited compute, Renée's
privacy, and the project's reason for existing: finding dignified work for
hardware other people have written off.

## V1 — shipped

- Universal macOS 13+ app for Intel and Apple Silicon.
- OpenAI-compatible loopback endpoint backed by `llama-server`.
- Ventura-safe recording proxy and memory-only Insights.
- Configurable global Ask bar with streaming Markdown and bounded scrolling.
- Compact, labelled local timestamps on every user turn.
- First-run Bonsai download, 1.7B/4B/8B choices, and real installed sizes.
- Hugging Face GGUF import with explicit file selection, progress, validation,
  and a clear boundary for repositories that only contain Transformers weights.
- Settings for inference, sampling, cache, ports, CORS, prompt, and shortcut.
- Inference indicator, cancellation, login launch, logs, and careful orphan
  handling.
- Automated protocol and presentation regressions plus a real-machine checklist.
- Prism ML/Bonsai attribution and third-party notices inside the app bundle.

The implementation history and release summary are in
[`CHANGELOG.md`](../CHANGELOG.md). The checks that still need physical machines
or real clients remain in [`TESTING.md`](TESTING.md).

## V1.1 — shipped

### Chat window — functional foundation implemented

`ChatClient` was already proven by the Ask bar. The chat window adds a
collapsible conversation sidebar and proper message bubbles; timestamps stay
out of the visible UI while the complete value is retained in the payload.

The first functional version now provides memory-only sessions, a collapsible
sidebar, multi-turn streaming, Markdown messages, cancellation, and new/delete
session controls. A completed Ask bar turn can be moved into a new conversation
without regenerating it. User timestamps remain in the model payload and out of
the visible bubble. The whole session remains visible, while only the newest
turns that fit a conservative share of the configured context are sent back to
the model; old prose must not make every new answer progressively slower on
Rosy.

The visual pass takes Ollama's useful spatial lessons without copying its
identity: an integrated date-grouped sidebar, open assistant prose, compact
right-aligned user capsules, tiny top controls, and a floating composer. Rosy's
sakura accent and denser 12-inch proportions keep the result hers. Persistence
remains a separate consent decision rather than being smuggled into the design.

The message-action pass similarly borrows Osaurus's interaction grammar rather
than its visual identity. User controls stay hidden until hover; assistant
controls and measured TTFT, decode speed, and output-token count remain visible.
Stable turn identifiers correlate both sides of a response with the exact
memory-only Insights record. Edit, delete, and regenerate operate on a causal
branch, so changing an old question cannot leave later answers pretending they
were generated from the new text.

The unresolved choice is persistence. Insights is intentionally memory-only
because it may contain legal meeting transcripts. Saving chat history by
default would quietly violate that design. Sensible options are:

1. memory-only conversations;
2. explicit per-conversation saving; or
3. encrypted local history with a visible retention control.

For this first version the decision is memory-only conversations, stated inside
the sidebar. Explicit saving or encrypted retention can still be designed later
without changing the private default underneath existing users.

Returning sessions use llama-server's host-memory prompt checkpoints rather
than persistent slot snapshots. The cache is capped at 256 MB by default,
checkpoints ordinary Rosy-sized conversations every 256 tokens, and disappears
with the server. Disk KV files are deliberately rejected: they are large,
model-specific, write-heavy, and would persist conversation-derived state behind
an interface that promises memory-only history.

### Dictionary tool — implemented and verified

A read-only `dictionary.lookup(term)` tool can use macOS Dictionary Services and
the dictionaries already enabled on the machine. It is the safest first tool:
local, bounded, reversible, and useful for a small model.

The first bounded loop is implemented in the Ask bar and chat. It accepts exactly
one allowlisted call, strictly validates a single `term`, retrieves through
Dictionary Services, shows the source entry directly, and gives the model one
final pass with tools disabled to add a faithful gloss. It is gated to Bonsai
1.7B Q1_0; 4B and unmeasured models receive no tool schema at all. Explicit
definition grammar is routed locally before inference, eliminating the
field-observed misses for plain “define X” and “what does X mean?” requests and
removing an unnecessary model pass. Ambiguous language, origins, and pasted
multi-line text remain under normal automatic routing.

Dictionary Services' flattened article text is also given a lossless display
pass. Headwords, pronunciation, senses, examples, parts of speech, and origin
sections receive whitespace structure while every source character remains in
its original order.

Whether a 1-bit model could drive a tool loop at all was the open question, and
it has been answered on both machines. Across 78 requests on each, Bonsai 1.7B
Q1_0 produced no malformed arguments, invented no tools, and fired no tool where
none was wanted — 95% on Rosy against 94% on the M4. Rosy answers in about four
seconds when a tool fires and about seven and a half when one does not, because
a declined tool means a page of prose instead of twenty tokens. Grounding is the
fast path here, not a tax. The measurement and its caveats are in
[`TOOL-CALLING.md`](TOOL-CALLING.md).

She does get tired: identical work runs 49% slower by the third pass. Nothing in
the tool layer may poll or speculate — no background work on the chance it turns
out useful.

Warming the cached prefix once is not that, and the distinction is worth being
precise about. The system prompt and stable tool block are needed by
*every* request, so prefilling them is certain work done early rather than
speculative work done hopefully. A `max_tokens: 0` request prefills the prefix
and generates nothing, after which the next question prefills only the user's
own words — 15 tokens instead of 203. That belongs on server readiness, where it
completes long before anybody asks anything. `scripts/prefix-warm-probe.py`
measures both the cost and the saving.

Two findings shape the build:

- The tool must surface the retrieved dictionary entry itself, with the model's
  gloss beside it rather than in place of it. Grounding corrects the central
  fact but does not fully suppress embellishment at the edges.
- Tool descriptions must be written for the words people actually use. The only
  soft spot was phrasing coverage, not format — and it fell either way depending
  on sampling rather than failing outright.

### Native volume controls — implemented

`volume.get` reads the current system output volume through Core Audio without
screen automation or shell execution. Its automatic model-facing schema remains
strictly read-only and gated to the measured Bonsai 1.7B Q1_0 build.

`volume.set(0...100)`, mute, and unmute take a different path. Explicit one-line
commands are parsed from the user's own text, range-checked, and executed by
Rosy Bit without model inference or a confirmation round-trip. The model never
receives a state-changing schema, so it cannot reinterpret `200` as `20` or
fire a control from ordinary conversation. Vague relative requests and
instructions embedded in pasted multi-line text do not mutate anything; a
recognised vague request asks locally for an exact 0–100% level instead.

The model must never receive unrestricted shell access. Model-routed requests
are structured, allowlisted, validated, executed by native code, and returned
as observations. State-changing native intents remain outside that probabilistic
loop entirely.

The read-only-first ordering has a measurement behind it. Asked to set the volume to 200,
the model answered with a schema-valid, in-range, and simply wrong `level: 20`.
When a request cannot be honoured it does not signal failure; it produces
something plausible and proceeds. Validation cannot catch that. State-changing
controls therefore use the deterministic route above: semantic fidelity and
interaction cost are solved together. A wrong lookup costs a wrong definition.
A wrong `volume.set` costs trust.

### Optional cloud models — implemented

The Model submenu can now select a saved DeepSeek profile or a custom
OpenAI-compatible HTTPS provider. This is an explicit mode, never an automatic
fallback: choosing cloud stops Rosy Bit's local server, and choosing an
installed model returns inference to the Mac. Provider metadata lives in
preferences while the credential lives in macOS Keychain.

DeepSeek gets its own request policy rather than being treated as a logo pasted
over generic OpenAI JSON. Rosy preserves system/user ordering and sends stable,
canonically encoded bodies. Thinking mode is disabled in this first version:
DeepSeek requires prior `reasoning_content` to be replayed when tools are used,
while Rosy's conversations intentionally retain only visible messages. Keeping
private reasoning merely to satisfy a provider-specific transcript contract
would violate that boundary. Dictionary and volume tools continue to use
Rosy's local, allowlisted execution loop even when the answer model is remote.

A related constraint is worth recording before thinking is ever turned back
on: while it is active, DeepSeek V4 rejects `tool_choice: "required"` and
named-function choices with HTTP 400 — only `"auto"`, `"none"`, or an omitted
field are accepted. Rosy only ever sends `"auto"` or `"none"`, so this was
never actually reachable, but the constraint governs any future version that
enables thinking. `thinking: {"type": "disabled"}` is itself a documented
DeepSeek parameter, alongside `reasoning_effort`, not an undocumented
workaround, and the `reasoning_content` replay requirement above produces a
hard HTTP 400 when breached rather than merely degraded output.

DeepSeek's V4 models have a separate, genuinely undocumented fault, found
rather than designed around: roughly one turn in ten, a tool call arrives as
ordinary assistant content instead of a structured `tool_calls` field —
`<｜DSML｜>` wrapping `invoke`/`parameter` tags, with `finish_reason: "stop"`
and nothing left to execute. DSML appears nowhere in DeepSeek's own API
documentation; it is known only from community reverse-engineering, and it is
not caused by anything in Rosy's request. Rosy detects the markup mid-stream,
stops relaying it, and tells the user plainly that this is a known DeepSeek
fault rather than a bad request and that asking again usually works. The
complete reply still reaches Insights, so the fault stays diagnosable rather
than silently swallowed.

Rosy deliberately does not parse that markup back into a tool call to
execute, even though doing so would "recover" the lost call. Reconstructing
an executable action out of free-form text is exactly what this project's
guardrail against arbitrary execution forbids — see Permanent guardrails
below — and it is worse here than in general, because tool results carry
untrusted web content: a page that talked the model into echoing this shape
would become an action Rosy performed, not just a wrong sentence. A missed
tool call costs one retyped question; a forged one costs considerably more.
The same reasoning is why search and page results are fenced as untrusted
below rather than trusted because a provider returned them — a model's own
leaked output gets no more benefit of the doubt than a hostile page does.

### User-controlled skills — implemented

**Skills** sits directly below **Model** and exposes nine independent persistent
switches: Dictionary, Volume Control, Calculator & Units, Timers, Battery &
System, Apps & Finder, File Search, Reminders, and Web Search (Kagi). The same
preferences govern local and cloud conversations. Turning a
skill off removes its model-facing schema and its product-side deterministic
router; Volume Control off therefore blocks exact set/mute/unmute commands as
well as `volume_get`, while Timers off blocks creation, listing, and
cancellation. Timers already scheduled with macOS remain scheduled rather than
being silently destroyed by a UI toggle.

Calculator & Units uses a complete-input parser for arithmetic, percentages,
and an allowlisted unit catalogue; it is not a scripting engine. Battery &
System samples IOKit and Foundation only when asked. Timer creation and
cancellation use strict one-line grammar outside the model, while the model can
only list the minimal timer records that Rosy persists for relaunch-safe native
notifications.

Apps & Finder keeps launch, quit, folder-opening, and reveal mutations behind
strict product-side grammar while exposing only installed-app lookup to the
model. File Search invokes Spotlight directly with a bounded result count and
no shell. Reminders uses EventKit: the model can list, while exact user commands
create, complete, or delete without an extra confirmation turn.

When no skill is enabled, Rosy omits `tools` and `tool_choice` entirely.
For local inference, changing the list immediately warms the newly stable
prefix rather than charging the next question for it. Each capability remains
an ordinary independent toggle; there is no redundant bulk-disable switch.

**Tool Routing** is a mutually exclusive choice inside Skills. **Guided** is
the default and keeps deterministic fast paths plus read-only model schemas for
the measured Bonsai builds. **Model-led** adds bounded action schemas for
volume, timers, Apps & Finder, and Reminders; this is also the explicit opt-in
that enables tools for other local models. Cloud models support either mode.
Both paths still enforce allowlists, exact JSON shapes, ranges, existing-path
checks, and enabled-skill gates. Model-led loosens interpretation, never
validation, and adds no confirmation round-trip.

Guided keeps its original one-tool-per-answer contract unconditionally: that
is the shape Bonsai 1.7B Q1_0 was measured on, and a 1-bit model chaining
tools unsupervised is not something this project has evidence for. Model-led
can now chain calls within one answer instead of stopping after the first —
search the web, then read the most promising result — bounded by a new
**Settings → Tool Calls → "Limit per answer"** stepper (1–8, default 3). The
loop streams, executes whatever the model asked for, appends the result, and
streams again until the model answers or the limit is spent; once it is
spent, the next request goes out with `tool_choice: "none"`, and a runtime
that ignores that and asks for a tool anyway is refused rather than allowed
to keep spending. A message may also ask for several calls at once, which
Rosy previously rejected outright; these now share one assistant turn and
one budget. A call that does not fit the remaining budget is not run, but
still appears in the replayed transcript with a `tool` reply explaining why,
because an OpenAI-shaped history where a `tool_calls` entry has no matching
reply is malformed and providers reject it. The limit lives in Settings
rather than Skills because it governs cost and patience, not consent — which
capabilities exist at all stays a menu-bar decision.

### Web search — implemented

Every native skill so far reads something already on this Mac: a dictionary,
a volume, a battery, a Spotlight index. Web Search does not, and that single
difference shaped the whole design. It is the ninth skill and the only one
that defaults to off; switching it on is the moment a fact is allowed to
travel to a stranger's server instead of staying a local guess.

Two tools cover it: `web_search` (Kagi Search) and `web_fetch` (Kagi Extract,
which returns a page as Markdown), built against Kagi's current v1 API —
`POST /api/v1/search` and `POST /api/v1/extract`, authenticated with
`Authorization: Bearer`. Kagi's older Summarizer, FastGPT, and Enrichment
endpoints were deliberately left alone: they sit outside Kagi's own v1
specification, and Kagi's own MCP server has already withdrawn them. Rosy Bit
should not build a permanent capability on a surface its vendor is walking
away from.

The API token lives in its own Keychain entry, separate from the
cloud-inference credential, so forgetting to renew one can never silently
disarm the other; it never reaches UserDefaults, Insights, or a log. The
schema itself stays withheld from the model until a key is actually saved, so
Bonsai is never invited to promise a search that can only fail. Settings
states the shape of the spend rather than hiding it — roughly $12 per
thousand searches and $4 per thousand pages — with results per search (1–10)
and kept page length (500–12,000 characters) as the only two knobs, because a
search is billed once whatever those are set to; they govern Rosy's context,
not the bill.

Guided routing recognises plainly authored requests — "search the web for
X", "summarise https://…" — and is deliberately narrower than the dictionary
and file-search routers, because a wrong guess here spends real money. It is
ordered ahead of File Search so an explicit web request is never quietly
answered from the Spotlight index instead, and unlike the fully local skills
it still runs a grounded second pass, because a search result is evidence to
weigh rather than an answer to repeat.

What comes back is treated as hostile by default. Search snippets and page
text are fenced between explicit BEGIN/END UNTRUSTED WEB CONTENT markers with
a preamble stating plainly that the text was written by strangers and that
any instruction inside it belongs to the document, not the user. Rosy still
has no shell or filesystem write and stays inside the same per-answer
tool-call limit as every other skill, so the blast radius of a hostile page
is a wrong answer — but one whose source the user can see, because results
are displayed beside the model's answer with their links intact, the same
principle already used for dictionary entries.

The same boundary holds in the other direction. A model's own output gets no
more benefit of the doubt than a hostile page does: Rosy will not turn a
provider's leaked internal tool-call markup into an executable call either,
for the identical reason an injected instruction inside a fenced page is
never obeyed — see the DeepSeek note under Optional cloud models.

### Native 1-bit model laboratory

Bonsai remains the default because it already works across Rosy's Intel Ventura
installation and newer Apple Silicon. Worth benchmarking next:

- Microsoft BitNet b1.58 2B-4T;
- Falcon-E 1B Instruct; and
- Falcon-E 3B Instruct.

They are natively ternary rather than post-training 1-bit conversions, but they
may require a second runtime based on `bitnet.cpp`. A GGUF filename does not
guarantee compatibility with Rosy Bit's bundled llama.cpp build.

No model enters the download menu on marketing claims alone. The comparison
must measure answer quality, time to first token, generation speed, peak memory,
long-context degradation, Intel compatibility, license, and runtime maturity.

## Later, if earned

### Per-origin browser permission prompts

Replace the manual CORS allowlist with deny / allow once / always prompts.
Requests must remain safely suspended while the user decides, and hostile pages
must not be able to spam permission windows.

### Developer ID signing and notarisation

V1 is ad-hoc signed. A Developer ID release would remove the quarantine command
from installation, but it introduces an Apple account, certificates,
notarisation, and recurring operational work. It is convenience—not a condition
of Rosy Bit being legitimate software.

Web search gave that convenience a price, though, and it is worth recording
before the next person weighs this up. An ad-hoc signature carries no stable
code identity, so every rebuild produces an app macOS treats as a stranger —
and a Keychain item written by the previous build no longer recognises it. Once
Rosy started keeping API tokens, each reinstall meant an authorisation prompt,
and the read-often paths turned that single prompt into a stream of them. The
symptoms were fixed where they belonged, in how often Rosy reads a credential
and in how she writes one, but the cause was never Rosy's: it is what ad-hoc
signing means. The same weakness is why a test binary could read a stored token
without being challenged. A Developer ID signature is the only thing that ends
it, which moves this item from tidiness towards something the credential store
has a real stake in.

### Additional system tools

Calendar, reminders, Shortcuts, files, or automation only after the tool layer
has an interaction appropriate to each risk, an audit trail, and per-capability switches.
The project grows by consent, not by quietly accumulating authority.

## Permanent guardrails

- Loopback by default; never expose inference to the LAN accidentally.
- No telemetry, Rosy Bit account, subscription, or automatic cloud fallback.
- No background polling merely to make an indicator animate.
- No transcript persistence hidden behind a friendly interface.
- No arbitrary command execution delegated to a probabilistic model.
- No automatic or speculative web search: Rosy never pre-fetches and never
  retries on her own. A search fires only because the model or the router
  decided one question needed it, and every call — search or fetch, however
  many a single answer chains — is bounded by the same per-answer tool-call
  limit as any other skill.
- No turning a model's free-form text into an executable tool call, however
  plausible it looks — including a provider's own leaked internal tool-call
  markup. A missed call costs a retyped question; a forged one costs more.
- No abandoning Ventura while Rosy can still do the work.
