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
git clone -b claude/rosy-bit-planning-90xr0a \
  https://github.com/reneezmp/Rosy-Bit.git ~/rosy-bit
cd ~/rosy-bit
```

### 1a. Get `llama-server`

```bash
./scripts/fetch-llama-server.sh x86_64
```

Expected:

```
llama.cpp b10684
trying https://github.com/ggml-org/llama.cpp/releases/download/b10684/llama-b10684-bin-macos-x64.tar.gz
installed vendor/x86_64/ (12M)
  minos: 13.0 — OK for macOS 13.0
```

**The Swift is not the risk here — the prebuilt binary is.** If it was compiled
against a newer SDK it will refuse to launch on Ventura, and the failure much
later looks like a Gatekeeper problem rather than what it is. The script runs
the check for you; to do it by hand:

```bash
otool -l vendor/x86_64/llama-server | grep -A3 LC_BUILD_VERSION
```

**If `minos` is above 13.0** the script refuses: it deletes the Intel payload
and exits non-zero rather than leave an unlaunchable binary for `make app` to
pick up. (`ALLOW_NEW_MINOS=1` overrides, if you want it anyway. A newer `minos`
on the *arm64* slice is only ever a warning — that slice never leaves the M4.)

Compile from source on Rosy instead. Slow on two cores, but straightforward —
and note you do **not** need PrismML's `prism` fork.
`Q1_0` was merged into upstream llama.cpp ([#21273], with the x86-optimized CPU
kernel in [#21636]); the fork is only needed for ternary `Q2_0`.

```bash
# Xcode 14 Command Line Tools + cmake
xcode-select --install
brew install cmake

git clone --depth 1 --branch b10684 https://github.com/ggml-org/llama.cpp ~/llama.cpp
cd ~/llama.cpp
cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=OFF \
  -DLLAMA_CURL=OFF
cmake --build build --config Release -j 2 --target llama-server

mkdir -p ~/rosy-bit/vendor/x86_64
cp build/bin/llama-server ~/rosy-bit/vendor/x86_64/
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

## Step 2 — build the app on the M4

```bash
git clone -b claude/rosy-bit-planning-90xr0a \
  https://github.com/reneezmp/Rosy-Bit.git ~/rosy-bit
cd ~/rosy-bit

./scripts/fetch-llama-server.sh     # both slices this time
make app
```

If Rosy needed a source build in step 1a, copy that binary over rather than
letting the script fetch a prebuilt one:

```bash
scp rosy:rosy-bit/vendor/x86_64/llama-server vendor/x86_64/
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
make run
```

> **Stop Osaurus first.** It also defaults to port 1337 — that is the entire
> point of choosing 1337 — so the two cannot run at the same time. Rosy Bit will
> notice and say `⚠ Port 1337 held by osaurus` rather than fighting it.

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
defaults write com.rosybit.app contextSize -int 4096
defaults write com.rosybit.app port -int 8080
killall RosyBit && open /Applications/RosyBit.app
```

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
