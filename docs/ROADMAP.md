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

## V1.1 candidates

### Chat window

`ChatClient` is already proven by the Ask bar. A full window would add a
collapsible conversation sidebar and proper message bubbles, with the compact
time visible in the UI and the complete timestamp retained in the payload.

The unresolved choice is persistence. Insights is intentionally memory-only
because it may contain legal meeting transcripts. Saving chat history by
default would quietly violate that design. Sensible options are:

1. memory-only conversations;
2. explicit per-conversation saving; or
3. encrypted local history with a visible retention control.

That decision comes before the interface.

### Dictionary tool

A read-only `dictionary.lookup(term)` tool can use macOS Dictionary Services and
the dictionaries already enabled on the machine. It is the safest first tool:
local, bounded, reversible, and useful for a small model.

### Small, native macOS controls

Volume is feasible through Core Audio without screen automation. Rosy Bit
should expose narrow operations such as `volume.get`, `volume.set(0...100)`,
and `volume.mute` through a validated tool-call loop.

The model must never receive unrestricted shell access. Tool requests are
structured, allowlisted, range-checked, executed by native code, and returned to
the model as observations. Read-only tools come before state-changing ones.

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
has explicit confirmation rules, an audit trail, and per-capability switches.
The project grows by consent, not by quietly accumulating authority.

## Permanent guardrails

- Loopback by default; never expose inference to the LAN accidentally.
- No telemetry, account, subscription, or cloud fallback.
- No background polling merely to make an indicator animate.
- No transcript persistence hidden behind a friendly interface.
- No arbitrary command execution delegated to a probabilistic model.
- No abandoning Ventura while Rosy can still do the work.
