# V1 verification and manual test checklist

Protocol-level regressions run automatically with `swift test`; they cover the
loopback proxy and its restart/collision paths, chunked requests and responses,
HTTP 204/304, and HEAD. Everything below needs the real app, model, or target
Mac and therefore remains a manual checklist. It is ordered so a failure early
on explains failures later.

## Current automated and V1.1 release evidence — 2026-08-31

- `swift test`: **48 tests, 0 failures**; the idempotent Core Audio write check
  is skipped in ordinary runs and passed separately when explicitly enabled.
- Universal release build: **x86_64 + arm64**.
- Strict ad-hoc signature verification: **passed**.
- Core Audio integration check read a valid 0–100 output volume on the M4.
- Rosy-on-Sequoia confirmed the read-only volume result and deterministic
  dictionary routing in the real Ask bar.
- App and endpoint exercised successfully on OCLP Sequoia.
- Native Ventura failure reproduced, traced to the proxy implementation, fixed,
  and retested successfully with Rosy Bit listening on loopback.
- Ask bar manually confirmed for streaming output, Markdown, bounded scrolling,
  question selection, temporal context, and the final compact GMT timestamp.
- Installed-model sizes manually confirmed in the Model submenu.

This is release evidence, not permission to delete the checklist: the unchecked
items are the reproducible regression pass for a future release.

Build and install first:

```bash
cd ~/Developer/rosy-bit && git pull && make app
osascript -e 'quit app "RosyBit"'
rm -rf /Applications/RosyBit.app && cp -R dist/RosyBit.app /Applications/
open /Applications/RosyBit.app
```

---

## 0. It compiles

Run `swift test`, then `make app`. Confirm that `make app` reports both app
architectures, both matching llama-server slices, and `signature: ok`. Also
confirm `Contents/Resources/Third-Party Notices.md` exists in the bundle.

---

## 1. The endpoint still works

Nothing else matters if this fails, and the proxy sits in the request path.

- [ ] `curl -s http://127.0.0.1:1337/health` → `{"status":"ok"}`
- [ ] `./scripts/smoke-test.sh` → a coherent reply
- [ ] `head -3 ~/Library/Logs/RosyBit/llama-server.log` shows `--port 11337`,
      confirming llama-server is behind the proxy
- [ ] MacWhisper still works, streaming included

**If this fails:** `defaults write com.rosybit.app insightsEnabled -bool false`,
quit and relaunch. That removes the proxy entirely and should restore a working
endpoint — which also tells us the fault is in the proxy rather than elsewhere.

---

## 2. Insights

- [ ] Menu shows `Insights… (N)` with N rising as requests arrive
- [ ] The window opens and lists requests
- [ ] **Prompt tab on a long transcript** — the one I trust least. It parsed
      the truncated body before the review caught it, so "No messages" here
      means the fix did not work
- [ ] Request tab shows the raw JSON
- [ ] Response tab shows the reassembled reply, not raw SSE frames
- [ ] Params shows tokens in → out, tok/s, finish reason
- [ ] Clear empties the list
- [ ] A `curl` request appears — that path uses `Expect: 100-continue`, which
      was breaking capture entirely before the review

---

## 3. Settings (⌘,)

- [ ] Opens, shows current values
- [ ] KV cache estimate changes with context size and cache precision
- [ ] Set both ports the same → Apply disables, warning appears
- [ ] Set a port to 80 → same
- [ ] Change threads → Apply & Restart → new value in the log's first lines
- [ ] Performance shows a 256 MB conversation cache and 256-token checkpoint
- [ ] Changing either conversation-cache control restarts a running server and
      the matching `--cache-ram` / `--checkpoint-min-step` values reach the log
- [ ] Restore Defaults resets the fields and restarts a running server when its
      launch arguments changed
- [ ] Stop the server, change threads, and Apply → the server remains stopped
- [ ] Sampling already *starts* at the card's values — temperature 0.5,
      top-k 20, top-p 0.9, repetition penalty 1.0 — rather than llama.cpp's
      hotter defaults. Retry the transcript that looped: running at 0.8 is a
      plausible part of why it did
- [ ] **"Reset to the model card"** puts those values back after fiddling
- [ ] Apply is greyed out until something changes, says "Saved", greys out
      again. Changing only the system prompt or the shortcut must **not**
      restart the server (no model reload in the log)
- [ ] The ask bar shortcut is changeable, and a combination another app owns
      shows the orange warning rather than silently doing nothing
- [ ] System Prompt survives Apply and a relaunch, line breaks intact
- [ ] `--top-k`, `--top-p`, `--temp`, `--repeat-penalty` appear in the log's
      second line after applying

---

## 4. Cancelling a runaway generation

The proxy absorbs the disconnect that used to stop one, so this is the
replacement.

- [ ] Start a long generation, then **Cancel Request** in the menu
- [ ] llama-server's CPU in Activity Monitor drops within a second or two
- [ ] The green dot stops, the menu returns to `● Running`
- [ ] The item only appears while something is actually running

