# What still needs testing

Everything below was written without a compiler and, unless noted, has never
run. Ordered so that a failure early on explains failures later — don't chase
item 12 while item 1 is broken.

Build and install first:

```bash
cd ~/Developer/rosy-bit && git pull && make app
osascript -e 'quit app "RosyBit"'
rm -rf /Applications/RosyBit.app && cp -R dist/RosyBit.app /Applications/
open /Applications/RosyBit.app
```

---

## 0. It compiles

The largest untested surface is `Network.framework` in `ProxyServer`, the
Carbon interop in `GlobalHotKey`, and `URLSession.bytes` in `ChatClient`.
Expect errors here before anything else.

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
- [ ] Restore Defaults resets the fields
- [ ] **"Use the values from Bonsai's model card"** sets temperature 0.5,
      top-k 20, top-p 0.9, repetition penalty 1.1. Apply, then retry the
      transcript that looped — running at llama.cpp's default 0.8 rather than
      the card's 0.5 is a plausible part of why it looped
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
- [ ] With a model present, the window does not appear
- [ ] `Model → Download a Model…` opens it again

Then restore: `mv ~/Library/Application\ Support/RosyBit/stash/*.gguf ~/Library/Application\ Support/RosyBit/`

---

## 6. Ask bar (⌥Space)

- [ ] ⌥Space opens it from another app — this is the Carbon hotkey, and if it
      is silently doing nothing the registration failed
- [ ] Typing and pressing return streams an answer
- [ ] The stop button cancels, and llama-server's CPU drops with it
- [ ] Clicking elsewhere dismisses it
- [ ] ⌥Space again reopens
- [ ] The request appears in Insights
- [ ] `defaults write com.rosybit.app askBarEnabled -bool false` removes both
      the shortcut and the menu item

If ⌥Space is taken by something else on your machine, the registration fails
silently — say so and it becomes configurable.

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

## 9. Unmeasured, if you are curious

- [ ] Whether slots multiply KV memory. Set `parallelSlots` to 4, restart,
      then `ps -o rss= -p $(lsof -ti tcp:11337 -sTCP:LISTEN)`. About 1.3 GB
      means shared; about 4 GB means not. Nothing depends on the answer at one
      slot, but the docs currently say it is unverified
