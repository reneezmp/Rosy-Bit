# V1 verification and manual test checklist

Protocol-level regressions run automatically with `swift test`; they cover the
loopback proxy and its restart/collision paths, chunked requests and responses,
HTTP 204/304, and HEAD. Everything below needs the real app, model, or target
Mac and therefore remains a manual checklist. It is ordered so a failure early
on explains failures later.

This file is the complete pass. The shorter list of checks that have **never
been run yet** — new work whose machine nobody has sat in front of, and the
questions this project is still carrying — is in
[`PENDING-TESTS.md`](PENDING-TESTS.md). An item that has never once passed is a
different thing from one that wants re-running, and keeping them apart stops
the first from hiding inside the second.

## Current automated and V1.1 release evidence — 2026-08-31

- `swift test`: **89 tests, 0 failures**; the idempotent Core Audio write check
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
- DeepSeek cloud inference and its redacted, memory-only Insights records were
  confirmed against the live service.

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

- [ ] ⌘, opens Settings, and only Settings — no second, blank window opens
      alongside it
- [ ] Closing Settings leaves no other window behind; reopening with ⌘, or
      from the menu shows the same, populated window every time
- [ ] **⌘V pastes into the DeepSeek/Kagi key field.** Call this one out: the
      app's Edit menu is hand-built rather than supplied by a framework, so a
      regression here silently breaks pasting a key with no error shown
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

## 7. Optional cloud model

- [ ] **Model → Cloud Model…** opens a small window with DeepSeek and Custom
      Provider choices
- [ ] A DeepSeek key survives relaunch through Keychain while the field itself
      remains blank and says a key is saved
- [ ] Saving DeepSeek stops the local server and streamed Ask/chat answers work
- [ ] Explicit dictionary requests still show the local source entry before the
      remote model's gloss; current-volume questions still use Core Audio
- [ ] A wrong API key or provider error shows the provider's useful error text
- [ ] A custom base URL ending in `/v1` reaches `/v1/chat/completions`; a complete
      chat-completions URL is left unchanged
- [ ] HTTP custom endpoints are refused; HTTPS endpoints that need no key work
      with the key field empty
- [ ] Choosing an installed model starts Rosy's local server and checks that
      model in the menu without deleting the saved cloud profile
- [ ] Installing another local model while cloud is selected does not switch
      inference away from cloud
- [ ] Forget Cloud Model removes its configuration and Keychain credential
- [ ] Direct cloud requests appear in memory-only Insights with provider status,
      prompt, streamed response/tool call, tokens, and duration
- [ ] **Inspect response** on a cloud-backed chat answer opens its correlated
      record; a tool-backed answer selects the newer grounded follow-up
- [ ] Neither the Keychain credential nor an Authorization header appears in
      any cloud Insights tab
- [ ] When DeepSeek leaks its `<｜DSML｜>` tool-call markup as plain text
      (roughly one turn in ten — repeat a tool-triggering DeepSeek question
      until it happens), Rosy shows the plain-language notice instead of the
      raw markup, and the complete raw reply still reaches Insights unedited

---

## 8. Skills

- [ ] **Skills** appears immediately below **Model**, with nine independent
      checked rows and no bulk-disable item
- [ ] Both choices persist across relaunch and affect local and cloud chats
- [ ] Disabling Dictionary removes its schema and deterministic lookup route;
      an ordinary definition question no longer opens a dictionary entry
- [ ] Disabling Volume Control removes its schema and blocks exact get, set,
      mute, and unmute routes without changing system volume
- [ ] Calculator handles `2 + 3 * 4`, `15% of 80`, `500 mL to liters`, and
      `32 °F to °C`; unsupported syntax produces an error without inference
- [ ] Battery & System reports plausible battery/charging, power-source,
      startup-disk, and installed-memory values on both Macs
- [ ] The first timer requests notification permission once; `Set a tea timer
      for 10 seconds` rings, survives app relaunch, appears in `Show my timers`,
      and can be cancelled by name
- [ ] Disabling Timers blocks creation/list/cancellation but does not silently
      cancel a notification already scheduled with macOS
- [ ] `Open Safari`, `Quit Safari`, `Open my Downloads folder`, and `Reveal
      ~/Desktop/test.txt in Finder` execute only as exact one-line commands
- [ ] File Search returns no more than twelve existing Spotlight paths and does
      not treat query punctuation as shell syntax
- [ ] The first Reminders command requests native permission; create, list,
      complete, and delete work without a model confirmation turn