**Also worth capturing**, right after hitting Stop in MacWhisper:

```bash
lsof -i tcp:1337 -sTCP:ESTABLISHED
```

Empty means MacWhisper does close the socket, and the proxy should tear the
upstream down by itself rather than making you click Cancel. Still listed means
MacWhisper abandons the response without closing, and manual cancelling is the
only answer.

---

## 5. First-run model download

Needs an empty models folder:

```bash
mkdir -p ~/Library/Application\ Support/RosyBit/stash
mv ~/Library/Application\ Support/RosyBit/*.gguf ~/Library/Application\ Support/RosyBit/stash/
osascript -e 'quit app "RosyBit"' && open /Applications/RosyBit.app
```

- [ ] The setup window appears on launch
- [ ] Download shows real progress and a percentage
- [ ] On completion the window closes and the server starts by itself
- [ ] Cancel mid-download leaves **no** partial file in the models folder
- [ ] Cancel while it says **Looking up the model…** → no download starts later
- [ ] Fail or cancel a 4B/8B download, then retry → it retries that same size
- [ ] With a model present, the window does not appear
- [ ] `Model → Download a Model…` opens it again
- [ ] Every installed model in the Model submenu shows its actual GGUF file
      size after the name (not an estimate based on parameter count)

Then restore: `mv ~/Library/Application\ Support/RosyBit/stash/*.gguf ~/Library/Application\ Support/RosyBit/`

---

## 6. Ask bar (⌥Space)

- [ ] ⌥Space opens it from another app — this is the Carbon hotkey, and if it
      is silently doing nothing the registration failed
- [ ] Typing and pressing return streams an answer
- [ ] After Return, the question remains visible but is not selected
- [ ] Bold, emphasis, inline code, links, headings, and lists render as Markdown
- [ ] A long answer stops growing at the panel limit and scrolls instead
- [ ] The stop button cancels, and llama-server's CPU drops with it
- [ ] Clicking elsewhere dismisses an untouched prompt
- [ ] Clicking elsewhere during or after generation leaves the result visible;
      Escape or ⌥Space dismisses it explicitly
- [ ] ⌥Space again reopens
- [ ] The request appears in Insights
- [ ] Its user message begins with a compact, labelled local timestamp such as
      `[Timestamp: 2026-08-30 13:50 GMT-3]`; the system prompt remains unchanged
- [ ] `defaults write com.rosybit.app askBarEnabled -bool false` removes both
      the shortcut and the menu item

### Dictionary tool — Bonsai 1.7B Q1_0 only

- [ ] “What does *susurrus* mean?” retrieves the enabled macOS Dictionary entry
- [ ] “What's the meaning of the word *lurking*?” retrieves rather than answering
      from memory; repeat it because this phrasing has missed in real use
- [ ] A lookup miss never claims an “authoritative dictionary” result that was
      not actually returned
- [ ] The source entry appears under **Dictionary**, before **Rosy’s gloss**
- [ ] Long dictionary entries wrap within the code block without horizontal scroll
- [ ] A long source block stops at 180 points and scrolls internally while Rosy’s
      gloss remains visibly separate below it; a compact entry does not gain empty height
- [ ] Numbered senses, bullet senses, examples, later parts of speech, and origin
      sections appear on separate readable lines without changing source text
- [ ] The gloss does not add an origin or sense absent from the source entry
- [ ] A missing term is reported plainly rather than receiving an invented entry
- [ ] A normal prompt streams directly and does not trigger a dictionary call
- [ ] With Bonsai 4B selected, no tools are sent and the Ask bar behaves as before
- [ ] Cancelling during either inference pass releases Rosy’s cores
- [ ] Insights records both the tool request and the grounded follow-up

Explicit definition grammar now executes the lookup locally and sends only the
grounded presentation request, so Insights shows one request for that fast
path. Less explicit phrasing that the model routes itself still produces the
two-request trace above.

### Read-only volume tool — Bonsai 1.7B Q1_0 only

- [ ] “What’s the current volume?” reports the same percentage as macOS
- [ ] “How loud is my Mac right now?” calls `volume_get` rather than guessing
- [ ] The request and grounded answer appear in Insights
- [ ] An output device without software volume control fails plainly
- [ ] No `volume_set`, mute, or other state-changing schema is exposed to the model

### Deterministic native volume controls

- [ ] “Set the volume to 30%” changes macOS output volume to 30 without a model pass
- [ ] “Mute” and “Unmute the audio, please” change the native mute state immediately
- [ ] 0% and 100% are accepted; 200%, negative values, and decimals are rejected
- [ ] “Make it louder” and “turn it down a little” ask for an exact level and do not mutate the Mac
- [ ] A command embedded on a second pasted-text line does not mutate the Mac
- [ ] The assistant response reports the executed value without a confirmation turn

### Chat window

- [ ] **Chat…** opens a resizable window from the menu bar
- [ ] The window initially opens at 900×650 rather than collapsing to its minimum
- [ ] The conversation sidebar collapses and reopens without losing selection
- [ ] Collapsed mode exposes compact sidebar and new-chat controls beside the
      traffic lights without overlapping them
