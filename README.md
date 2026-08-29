# 🌸 Rosy Bit

**A tiny always-on local LLM server for a 2017 MacBook, in a menu bar app.**

Rosy is a MacBook Retina 12″ (2017) — Core m3, 16 GB, fanless. She has no
Foundation Models and barely supports local ones. Rosy Bit solves that a
little: a `llama-server` running the 1-bit Bonsai 1.7B model, entirely on CPU,
exposing an OpenAI-compatible endpoint that anything on the machine can call
for small helper tasks — titles, tags, summaries, tone rewrites.

Modelled on Ollama's shape: launches at login, no window, sits in the menu bar,
click to start or stop.

```
● Running — 127.0.0.1:1337
──────────────────────────
Model                    ▸
Stop Server
Copy Endpoint URL
Open Log
──────────────────────────
☑ Launch at Login
Quit Rosy Bit          ⌘Q
```

## What it is, precisely

A **house LLM endpoint** for anything that accepts a custom OpenAI-compatible
base URL — Obsidian plugins, indie Mac AI apps, your own scripts and MCP
tooling.

```
http://127.0.0.1:1337/v1
```

It is **not** a replacement for Apple's Foundation Models. That is an OS-level
Swift framework; apps call `SystemLanguageModel` in-process, and there is no
base URL, environment variable, or proxy hook to redirect. On Intel the
framework isn't present at all, so those apps aren't falling back to something
interceptable — the feature simply isn't offered. Aim this at the things that
*do* have a base URL field, and it earns its keep.

Port **1337** matches Osaurus on the M4, so a config pointing at
`localhost:1337` works on either machine unmodified.

## The stack

| Layer | Choice | Why |
|---|---|---|
| Model | Bonsai 1.7B, `Q1_0` GGUF | 0.25 GB on disk, negligible resident footprint |
| Runtime | `llama-server`, upstream llama.cpp | already an OpenAI-compatible endpoint; no wrapper needed |
| Wrapper | Swift menu bar app | `MenuBarExtra` + `Process` + `SMAppService`, deployment target 13.0 |

`Q1_0` is **merged into upstream llama.cpp** ([#21273], with the x86-optimized
CPU kernel in [#21636]) — PrismML's `prism` fork is only needed for ternary
`Q2_0`. That matters: it means stock source builds work if a prebuilt binary
won't cooperate on Ventura.

Deployment target **13.0** because `MenuBarExtra` and `SMAppService` both land
exactly in Ventura — one target covers both sides of Rosy's boot picker with
zero conditional code.

## Getting started

**→ [docs/RUNBOOK.md](docs/RUNBOOK.md)** — every command, in order, with the
output you should see.

The short version:

```bash
# On Rosy — this is the whole project. Nothing else matters until it passes.
./scripts/fetch-llama-server.sh x86_64
./scripts/fetch-model.sh
./scripts/run-by-hand.sh          # then, in another terminal:
./scripts/smoke-test.sh

# On the M4 — build the wrapper
./scripts/fetch-llama-server.sh
make app && make dist

# Back on Rosy — install
unzip RosyBit.zip && mv RosyBit.app /Applications/
xattr -dr com.apple.quarantine /Applications/RosyBit.app
open /Applications/RosyBit.app
```

Either machine can build it. Rosy needs only the Command Line Tools: `make app`
notices there is no XCBuild, builds for the host architecture, and skips the
copy entirely. Building on the M4 needs full Xcode but produces a Universal
bundle that runs on both — the macOS SDK is still Universal for back
deployment, so targeting Ventura from Apple Silicon is a normal supported path.

## Layout

```
Sources/RosyBit/     the app — one file per concern, all of it small
Support/             Info.plist and both icon assets
scripts/             fetch, run, smoke-test, and the icon generator
docs/RUNBOOK.md      the hand-off procedure
Makefile             build on the M4
```

Two icon assets, one sakura motif, and they are not interchangeable. The menu
bar icon **must** be a monochrome template image — macOS tints template images
itself to match the menu bar and appearance mode, so a rosy tint there would
simply be discarded. The rosy tint belongs on the app icon, which is the one
people actually see in System Settings. Both are generated from the same
geometry by `scripts/make-icons.py`, pure standard library, no Pillow.

## Capability expectations

1.7B at 1-bit does titles, tags, short summaries, classification, tone rewrites,
and simple extraction. **It does not reason.** Apple's on-device Foundation
model is roughly 3B and aimed at the same class of task — so the match to
"little helper" work is genuinely reasonable. This is the right size for the
job, not a sad compromise.

[#21273]: https://github.com/ggml-org/llama.cpp/pull/21273
[#21636]: https://github.com/ggml-org/llama.cpp/pull/21636