- [ ] With one skill enabled, Insights shows exactly that one tool schema
- [ ] With all nine skills disabled, Insights contains neither `tools` nor
      `tool_choice`
- [ ] Changing a skill while a local model is running refreshes the stable
      prefix before the next request
- [ ] **Skills → Tool Routing** presents radio-style Guided / Model-led choices;
      selecting either unticks the other and persists across relaunch
- [ ] Guided keeps state-changing schemas out of the prompt; Model-led adds
      only action schemas whose parent skills are enabled
- [ ] An unmeasured local model receives no Guided tools but receives enabled
      tools after explicit Model-led selection
- [ ] Model-led rejects volume outside 0–100, boolean numeric values, timers
      beyond seven days, unknown Finder folders, malformed due dates, and extra
      JSON fields before native state changes
- [ ] When Rosy speaks before reaching for a tool ("Let me look that up…"), the
      retrieved block that follows (dictionary entry, search results) starts
      its own Markdown heading on a new line rather than running into that
      sentence

### Tool-call chaining and the per-answer limit

Needs Web Search enabled with a saved Kagi key (see below) and Model-led
routing selected, since Guided cannot chain by design.

- [ ] **Settings → Tool Calls** shows a "Limit per answer" stepper from 1 to
      8, defaulting to 3, with copy explaining chaining and its cost
- [ ] With the limit at 3 or higher, "Search the web for the current Kagi
      status page and tell me what the top result says" produces two tool
      calls in one answer — a search, then a fetch of the most promising
      result — visible as two entries in Insights for the same reply
- [ ] The same request under **Guided** routing still stops after exactly one
      tool call regardless of the Settings value, and answers from the search
      results alone rather than also fetching a page
- [ ] Setting the limit to 1 and repeating the chaining request under
      Model-led stops Rosy after the first call; the second half of the
      request is answered from whatever the first call returned, not left
      hanging
- [ ] After the first tool call in a chain, the replayed assistant turn keeps
      whatever the model said before calling the tool — check Insights' Request
      tab for that turn's `content`, which must not be null when the model
      actually wrote something
- [ ] A request likely to chain more calls than the configured limit allows
      (for example asking Model-led to search three different topics with the
      limit at 2) still produces a valid, complete assistant reply — Rosy
      answers with what she has rather than erroring
- [ ] Insights' Request tab on that reply shows a `tool_calls` entry for the
      refused call paired with a `tool` reply stating it was not run and why,
      confirming the replayed transcript is well-formed rather than missing a
      reply
- [ ] Raising the limit to 8 and deliberately provoking a long chain does not
      hang the UI; each additional call still streams and appends normally
- [ ] With Web Search enabled and the limit above 1, Settings' warning about
      extra calls costing another generation and possibly another billed Kagi
      request is visible before triggering a chain, not only after

### Web Search (Kagi) — needs a real API key and network

Everything below needs an actual Kagi account and a live connection; none of
it can be faked with a mock, because the point is confirming Rosy's own
validation against Kagi's real v1 API rather than a description of it.

- [ ] With no Kagi key saved, the model receives no `web_search` or
      `web_fetch` schema even with the skill switched on
- [ ] Settings → **Web Search** accepts a real token, shows "Saved in
      Keychain" afterwards, and the field itself never redisplays the value
- [ ] **Remove** deletes the Keychain entry and the schema disappears again
      without a key, even with the skill left on
- [ ] "Search the web for the current Kagi status page" returns real titles,
      URLs, and snippets, displayed with working links beside the model's
      answer
- [ ] Search a term Kagi is likely to bold in its own snippets (a distinctive
      word from the query) and confirm no `<b>`, `<strong>`, or other HTML tag
      is visible in the displayed title or snippet — only the plain matched
      word
- [ ] "Summarise https://kagi.com" (or another real page) returns Markdown
      text via Extract rather than a summary invented from the URL alone
- [ ] An invalid or revoked key produces Kagi's HTTP 401/403 message rather
      than a generic failure
- [ ] A key with no remaining credit surfaces Kagi's HTTP 402 message
- [ ] Disabling Web Search mid-session blocks both tools and both
      deterministic routes without clearing the saved key
- [ ] Insights contains no Kagi request at all—the call goes straight out
      over HTTPS rather than through the recording proxy—while the grounded
      follow-up to the model appears there as usual, key and Authorization
      header nowhere in it
- [ ] A page that contains text such as "ignore previous instructions"
      reaches the model only inside the BEGIN/END UNTRUSTED WEB CONTENT
      fence, and the final answer does not comply with it
