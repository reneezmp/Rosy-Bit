# Rosy Bit runbook

Everything you actually type, in order, with what you should see back.

Two machines are involved:

| Machine | Role | Why |
|---|---|---|
| **Rosy** — MacBook10,1, Core m3, Ventura 13.7.8 / Sequoia 15 (OCLP) | runs the server | it's the point |
| **the M4** | builds the `.app` | Xcode 27 is Apple Silicon only, and Xcode 26 on Intel has gone messy |

Building on one Mac and running on another is a normal supported path — the
macOS SDK is still Universal for back deployment. It is not a hack.

---

## Step 1 — prove the server works on Rosy

**Step 1 is the whole project. Everything after it is a wrapper.** Do not write
or build any Swift until the smoke test passes.

```bash
mkdir -p ~/Developer
git clone -b claude/rosy-bit-planning-90xr0a \
  https://github.com/reneezmp/Rosy-Bit.git ~/Developer/rosy-bit
cd ~/Developer/rosy-bit
```

### 1a. Get `llama-server`

```bash
./scripts/fetch-llama-server.sh x86_64
```

Expected:

```
llama.cpp b10684 — checking binaries against macOS 13.7.8
trying https://github.com/ggml-org/llama.cpp/releases/download/b10684/llama-b10684-bin-macos-x64.tar.gz
installed vendor/x86_64/ (53M)
  minos: 13.3 — OK for macOS 13.7.8
```

**The Swift is not the risk here — the prebuilt binary is.** If it was compiled
against a newer SDK it will refuse to launch on Ventura, and the failure much
later looks like a Gatekeeper problem rather than what it is. The script runs
the check for you; to do it by hand:

```bash
otool -l vendor/x86_64/llama-server | grep -A3 LC_BUILD_VERSION
```

The number that matters is **the OS that will actually run the binary**, not the
app's deployment target. Rosy is on Ventura 13.7.8, so a `minos` of 13.3 is
fine there — the app bundle targets 13.0 for its own Swift, which is a separate
question. The script defaults to checking against the machine it is running on,
which is correct when you run step 1 on Rosy as above.

**Fetching Rosy's slice from the M4 instead?** The default is then the M4's own
version, which tells you nothing useful. Pass Rosy's:

```bash
TARGET_MACOS=13.7.8 ./scripts/fetch-llama-server.sh x86_64
```

**If `minos` really is above the target** the script refuses: it deletes the
Intel payload and exits non-zero rather than leave an unlaunchable binary for
`make app` to pick up. (`ALLOW_NEW_MINOS=1` overrides. A newer `minos` on the
*arm64* slice is only ever a warning — that slice never leaves the M4.)

