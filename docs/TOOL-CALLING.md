# Can a 1-bit model drive a tool loop?

The V1.1 tool layer is a substantial piece of work: structured requests, an
allowlist, validation, native execution, and observations returned to the model.
All of it assumes the model can emit a well-formed tool call in the first place.
Heavy quantisation is known to damage strict format adherence before it damages
prose, and Bonsai is quantised to one bit, so that assumption was worth an
afternoon rather than a rewrite.

The harness is [`scripts/tool-call-spike.py`](../scripts/tool-call-spike.py).

```bash
./scripts/tool-call-spike.py --repeat 3              # through the public port
./scripts/tool-call-spike.py --port 11337 --repeat 3 # straight to llama-server
```

The port differs by machine: Rosy serves on 1337, while the M4 serves on 1338
because Osaurus already holds 1337 there. `--port` is not optional guesswork.

## Result — the M4, 2026-08-30

**Bonsai 1.7B Q1_0, 26 cases, 3 passes, 78 requests, temperature 0.7.**

| Verdict | Count | Share |
| --- | --- | --- |
| PASS | 73 | 94% |
| MISSED — no call where one was wanted | 3 | 4% |
| WRONG-ARG — valid call, wrong value | 2 | 3% |
| MALFORMED JSON | **0** | 0% |
| Hallucinated tool name | **0** | 0% |
| False positive on a no-tool case | **0** | 0% |

Median latency 0.17 s, maximum 0.88 s. Rosy's own numbers are below, and they
are the ones that matter.

**The tool track is green.** llama-server exposes tool calling correctly through
the Bonsai chat template when launched with `--jinja`, and the failure modes are
not the ones that were feared.

### Through the proxy

The three passes above went straight to `llama-server`, bypassing Rosy Bit's own
proxy. A tool call is a response shape the proxy and `HTTPTrafficParser` had
never been given — `tool_calls` arrays and `finish_reason: "tool_calls"` — so
the suite was repeated against the public port.

Identical verdicts, identical median latency, nothing mangled. The recording
proxy needs no changes to carry tool traffic.

## What did not fail

Nothing in 78 requests produced unparseable arguments, invented a tool that was
not registered, or fired a tool on a prompt where none applied. The two
prompt-injection cases — an instruction planted inside a note to be summarised,
and one inside text to be translated — were both treated as data in all three
passes. That is one afternoon of evidence rather than a security guarantee, and
the case list should grow, but the shape of the result is encouraging: this
model does not appear eager to reach for tools it was not asked to use.

## What did fail, and why it matters more

### Well-formed and wrong

Asked to *"Set volume to 200"*, Bonsai answered `volume_set(level=20)` in two
passes of three. The value is the right type, inside the declared range, and
schema-valid. It is also not what was asked, and no amount of validation can
tell the difference: a range check sees 20 and is satisfied.

Asked to *"Set the volume to eleventy"*, she answered `volume_set(level=11)`.

This is the single most important finding of the spike, and it is not a bug to
be prompted away. When a request cannot be honoured, the model does not signal
failure — it produces something plausible and proceeds. The design consequence:

- **Read-only tools are safe on schema validation alone.** A wrong dictionary
  lookup costs a wrong definition and nothing else. `dictionary.lookup` can ship
  with validation and no confirmation step.
- **State-changing tools need the parsed intent shown before execution.** Not a
  yes/no dialog on every call, but the interpreted action visible and
  correctable: *"Set volume to 20%"* is something Renée can catch. `volume.set`
  should not fire silently on the model's arithmetic.

The roadmap already said read-only tools come before state-changing ones. This
is the measurement that explains why.

### Phrasing sensitivity

*"How loud is my Mac right now?"* produced no call in any of the three M4
passes, while *"What's the current volume?"* worked every time. On Rosy the same
prompt called the tool correctly, so this is a borderline case rather than a
hard gap in the description — the wording sits near the model's decision
boundary and falls either way depending on sampling.

Tool descriptions should still be written for the words people actually use, and
MISSED remains the benign failure: the model answers without the tool instead of
acting wrongly. But no conclusion about a specific phrase survives a single
pass, which is why the harness takes `--repeat` and why an early MISSED on
`susurrus` that never reproduced is not in the headline table.

## Result — Rosy, 2026-08-30

**Bonsai 1.7B Q1_0 on the 2017 fanless Core m3, one pass, 26 requests.**

| Verdict | Count | Share |
| --- | --- | --- |
| PASS | 25 | 96% |
| WRONG-ARG | 1 | 4% |
| MALFORMED, hallucinated, or false positive | **0** | 0% |

Median latency 4.13 s; 18.01 s on the first request and roughly 4 s on every one
after it.

The machine the project exists for runs the tool loop, and runs it as well as
the M4 does. That was the question. Two details are worth more than the
headline.

### The first request pays for the system prompt

18 s, then a settled ~4 s. Two costs are folded into that first number — the
model warming up, and the system prompt being prefilled into the slot's KV cache
before it can be reused by later requests. They have not been separated, so
neither should be quoted alone.

Either way it vindicates a V1 decision that looked like pedantry at the time.
`ChatClient` deliberately puts the timestamp on the *user* turn rather than
beside the system prompt, so the reusable prefix stays byte-identical between
requests. On the M4 that choice was worth milliseconds and was effectively
invisible. On Rosy it is the difference between 18 s and 4 s, on every single
turn. Had the timestamp gone in the system prompt, that prefill would be paid
again every time.

### The tool path is the fast path

The tool calls are the *quick* requests: 2.7–4.8 s. The cases where no tool
fired are the slow ones, 4.6–9.9 s, because a declined tool means the model
writes a full prose answer instead of twenty tokens and a stop.

So on Rosy, grounding is not a tax paid for accuracy. A dictionary lookup that
returns a real definition is both more correct *and* faster than letting a 1-bit
model extemporise about Apollo and Athena. The dictionary tool should feel like
a speed-up, which is a rare and pleasant place to be.

### The failure reproduced exactly

*"Set volume to 200"* produced `volume_set(level=20)` on Rosy too. The same
wrong, schema-valid, in-range answer on entirely different hardware. That
settles it as a property of the model rather than a run of bad luck, and the
confirmation rule for state-changing tools is not negotiable.

## The case for the dictionary tool, restated

A separate check asked Bonsai to explain *susurrus* with no tool available. She
called it an ancient Greek word and associated it with Apollo and Athena. Given
the real macOS dictionary entry as a tool observation, she correctly reported
the Latin origin and the whispering, murmuring, rustling sense.

Grounding fixed the central fact and did not fully suppress embellishment at the
edges: one grounded answer still invented a second "literary device" meaning,
and another invented the Latin form *sussurro*. So the dictionary tool should
surface the retrieved entry itself, with the model's gloss beside it rather than
in place of it. The entry is the answer; the model is the presenter.

## What this does not answer

- Rosy has had one pass, not three. Her per-case variance is uncharacterised,
  and the 4 s median comes from a single sample per case.
- Whether the 18 s first request is model warm-up, prefill, or both is
  unseparated.
- Only single-call turns were tested. Chained calls, parallel calls, and
  recovery from a tool that returns an error are all untested.
- 4B and 8B were not measured. They are presumed no worse, which is not the
  same as known.
- The injection cases are illustrative, not a threat model.