- [ ] Raising **Results per search** and **Page text kept** in Settings
      changes what Rosy requests and retains, confirmed against the actual
      response sizes
- [ ] Airplane Mode or a firewalled Kagi host produces the plain "could not
      reach Kagi" message instead of a hang or a retry

---

## 9. Apple Intelligence as a local model

Only reachable on Apple Silicon running macOS 26 or later with Apple
Intelligence switched on, so on Rosy this whole section is section 9.4 alone.

**Already verified on the M4, no need to repeat:** the framework reports
`available`; a streamed answer arrived in 2.66 s to first token; both slices of
the universal bundle carry `LC_LOAD_WEAK_DYLIB` for FoundationModels.

### 9.1 It appears, and only where it should

- [ ] **Model** submenu lists **Apple Intelligence — on-device** below the GGUF
      files and above **Cloud Models**, enabled and unchecked
- [ ] Its tooltip reads "Answers on this Mac, with no llama-server and no
      network."
- [ ] Turn Apple Intelligence off in **macOS**'s System Settings — Apple's app,
      not Rosy's ⌘, window; Rosy has no switch of her own and needs none — then
      reopen the menu. The row is still there but **greyed out**, with "Turn
      Apple Intelligence on in macOS System Settings." as its tooltip. Turn it
      back on before continuing

### 9.2 Selecting it

- [ ] Clicking it moves the checkmark: the GGUF row and the Cloud Models row
      both clear
- [ ] The status line at the top of the menu reads
      `☀ Apple Intelligence — on-device`
- [ ] llama-server stops — `pgrep -lf llama-server` is empty and the menu offers
      **Start Server**
- [ ] `curl -s http://127.0.0.1:1338/health` is refused. This is the documented
      trade, not a fault: FoundationModels is an in-process framework, so there
      is no endpoint to hand other apps while it is selected
- [ ] Quit and relaunch: still selected, and llama-server does **not** start

### 9.3 It answers

- [ ] Ask bar (⌥Space) streams an answer. Expect it to arrive in a few large
      jumps rather than token by token — the framework batches, and three
      chunks for one sentence is normal
- [ ] The metrics footer shows a time to first token; tokens and tok/s appear on
      macOS 27 and are blank on macOS 26, which publishes no usage
- [ ] Chat window: a second turn clearly has the first turn's context
- [ ] Cancelling mid-answer stops it and frees the machine
- [ ] Deterministic skills still route — `define plinth` shows the dictionary
      entry, then a gloss; a volume question still reads Core Audio
- [ ] An explicit web search still shows the results block, then a grounded
      answer. (Costs a real Kagi call)
- [ ] Paste a very long transcript until it overflows: the error names real
      token counts on macOS 27, and says "start a new chat" on macOS 26
- [ ] Selecting a GGUF again starts llama-server and moves the checkmark back

### 9.4 Tool calling through the bridge

Apple's model calls tools natively; Rosy's schemas are translated into its shape
at runtime. Verified outside the app that a dynamically-built tool is invoked
with correct arguments — `define {"term": "plinth"}` and
`volume_set {"action": "set", "level": 30}`, the enum and the bounded integer
both intact. What remains is confirming it inside Rosy, where the arguments meet
the real validators.

- [ ] "Set the volume to 100%" changes the volume rather than reporting it.
      This is the case the on-device descriptions exist for: on the shared
      wording it picked the read-only getter and then described a level it had
      not set
- [ ] "How loud is the Mac?" still *reads* rather than setting — the sharpened
      read-tool wording must not have pushed it the other way
- [ ] "Set an alarm for 6:37" reaches Reminders with a due date, not a timer.
      Rosy has no alarm of her own; the on-device wording is the only place
      that says so
- [ ] "Open Safari" opens it rather than looking up whether it is installed
- [ ] Ask something that needs a lookup without phrasing it as a command —
      "what does plinth mean?" rather than "define plinth", so the deterministic
      route does **not** fire and the model has to choose the tool itself. The
      dictionary entry appears, then the gloss
- [ ] "What is my battery at?" reaches Battery & System without an explicit
      command
- [ ] In **Model-led** routing, "set the volume to 30%" actually changes the
      volume, and the level it sets is the one you asked for
- [ ] The same question with **Volume Control** switched off in Skills does not
      change the volume, and the model is not offered the tool at all
- [ ] With Web Search **on** and a key saved, a question needing the web reaches
      Kagi. With it off, it does not — and Rosy says so rather than pretending