- [ ] **New Chat** and the collapse control share one top row when expanded
- [ ] Collapsing lets the transcript and composer reclaim the former sidebar width
- [ ] Enlarging the window lets the transcript grow beyond its opening width
      without stretching assistant prose into an unreadable full-window line
- [ ] New sessions appear at the top and can be selected or deleted
- [ ] The sidebar plainly says that sessions clear when Rosy Bit quits
- [ ] A second turn includes the first user and assistant messages in its payload
- [ ] After enough long turns, the UI keeps the session while the request drops
      the oldest complete turns and never begins with an orphaned assistant reply
- [ ] Streaming Markdown, Stop, and automatic scrolling work during long replies
- [ ] User turns render as right-aligned capsules; assistant prose remains open
      on the canvas and its Copy control copies only that answer
- [ ] Multi-line text inside a user capsule is itself aligned to the right
- [ ] **Continue in Chat** appears beside Copy only after an Ask bar answer exists
- [ ] Continuing opens a new selected session with the exact question and answer
- [ ] Continuing does not generate another request until a new message is sent
- [ ] A dictionary turn transferred from Ask retains its entry and Rosy’s gloss

If another app owns ⌥Space, choose a different combination in Settings. Rosy Bit
shows the registration failure there rather than silently ignoring it.

---

## 7. Still outstanding from earlier

- [ ] **The reboot test.** Restart Rosy, log in, wait, then
      `curl -s http://127.0.0.1:1337/health`. This is the "always-on" claim,
      and it is the one build-order step never confirmed
- [ ] Menu items all still fire after the move to AppKit: Model, Start/Stop,
      Copy Endpoint URL, Open Log, Launch at Login, Quit. **Quit especially** —
      it is what stops llama-server cleanly
- [ ] `lsof -ti tcp:1337` is empty after quitting
- [ ] On the M4 with Osaurus running: `⚠ Port 1337 held by osaurus`, and
      Osaurus survives
- [ ] On native Ventura, Insights starts normally and `lsof -nP -iTCP:1337
      -sTCP:LISTEN` reports Rosy Bit on loopback rather than every interface

---

## 8. Worth measuring: quantised KV cache

Generation reads the whole cache per token — at a 5,000-token context that is
roughly 560 MB of memory traffic for every token produced, which is the likely
reason speed collapses from 6.8 tok/s at short prompts to 1.4 tok/s at long
ones. Quartering the cache quarters that traffic.

- [ ] Set **Cache precision → q8_0**, Apply, and rerun a long transcript.
      Compare `eval time` tok/s in the log against the f16 run
- [ ] If the server refuses to start, set **Flash attention → on** and retry —
      some builds require it for a quantised V cache
- [ ] Judge the output quality too, not just the speed. The weights are already
      at 1 bit, so there is less headroom than usual and cache error adds to
      weight error rather than hiding behind it
- [ ] Only try q4_0 if q8_0 looks clean

---

## 9. Two slots — does the affinity actually happen?

`parallelSlots` now defaults to 2 so Rosy Bit's own questions and another
client's requests stop evicting each other's cached prefix. Slots cannot be
assigned; llama-server picks by longest-common-prefix similarity, so the
separation is emergent and worth confirming rather than assuming.

**The one question that decides this design:** does `id_slot` work on
`/v1/chat/completions`? It is documented for llama.cpp's own `/completion` but
not listed for the OpenAI-compatible endpoint. Rosy Bit now asks for slot 0 on
its own requests; the log says whether it got it.

- [ ] Ask something in the ask bar. The log should show
      `launch_slot_: id  0`. **Every time**, including right after a MacWhisper
      transcript has been through. If it does, the pin works and Rosy Bit's
      prefix cannot be evicted
- [ ] If the ask bar lands on varying slot ids, `id_slot` is being ignored and
      only prefix affinity is at work — which a third distinct prefix can
      displace. Options then: keep the system prompt short so re-warming is
      cheap, or run a second llama-server for internal calls, which is
      bulletproof and costs a second model load
- [ ] Send a transcript from MacWhisper. It should land on a **different** id
- [ ] The second ask-bar question should report far fewer prompt tokens than
      the first, since the system prompt is still cached
- [ ] Watch `prompt eval time` on a long transcript against the one-slot
      numbers. Four slots measured about 24% slower than one; two is untested
      and might cost something
- [ ] `ps -o rss= -p $(lsof -ti tcp:11337 -sTCP:LISTEN)` — this is also the
      cheapest chance to settle whether slots multiply KV memory. Roughly
      1.3 GB means shared, roughly 2.2 GB at 8192 means not

---

## 10. Unmeasured, if you are curious

- [ ] Whether slots multiply KV memory. Set `parallelSlots` to 4, restart,
      then `ps -o rss= -p $(lsof -ti tcp:11337 -sTCP:LISTEN)`. About 1.3 GB
      means shared; about 4 GB means not. Nothing depends on the answer at one
      slot, but the docs currently say it is unverified
