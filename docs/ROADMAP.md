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

### Read-only native volume — implemented

`volume.get` reads the current system output volume through Core Audio without
screen automation, shell execution, or any ability to mutate the Mac. It uses
the same strict one-call allowlist as the dictionary and is gated to the
measured Bonsai 1.7B Q1_0 build.

`volume.set(0...100)` and `volume.mute` remain later work. The earlier proposal
for a mandatory conversational confirmation would add a costly extra turn to a
small local model. Before either ships, the interaction needs a design that
preserves argument fidelity without making every ordinary adjustment a
two-round conversation—for example a direct deterministic intent path or a
non-conversational UI affordance.

The model must never receive unrestricted shell access. Tool requests are
structured, allowlisted, range-checked, executed by native code, and returned to
the model as observations. Read-only tools come before state-changing ones.

The read-only-first ordering has a measurement behind it. Asked to set the volume to 200,
the model answered with a schema-valid, in-range, and simply wrong `level: 20`.
When a request cannot be honoured it does not signal failure; it produces
something plausible and proceeds. Validation cannot catch that. State-changing
controls therefore remain absent until semantic fidelity and interaction cost
are solved together. A wrong lookup costs a wrong definition. A wrong
`volume.set` costs trust.

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

### Additional system tools

Calendar, reminders, Shortcuts, files, or automation only after the tool layer
has an interaction appropriate to each risk, an audit trail, and per-capability switches.
The project grows by consent, not by quietly accumulating authority.

## Permanent guardrails

- Loopback by default; never expose inference to the LAN accidentally.
- No telemetry, account, subscription, or cloud fallback.
- No background polling merely to make an indicator animate.
- No transcript persistence hidden behind a friendly interface.
- No arbitrary command execution delegated to a probabilistic model.
- No abandoning Ventura while Rosy can still do the work.