- [ ] Turn every skill off: the model answers from its own knowledge, with no
      tool block and no errors
- [ ] **The budget holds.** In Guided routing only one tool runs per answer; in
      Model-led, at most the **Settings → Tool Calls** limit. Ask something that
      invites a chain and watch it stop — the refusal is worded the same as on
      the HTTP path, telling the model to answer with what it has
- [ ] An argument the model gets wrong — an out-of-range volume, a malformed
      term — is refused by Rosy's own validator, not accepted because Apple's
      schema let it through. The guides steer the model; they are not the guard
- [ ] Cancelling mid-answer stops a tool chain as well as the prose

### 9.5 Insights sees it

FoundationModels never crosses the recording proxy, so the call is described
into Insights by hand — the same thing the cloud client already does, and the
reason Insights stayed one product rather than two.

- [ ] After an on-device answer, Insights gains a row: method **CALL**, path
      **apple-intelligence/on-device**, a green 200, and a real duration
- [ ] **Prompt** tab shows the conversation, system prompt included
- [ ] **Request** tab carries `"transport": "in-process (FoundationModels) —
      nothing left this Mac"`, so nothing here reads as network traffic
- [ ] **Response** tab shows each tool call above the answer, with its
      arguments and the observation Rosy returned. These are the calls the
      framework ran out of Rosy's sight, so this is the only place they can be
      inspected
- [ ] The same holds on a **cloud** answer that both speaks and calls a tool:
      the call is listed above the prose rather than hidden behind it
- [ ] **Params** shows Model `apple-on-device`, the temperature, and on
      macOS 27 a token pair. On macOS 26 the tokens are absent, not zero
- [ ] **Inspect response** on an on-device chat answer selects its record
- [ ] A failed answer — force a context overflow — still leaves a row, with a
      500 and the error text rather than no trace at all
- [ ] `defaults write com.rosybit.app insightsEnabled -bool false`, relaunch:
      no rows are recorded and answers still work

### 9.6 Settings stop lying about which knobs work

Every control in **Settings → Model** and **Settings → Performance** is a
`llama-server` command-line flag, and they used to stay editable while inference
was going somewhere that never reads them.

- [ ] With Apple Intelligence selected, open Settings: a note at the top says
      the local server's settings are inactive and that its model manages its
      own context window
- [ ] **Context size**, **Cache precision**, **Flash attention**, **Threads**,
      **Parallel slots**, **Conversation cache**, and **Cache checkpoint** are
      all greyed out and cannot be changed
- [ ] **Temperature** stays live — it is the one sampling control every runtime
      honours, including Apple's
- [ ] Top-k, Top-p, repetition penalty, presence penalty and **Reset to the
      model card** are greyed: those are llama.cpp sampler flags and nothing else
- [ ] Select a cloud profile: the same controls are greyed, with a note naming
      the provider as the one deciding context and cost
- [ ] Select a GGUF again: everything becomes editable, and a value changed
      before the switch was not silently lost

### 9.7 On Rosy — the one that actually matters

The app is weak-linked against a framework Ventura has never heard of. If that
is wrong, Rosy does not launch at all.

- [ ] Copy the universal bundle across and launch it on **native Ventura 13**:
      it starts, the menu bar icon appears, the endpoint serves
- [ ] The **Model** submenu has no Apple row at all — absent, not greyed
- [ ] Same on OCLP Sequoia
- [ ] Nothing else in the app behaves differently from before

---

## 10. Context Budget

What Rosy's own requests cost before the question is typed. A **token** count
needs a local GGUF selected and the server running; on any other source the row
is still there, saying what it can say instead.

**A note on the numbers I quoted while building this.** The 45-token system
prompt and 12-token chat template were measured against your real config. The
654-token tool schema was **not** — it used nine stand-in schemas of realistic
shape, because I had no way to extract Rosy's actual ones from outside the app.
So treat 711 as the right order of magnitude, not the number you should expect
to see. The first real reading is this checklist's job.

### 10.1 It reads correctly

- [ ] Menu shows a short **Context Budget** row between **Skills** and
      **Start/Stop Server** — the figure is inside, not on the row, because with
      its denominator and percentage it is far too long to sit in a menu
- [ ] Its submenu opens with **Total — N tokens of 32,768 (P%)**, then a
      separator, then **System Prompt**, **Tool Schema**, **Chat Template**
- [ ] The three add up to the total **exactly**. They are measured by
      difference precisely so they do; if they do not, the decomposition is
      wrong

