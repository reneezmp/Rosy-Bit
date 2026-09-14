# Pending tests

[`TESTING.md`](TESTING.md) is the full reproducible regression pass: everything
that should be checked before a release, whether or not it was checked today.
This file is narrower and more perishable. It is the list of things that are
**not verified right now** — work that has shipped into `Unreleased`, or a
question the project has been carrying, that no automated test can reach and
nobody has yet sat in front of the right Mac to confirm.

It exists because "needs a real machine" is otherwise indistinguishable from
"done". A checklist item that has never once passed is a different kind of
thing from one that passed last release and wants re-running, and merging the
two hides the first inside the second.

Each item says what to do, what a pass looks like, and what a failure would
mean. When one passes and becomes a standing regression check, move it into
`TESTING.md`. When the code it guards is gone, delete it.

---

## Needs a Mac with Apple Intelligence

Apple Silicon, macOS 26 or later, Apple Intelligence switched on — in practice
the M4. Rosy herself can never run any of these, and that is not a gap to be
closed: it is the machine this project exists for, and the on-device model is
the one feature written for somewhere else.

### 1. A multi-segment answer reaches Insights whole

`AppleFoundationModel.Result.text` accumulates the deltas it emitted rather
than taking the last cumulative snapshot, because a segment that begins after
a tool call does not continue the text before it. Assigning the snapshot left
the record holding only the closing half of an answer the reader saw in full.

- Select **Apple Intelligence — on-device**, with Dictionary on under Skills.
- Ask something that makes the model speak, call a tool, and then speak again:
  "look up *susurrus* and tell me whether it fits a fanless Mac."
- **Pass:** the Insights **Response** tab shows the tool call, then an `ANSWER`
  block containing *both* halves of the prose, separated by a blank line and
  matching what the chat window showed.
- **Fail:** the answer begins at the post-tool sentence. The accumulation has
  regressed to assignment.

`testAccumulatedDeltasReproduceTheWholeAnswerAcrossAToolCall` proves the
stitching arithmetic. It cannot prove the wiring, which is what this checks.

### 2. The budget fills in place while the menu is open

The same check as [`TESTING.md` §10.4](TESTING.md), and still the one to trust
least, because it is the only place in the app that redraws a menu already on
screen. Whether the budget submenu is open is now tracked by its own
`menuWillOpen` / `menuDidClose` rather than inferred from `isMeasuring` or
`highlightedItem`, both of which are false at the exact moment the measurement
lands.

- **Pass:** the number replaces "Measuring…" without closing and reopening the
  menu.
- **Fail:** it stays on "Measuring…" until the menu is reopened. The open-submenu
  tracking is wrong, or AppKit will not repaint a menu repopulated in place —
  which are different faults with different fixes, so find out which.

### 3. Reopening the menu bar mid-measurement does not restart the probe

Measuring the on-device prefix runs the model three times. It is the only
refresh in this app that costs inference, so throwing one away is not free.

- Open **Context Budget** on the Apple path, dismiss the menu while it still
  says "Measuring…", and reopen it immediately.
- **Pass:** it is either still measuring or already showing the number. Three
  fresh probes do not begin.
- **Fail:** the footer reverts to "Opening this measures the prefix — it runs
  the model." `settle` is cancelling work it was meant to keep.

### 4. macOS 26 never measures at all

`usage` does not exist before macOS 27, and an estimate would be wrong by a
wide margin on text carrying emoji.

- **Pass:** the submenu shows the system prompt in *characters* and says Apple
  publishes no tokeniser or context length. No inference happens.
- **Fail:** any token figure appears, or the model runs.

---

## Needs Rosy — 2017 Core m3, native Ventura and OCLP Sequoia

### 5. The on-device model is absent, and nothing else notices

FoundationModels is weak-linked so older systems launch exactly as before.

- **Pass:** no **Apple Intelligence** row in the Model menu at all — not greyed
  out, absent — and the app launches, serves `/v1`, and answers normally.
- **Fail:** a row appears, or the app fails to launch against a framework that
  is not there.

### 6. Context Budget still measures on the local path

The llama-server path renders four templates through `/apply-template` and
counts them with `/tokenize` on the upstream port, bypassing the proxy.

- **Pass:** real token figures, the three parts summing to the total exactly,
  and `Insights… (N)` **not** climbing when the menu is opened and closed.
- **Fail:** eight rows per menu open. The measurement is going through the
  proxy and burying the requests Insights exists for.

### 7. The reboot test

Standing since V1 and still never confirmed: restart, log in, wait, then
`curl -s http://127.0.0.1:1337/health`. It is the whole "always-on" claim.

---

## Open questions nobody has answered

Carried in prose in [`TOOL-CALLING.md`](TOOL-CALLING.md) and
[`ROADMAP.md`](ROADMAP.md). Registered here so they stop being findable only by
whoever remembers reading them.

- **Is Bonsai 4B's failure the model or its chat template?** 4B got the tool
  suite exactly backwards — no call on seventeen cases that wanted one, five
  false positives on cases that wanted none. `--jinja` reads the template baked
  into the GGUF, and the 4B file is a different build from a different upload.
  The check is cheap and belongs before anyone concludes anything about 4B.
- **Chained and parallel tool calls, and recovery from a tool that errors.**
  Only single-call turns have ever been measured. Model-led routing ships
  chaining on that untested basis, which is precisely why Guided stays pinned
  at one call and why the per-answer limit exists.
- **Is the +49% latency drift thermal?** Monotonic across three passes on
  identical work. Nobody has watched Rosy's clock speeds while the suite ran;
  a growing KV cache would look the same.
- **Do slots multiply KV memory?** `parallelSlots` defaults to 2 on a guess.
  `ps -o rss=` on the llama-server pid settles it.
- **8B has never been measured**, and given the 4B result nothing should be
  presumed about it either way.