Then compile from source on Rosy. Slow on two cores, but straightforward — and
note you do **not** need PrismML's `prism` fork.
`Q1_0` was merged into upstream llama.cpp ([#21273], with the x86-optimized CPU
kernel in [#21636]); the fork is only needed for ternary `Q2_0`.

```bash
# Xcode 14 Command Line Tools + cmake
xcode-select --install
brew install cmake

git clone --depth 1 --branch b10684 \
  https://github.com/ggml-org/llama.cpp ~/Developer/llama.cpp
cd ~/Developer/llama.cpp
cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=OFF \
  -DLLAMA_CURL=OFF
cmake --build build --config Release -j 2 --target llama-server

mkdir -p ~/Developer/rosy-bit/vendor/x86_64
cp build/bin/llama-server ~/Developer/rosy-bit/vendor/x86_64/
```

`BUILD_SHARED_LIBS=OFF` gives one self-contained binary with no dylibs to keep
track of, which is what you want inside an app bundle. Expect this to take a
while — it is a fanless two-core machine.

### 1b. Get the model

```bash
./scripts/fetch-model.sh
```

Expected: `installed /Users/you/Library/Application Support/RosyBit/Bonsai-1.7B-Q1_0.gguf (250M)`

0.25 GB on disk, negligible resident footprint on 16 GB. The script asks the
Hugging Face API which files exist rather than guessing the filename; override
with `MODEL_FILE=...` if you want a specific one.

### 1c. Run it by hand

```bash
./scripts/run-by-hand.sh
```

This runs `llama-server` in the foreground with exactly the flags the app will
use: `--host 127.0.0.1 --port 1337 -c 2048 -t 2 --jinja`, and **no `-ngl`**
(every Bonsai example uses `-ngl 99` for GPU offload — that is written for CUDA
and Apple Silicon Metal; stay CPU-only on the HD 615).

### 1d. Smoke test

Second terminal:

```bash
./scripts/smoke-test.sh
```

Expected:

```
waiting for http://127.0.0.1:1337/health ... ok

prompt : Write a 4-word title for a note about sleep settings on old laptops.
reply  : Sleep Settings for Laptops

endpoint ready: http://127.0.0.1:1337/v1
```

**If that returns something coherent, everything downstream is just
configuration.** Ctrl-C the server and move on.

If generation makes the cursor stutter, try `THREADS=1 ./scripts/run-by-hand.sh`
and use the same value for the app (see [Configuration](#configuration)).

---

## Step 2 — build the app

You need a Swift toolchain, not necessarily Xcode. Two routes work:

**On Rosy, with just the Command Line Tools.** Simplest, and it skips step 3
entirely — no copy, no quarantine, no `lipo` worry. `make app` detects that
XCBuild is absent and builds for the host architecture alone, which is exactly
what Rosy runs. You are already in the right directory:

```bash
cd ~/Developer/rosy-bit && make app && make run
```

**On the M4, with full Xcode.** Builds universal, so the same bundle runs on
both machines and the UI can be exercised on fast hardware first. Follow the
rest of this step and then step 3.

> Passing `--arch` twice routes SwiftPM through XCBuild, which only ships inside
> full Xcode. With the Command Line Tools alone it fails with
> `xcbuild executable ... does not exist` — that is the toolchain talking, not
> your machine being too old. Override the detection with `UNIVERSAL=1` or
> `UNIVERSAL=0` if you ever need to.

### On the M4

```bash
mkdir -p ~/Developer
git clone -b claude/rosy-bit-planning-90xr0a \
  https://github.com/reneezmp/Rosy-Bit.git ~/Developer/rosy-bit
cd ~/Developer/rosy-bit

./scripts/fetch-llama-server.sh     # both slices this time
make app
```

If Rosy needed a source build in step 1a, copy that binary over rather than
letting the script fetch a prebuilt one:

```bash
scp rosy:Developer/rosy-bit/vendor/x86_64/llama-server vendor/x86_64/
```

`make app` builds universal, assembles `dist/RosyBit.app`, ad-hoc signs it, and
verifies the result:

```
  app archs      : x86_64 arm64
  llama-server   : x86_64 x86_64
  llama-server   : arm64 arm64
  signature      : ok
built dist/RosyBit.app
```

Because the arm64 slice is in there too, you can test the whole thing on the M4
before copying anything:

```bash
./scripts/fetch-model.sh    # the M4 needs its own copy
make run
```

The model lives in `~/Library/Application Support/RosyBit/`, which is per
machine — downloading it on Rosy did nothing for the M4. Without it the menu
says `⚠ No model — open the models folder`, which is the app working correctly,
not a build problem.

> **Stop Osaurus first.** It also defaults to port 1337 — that is the entire
> point of choosing 1337 — so the two cannot run at the same time. Rosy Bit will
> notice and say `⚠ Port 1337 held by osaurus` rather than fighting it. That is
> worth seeing once: it is the orphan-handling path refusing to kill something
> that is not ours.

Then package it:

```bash
make dist        # dist/RosyBit.zip
```

---

## Step 3 — copy to Rosy

```bash
scp dist/RosyBit.zip rosy:~/Downloads/
```

On Rosy:

```bash
cd ~/Downloads && unzip RosyBit.zip
mv RosyBit.app /Applications/

# Verify it is actually Intel-capable
lipo -archs /Applications/RosyBit.app/Contents/MacOS/RosyBit
# wants to say: x86_64 arm64

# Gatekeeper: unsigned app built on one Mac, run on another → quarantine
xattr -dr com.apple.quarantine /Applications/RosyBit.app

open /Applications/RosyBit.app
```

`scp` does not set the quarantine attribute; AirDrop and browser downloads do.
Running `xattr -dr` is harmless either way.

A sakura appears in the menu bar. No Dock icon, no window — `LSUIElement` is
set, so the menu bar item is the entire interface.

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

Confirm with `./scripts/smoke-test.sh` again — this time against the app's
server rather than your hand-run one.

---

## Step 4 — launch at login, then reboot

The app registers itself as a login item on first run, so **Launch at Login**
should already be ticked. It appears in System Settings → General → Login Items
as "Rosy Bit", with the rosy app icon.

> Registration needs the app in a stable location. If the toggle refuses to
> stick, check the app is in `/Applications` and not still in `~/Downloads`.

Reboot Rosy. Log in. Wait a few seconds, then:

```bash
curl -s http://127.0.0.1:1337/health
```

`{"status":"ok"}` means it came back on its own. That is the whole feature.

---

## Step 5 — point something at it

Anything that accepts a **custom OpenAI-compatible base URL**:

```
Base URL:  http://127.0.0.1:1337/v1
API key:   any non-empty string (it is ignored)
Model:     bonsai (also ignored — the loaded model is always served)
```

**Copy Endpoint URL** in the menu puts the base URL on the clipboard.

### What to expect from it

1.7B at 1-bit does titles, tags, short summaries, classification, tone rewrites,
and simple extraction. **It does not reason.** For calibration, Apple's
on-device Foundation model is roughly 3B and is aimed at the same class of task
— so this is the right size for the job, not a sad compromise.

Quality holds up better than the size suggests. Given a rambling Portuguese
legal meeting transcript it produced *"Ineficácia relativa em embargos de
terceiros"* — the actual doctrine under discussion, not a generic label.

**Speed is the real constraint, and it is the input that costs, not the
output.** Measured on Rosy, both rates degrade as the context fills:

| Prompt | Prompt eval | Generation | Total |
|---|---|---|---|
| 182 tokens | 26.8 tok/s | 6.6 tok/s | 9 s |
| 1257 tokens | 13.8 tok/s | 2.2 tok/s | 98 s |
| ~5700 tokens | ~10 tok/s | ~1 tok/s | ~9 min |

So: a selection, a note, an email — interactive. A full meeting transcript —
a background job. Raising `contextSize` makes long input *possible*, never
fast; nothing about a fanless two-core machine changes that.

### What this is not

Not a replacement for Apple's Foundation Models. `FoundationModels` is an
OS-level Swift framework; apps call `SystemLanguageModel` in-process. There is
no base URL, no environment variable, no proxy hook — nothing to redirect. On
Intel the framework isn't present at all, so those apps aren't falling back to
something interceptable; the feature simply isn't offered.

---

## Configuration

The port is fixed at 1337 for parity with Osaurus. The rest can be changed
without a rebuild:

```bash
defaults write com.rosybit.app threads -int 1        # if the UI stutters
defaults write com.rosybit.app contextSize -int 8192
defaults write com.rosybit.app port -int 8080
osascript -e 'quit app "RosyBit"' && open /Applications/RosyBit.app
```

Quit it with an Apple Event rather than `killall`. SIGTERM kills an AppKit app
outright without running `applicationWillTerminate`, which is precisely the
force-quit case that leaves `llama-server` holding the port. Rosy Bit clears
that orphan on its next launch, so nothing breaks either way — but there is no
reason to create the mess when quitting politely is the same length.

**`contextSize` is the one you will actually hit.** The default 2048 is enough
for titles and tags but not for a meeting transcript — a client sending more
gets back `request (N tokens) exceeds the available context size`, which is the
server refusing cleanly, not a crash. Roughly 750 words per 1000 tokens, so
8192 covers about 6000 words.

**It costs real memory.** Bonsai is Qwen3-1.7B — 28 layers, 8 KV heads,
head_dim 128 — which is 112 KiB of KV cache per token at f16:

| `contextSize` | KV cache | Measured RSS |
|---|---|---|
| 2048 | 229 MiB | — |
| 8192 | 917 MiB | **1.28 GB** |
| 32768 | 3.6 GiB | ~4 GB (extrapolated) |

Measured on Rosy with `ps -o rss= -p $(lsof -ti tcp:1337 -sTCP:LISTEN)`: at
8192 the whole process is 1.28 GB, which is the 0.9 GiB of cache plus 0.24 GB
of weights plus buffers. Use that command rather than trusting the table.

Note what the measurement did **not** show: llama-server reports four slots by
default, but RSS matches a *single* 8192-token cache rather than four. The log
also reports `kv_unified = 'true'`, so the slots appear to share one cache
rather than each holding a full context.

Rosy Bit still sets `parallelSlots` to **1**, on its own merits: two cores
cannot usefully generate four replies at once, and requests arrive one at a
time in practice. Raise it only if something genuinely needs concurrency.

```bash
defaults write com.rosybit.app parallelSlots -int 2
defaults write com.rosybit.app kvCacheType q8_0     # ~halves the table above
defaults write com.rosybit.app temperature -float 0.3
```

`kvCacheType` is the cheapest way to afford a big context. Some builds refuse a
quantised V cache without flash attention — if the server stops starting after
you set it, that is why, and the log will say so.

`temperature` is only a fallback: an OpenAI-compatible client that sends its own
`temperature` wins, and most do.

The model's trained context is **32,768**, so anything up to that is legitimate
— memory is the limit, not the model.

Check the log after raising it; llama-server warns there if the value exceeds
what the model was trained for:

```bash
grep -i "n_ctx_train\|greater than" ~/Library/Logs/RosyBit/llama-server.log
```

### Browser origins

llama-server warns at startup that it allows all CORS origins. Loopback keeps
the *network* out, but not browsers: a page you are visiting can call this
endpoint from JavaScript. It can only reach the model — no tools, no file
access — so what is at stake is CPU time on a fanless machine, not data. Native
clients (curl, scripts, Obsidian's `requestUrl`) send no `Origin` and do not
care either way.

Once you know which clients you actually need, close it:

```bash
defaults write com.rosybit.app corsOrigins "app://obsidian.md"
```

Unset, the server keeps its own permissive default. Set it only after the
client works, so a broken plugin is never ambiguous between the two causes.

**Swapping models** needs no rebuild either — the `.gguf` lives outside the
bundle. Drop another one into `~/Library/Application Support/RosyBit/` and pick
it from the **Model** submenu; the server restarts on the new model. **Open
Models Folder…** in that submenu takes you there.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `"RosyBit" is damaged and can't be opened` | quarantine | `xattr -dr com.apple.quarantine /Applications/RosyBit.app` |
| No menu bar icon at all | wrong architecture | `lipo -archs` — needs `x86_64` |
| `⚠ llama-server exited with code 1` | bad or missing model | **Open Log**; check the `.gguf` downloaded fully |
| Server dies instantly, log mentions dyld | `minos` too new, or missing dylib | rebuild from source on Ventura (step 1a) |
| `⚠ Port 1337 held by <name>` | something else has the port | quit it, or change `port` above |
| Launch at Login won't stick | app not in a stable location | move to `/Applications`, toggle again |
| Menu says Running but clients time out | still loading the model | wait; `curl /health` returns 503 until ready |

**Orphaned servers.** Force-quit the app and `llama-server` would normally keep
running and hold the port. Rosy Bit handles this at both ends: it kills its
child in `applicationWillTerminate`, and on launch it checks the port and
clears an orphan it recognises. It will only ever kill a process actually named
`llama-server` — anything else on the port is reported, never touched.

**The log** is at `~/Library/Logs/RosyBit/llama-server.log`, truncated on each
start. **Open Log** in the menu opens it.

**Battery.** Nothing polls. Liveness comes from the child process handle,
readiness from watching the server's own startup output, and `/health` is only
touched when you actually open the menu and the model is still loading. Waking
a fanless machine every few seconds to poll is exactly what quietly drains it.

[#21273]: https://github.com/ggml-org/llama.cpp/pull/21273
[#21636]: https://github.com/ggml-org/llama.cpp/pull/21636
