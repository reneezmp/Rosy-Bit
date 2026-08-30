# 🌸 Rosy Bit

**A small, private home for local AI on the Macs the industry has already
decided to forget.**

Rosy is a 12-inch Retina MacBook from 2017: a fanless Core m3, 16 GB of memory,
and considerably more life in her than a support matrix would have you believe.
She cannot use Apple Intelligence or the Foundation Models framework. She can,
however, run a genuinely 1-bit language model on her own CPU—and make that model
available to every compatible app on the machine.

Rosy Bit exists because *old* is not the same as *useless*. A computer should
not become waste merely because a corporation has moved the velvet rope. Old
silicon does not need to impersonate a data centre; it needs work shaped to its
strengths. A title. A tag. A careful rewrite. A short summary. A little local
companion waiting in the menu bar.

**Everyone deserves a chance. Machines included.** 🌱

## What V1 does

Rosy Bit is a native macOS menu bar app that supervises `llama-server` and
provides an OpenAI-compatible endpoint:

```text
http://127.0.0.1:1337/v1
```

V1 includes:

- a universal Intel + Apple Silicon app targeting macOS Ventura 13 and later;
- first-run downloads for Bonsai 1.7B, plus 4B and 8B choices in the model menu;
- actual GGUF file sizes beside installed model names;
- a configurable global Ask bar, initially **⌥Space**;
- streamed answers with native Markdown, bounded height, and scrolling;
- compact local context on every user turn, such as
  `[Timestamp: 2026-08-30 13:50 BRT]`;
- an in-memory Insights window for prompts, responses, parameters, and timing;
- settings for ports, context, threads, slots, KV cache, sampling, CORS, the
  system prompt, and the Ask shortcut;
- safe cancellation, orphan cleanup, port-collision reporting, and launch at
  login; and
- no account, subscription, cloud inference, telemetry, or background polling.

The sakura remains quiet when Rosy is quiet. During inference, a green light
appears beside it—not because everything needs an animation, but because a
fanless machine deserves to tell you when it is thinking. 🌸

## What Rosy Bit is for

Bonsai 1.7B at 1 bit is a **little helper**, not an oracle. It is well suited to
titles, tags, classification, extraction, tone rewrites, brief explanations,
and short summaries. It can drift or invent details in long answers, and long
inputs become slow on Rosy's two CPU cores. The app exposes larger Bonsai models
for jobs where quality is worth the wait, but it does not pretend physics has
been defeated.

Anything that accepts a custom OpenAI-compatible base URL can use Rosy Bit:
Obsidian plugins, transcription tools, indie Mac apps, scripts, and local
automation. Port 1337 deliberately matches Osaurus on a newer Mac, so the same
client configuration can follow Renée from one machine to the other.

Rosy Bit is **not** a replacement for Apple's Foundation Models. That is an
in-process OS framework with no endpoint to redirect; on unsupported Intel Macs,
the feature simply is not present. Rosy Bit serves the open door instead: apps
that let their users choose where inference happens.

## Privacy and boundaries

- The server binds to `127.0.0.1`, never the LAN.
- Models live in `~/Library/Application Support/RosyBit/`, outside the app.
- Insights retains at most a bounded in-memory history and disappears when the
  app quits; it is never written to disk.
- Captured credentials are redacted and oversized bodies are truncated.
- Rosy Bit currently gives the model no shell, files, macOS controls, or other
  tools. The only exposed capability is text generation.

If browser access is not needed, CORS can be restricted in Settings. Loopback
keeps other machines out; CORS controls pages running in your own browser.

## The stack

| Layer | Choice | Reason |
|---|---|---|
| Model | Prism ML Bonsai 1.7B, GGUF `Q1_0` | end-to-end 1-bit weights and roughly 0.24 GB on disk |
| Runtime | upstream `llama-server` | mature CPU inference and an OpenAI-compatible API |
| App | Swift, AppKit, SwiftUI | native menu bar behavior with no third-party package dependency |
| Compatibility | macOS 13+, x86_64 + arm64 | one build for Rosy's native Ventura, OCLP Sequoia, and newer Macs |

`Q1_0` support is now in upstream llama.cpp ([#21273]), including its optimized
x86 CPU kernel ([#21636]). Rosy Bit therefore does not require Prism ML's fork
for the binary Bonsai family; that fork remains relevant to ternary `Q2_0`.

## Build and install

The complete, machine-by-machine procedure—including Ventura binary checks,
manual smoke tests, performance measurements, and troubleshooting—is in the
**[runbook](docs/RUNBOOK.md)**.

For a universal build on a Mac with full Xcode:

```bash
git clone https://github.com/reneezmp/Rosy-Bit.git
cd Rosy-Bit
./scripts/fetch-llama-server.sh
make app
./scripts/install.sh --no-build
```

Rosy can also build her own Intel-only copy with the Command Line Tools. On the
first launch, the app offers to download a model. Models and runtime binaries
are deliberately absent from Git history.

Useful project references:

- **[Runbook](docs/RUNBOOK.md)** — build, installation, configuration, and repair
- **[Testing](docs/TESTING.md)** — automated coverage and real-machine checks
- **[Roadmap](docs/ROADMAP.md)** — what V1 settled and what comes next
- **[Changelog](CHANGELOG.md)** — release history
- **[Third-party notices](THIRD_PARTY_NOTICES.md)** — licenses and attribution

## Acknowledgements

Rosy Bit is **created using Bonsai by Prism ML**. Bonsai is the reason a useful
language model fits on Rosy at all, and that work deserves more than a filename
hidden in a download script. The Bonsai GGUF release is Apache-2.0, descends
from Apache-2.0 Qwen3-1.7B, and is downloaded separately from the app.

If you use or discuss Bonsai academically, Prism ML requests this citation:

```bibtex
@techreport{bonsai,
  title  = {Bonsai: End-to-End 1-bit Language Model Deployment
            Across Apple, GPU, and Mobile Runtimes},
  author = {Prism ML},
  year   = {2026},
  month  = {March},
  url    = {https://prismml.com}
}
```

Inference is powered by the MIT-licensed
[llama.cpp](https://github.com/ggml-org/llama.cpp). The complete license text,
Bonsai notice, upstream links, and redistribution notes live in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and are copied into every app
bundle Rosy Bit builds.

Rosy Bit is an independent project. “Bonsai,” “Prism ML,” “Qwen,” “Apple,” and
other third-party names belong to their respective owners; acknowledgement is
gratitude, not endorsement or affiliation.

## The promise

Rosy Bit will never make a 2017 Core m3 feel like a modern datacentre. That was
never the promise.

The promise is smaller, stranger, and more important: **we will look at what a
machine can still become before deciding what it no longer deserves to be.**

[#21273]: https://github.com/ggml-org/llama.cpp/pull/21273
[#21636]: https://github.com/ggml-org/llama.cpp/pull/21636