Cross-check one line by hand. This asks llama-server what an empty conversation
costs — no system prompt, no tools — which is exactly the **Chat Template**
figure:

```bash
curl -s -X POST http://127.0.0.1:11337/apply-template \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":""}]}' \
  | python3 -c 'import sys,json;print(json.dumps({"content":json.load(sys.stdin)["prompt"]}))' \
  | curl -s -X POST http://127.0.0.1:11337/tokenize \
    -H 'Content-Type: application/json' -d @- \
  | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["tokens"]))'
```

- [ ] It agrees with the **Chat Template** line to the token, and is a small
      number — around a dozen

### 10.2 It changes when the prefix changes

- [ ] Turn a skill off, reopen the menu: **Tool Schema** and the total both fall
- [ ] Switch **Tool Routing** between Guided and Model-led: the number changes,
      because Model-led advertises the extra action schemas
- [ ] `defaults write com.rosybit.app systemPrompt "Hi."`, relaunch: the
      **System Prompt** line drops sharply. Put yours back afterwards
- [ ] Switch models: the count is remeasured with the new model's own tokeniser
      rather than carried over

### 10.3 It says what it can, where it cannot count tokens

The row is always present; only its submenu changes. Hiding it outright made
"did this ship?" unanswerable from the one place it lives.

- [ ] **Stop Server**: the submenu reads "Start the server to measure."
- [ ] Select a cloud profile: "Counted by the provider, not here."
- [ ] Both carry a tooltip explaining that a count needs the tokeniser of a
      loaded model
- [ ] Select **Apple Intelligence** and open **Context Budget**: it says
      "Measuring…" for about a second, then shows **Total**, **System Prompt**,
      **Tool Schema** and **Model framing** in real tokens
- [ ] The three parts sum to the total exactly
- [ ] There is **no** "of N" and no percentage. Apple publishes no context
      length, so there is no denominator and inventing one would be a lie
- [ ] Reopen it: the numbers are instant. It is cached until the prefix changes
- [ ] Toggle a skill and reopen: it measures again and **Tool Schema** moves
- [ ] Before any question has been asked, there is **no** "Last request" line
- [ ] Ask one, then reopen: **Last request — N input tokens** appears. Apple's
      own count of the whole input, so it is larger than Total and is not a
      share of anything
- [ ] It is worth watching with every skill on: thirteen bridged tools is a
      real amount of prefix, and this is now measurable rather than guessed at

#### The cost, which is the point of the design

Measuring runs the model three times. Every other refresh in this app is free,
so this one waits to be asked for rather than firing when the menu bar opens.

- [ ] Open the menu bar and go straight to **Quit** without touching Context
      Budget: nothing measures, no inference happens
- [ ] Only opening the **Context Budget** submenu starts it
- [ ] The footer says "Opening this measures the prefix — it runs the model."
      before the first measurement, and afterwards explains how it was taken
- [ ] On macOS 26 it never measures at all: the submenu shows characters and
      says Apple publishes no tokeniser. `usage` does not exist before 27, and
      an estimate would be wrong by a wide margin on emoji-carrying text

### 10.4 The two I trust least

- [ ] **It fills in while the menu is open.** Change a skill, then open the menu:
      it may briefly say "measuring…" and should then replace itself with the
      number **without closing and reopening the menu**. This is the only place
      in the app that redraws a menu that is already on screen. Whether the
      budget submenu is open is tracked by its own `menuWillOpen`/`menuDidClose`
      rather than inferred: the measurement lands with `isMeasuring` already
      false and every row disabled, so neither that flag nor `highlightedItem`
      can answer at the one moment it matters, and the fallback path rebuilds
      the whole menu out from under the reader
- [ ] **It stays out of Insights.** Note the `Insights… (N)` count, open and
      close the Model menu several times, and check N has **not** climbed. The
      measurement deliberately talks to llama-server on the upstream port so it
      bypasses the proxy; if that is wrong, eight rows appear per menu open and
      bury the requests Insights exists for

---

## 11. Still outstanding from earlier

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

## 12. Worth measuring: quantised KV cache

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

## 13. Two slots — does the affinity actually happen?

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

## 14. Unmeasured, if you are curious

- [ ] Whether slots multiply KV memory. Set `parallelSlots` to 4, restart,
      then `ps -o rss= -p $(lsof -ti tcp:11337 -sTCP:LISTEN)`. About 1.3 GB
      means shared; about 4 GB means not. Nothing depends on the answer at one
      slot, but the docs currently say it is unverified
