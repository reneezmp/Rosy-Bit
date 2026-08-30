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

**Bonsai 1.7B Q1_0 on the 2017 fanless Core m3, 26 cases, 3 passes, 78 requests.**

| Verdict | Count | Share |
| --- | --- | --- |
| PASS | 74 | 95% |
| WRONG-ARG | 3 | 4% |
| MISSED | 1 | 1% |
| MALFORMED, hallucinated, or false positive | **0** | 0% |

Median latency 5.29 s, maximum 26.1 s.

The machine the project exists for runs the tool loop, and runs it as well as
the M4 does — 95% against 94%, which is the same number twice. Nothing about
one bit or two cores stops Bonsai driving a tool. Four details are worth more
than the headline.

### The tool path is the fast path

Across both machines this is the most consistent result in the suite. On Rosy,
over 78 requests:

| | n | median |
| --- | --- | --- |
| A tool fired | 51 | **4.30 s** |
| No tool fired | 27 | **7.50 s** |

A declined tool means the model writes a full prose answer; a fired one means
about twenty tokens and a stop. Grounding is roughly **1.7× faster** than
improvising, which inverts the usual trade. On Rosy the dictionary tool should
feel like a speed-up, not a tax paid for accuracy — a rare and pleasant place
to be.

### She gets tired

Tool-call latency drifts upward across passes on identical work:

| | pass 1 | pass 2 | pass 3 |
| --- | --- | --- | --- |
| Tool-call median | 3.70 s | 5.00 s | 5.50 s |

That is **+49% over about fifteen minutes of sustained load**, monotonic. The
obvious reading is thermal throttling on a fanless machine, and it has not been
confirmed against actual clock speeds — growing KV cache and background load
would look similar. Whatever the mechanism, the design consequence stands: Rosy
gets slower the harder she is worked, so a tool layer must not poll, batch
speculatively, or warm anything in the background. Work she was asked for, and
nothing else.

### The first request pays for the system prompt

The single pass run earlier cost 18.0 s on its first request and about 4 s
afterwards. This three-pass run began against an already-warm server, and its
first request took 4.1 s — which is the corroboration, not a separate result.
The 18 s is warm-up and system-prompt prefill together and they have not been
separated.

Either way it vindicates a V1 decision that looked like pedantry at the time.
`ChatClient` deliberately puts the timestamp on the *user* turn rather than
beside the system prompt, so the reusable prefix stays byte-identical between
requests. On the M4 that choice was worth milliseconds and was effectively
invisible. On Rosy it is worth about fourteen seconds a turn.

### The failure reproduced, every single time

*"Set volume to 200"* produced `volume_set(level=20)` in all three Rosy passes,
having produced it in two of three on the M4 — five times in six across two
architectures. It is a property of the model, not a run of bad luck, and the
confirmation rule for state-changing tools is not negotiable.

The one MISSED was case 14 again, *"How loud is my Mac right now?"*, in one pass
of three. That is the same borderline phrasing the M4 found, failing at a
similar rate, which is what a decision-boundary case looks like rather than a
gap in the description.

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

- Whether the 18 s first request is model warm-up, prefill, or both is
  unseparated.
- The +49% drift is unconfirmed as thermal throttling. Nobody has watched
  Rosy's clock speeds while the suite ran.
- Only single-call turns were tested. Chained calls, parallel calls, and
  recovery from a tool that returns an error are all untested.
- 4B and 8B were not measured. They are presumed no worse, which is not the
  same as known.
- The injection cases are illustrative, not a threat model.
