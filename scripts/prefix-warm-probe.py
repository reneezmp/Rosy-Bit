#!/usr/bin/env python3
#
# Measures what warming the cached prefix costs, and what it buys.
#
#   ./scripts/prefix-warm-probe.py                # against the public port
#   ./scripts/prefix-warm-probe.py --port 11337   # straight to llama-server
#
# llama-server caches the longest common prefix per slot, which is why Rosy's
# first request costs about 18s and every later one about 4s. The prefix is the
# system prompt plus, once tools are enabled, the stable tool block. Nothing
# warms it until the user's first question pays for it.
#
# A request with max_tokens=0 prefills that prefix and generates nothing, so the
# cost can be moved off the first question. The question this answers is whether
# that is worth doing on a fanless two-core machine: it prints what the warm
# costs and how many prompt tokens the next request then has to process.
#
# `prompt_n` in the timings is the number that matters. It is what the server
# actually had to prefill, as opposed to what it was sent.

import argparse
import json
import sys
import time
import urllib.request
import uuid

DICTIONARY = {
    "type": "function",
    "function": {
        "name": "dictionary_lookup",
        "description": "Look up a word or short term in the dictionaries enabled on "
                       "this Mac. Use this when the user asks what a word means, for "
                       "a definition, or about a word's origin. The returned entry is "
                       "authoritative; do not invent senses or etymologies beyond it.",
        "parameters": {
            "type": "object",
            "properties": {
                "term": {
                    "type": "string",
                    "description": "The exact word or short term to look up.",
                },
            },
            "required": ["term"],
            "additionalProperties": False,
        },
    },
}

VOLUME_GET = {
    "type": "function",
    "function": {
        "name": "volume_get",
        "description": "Read the Mac's current system output volume as a percentage. "
                       "Use this when the user asks how loud the Mac is or what its "
                       "current volume is.",
        "parameters": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
    },
}


def post(url, payload, timeout):
    request = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    started = time.time()
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read()), time.time() - started


def report(label, body, elapsed):
    timings = body.get("timings", {})
    print(f"  {label:<34} {elapsed:6.2f}s   "
          f"prefilled {timings.get('prompt_n', '?')} tokens "
          f"in {timings.get('prompt_ms', 0):.0f}ms")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=1337)
    parser.add_argument("--model", default=None)
    parser.add_argument("--timeout", type=float, default=300.0)
    parser.add_argument("--no-tools", action="store_true",
                        help="Measure the prefix without Rosy Bit's tool block.")
    options = parser.parse_args()

    base = f"http://{options.host}:{options.port}"
    model = options.model
    if model is None:
        try:
            with urllib.request.urlopen(f"{base}/v1/models", timeout=15) as response:
                model = json.loads(response.read())["data"][0]["id"]
        except Exception as error:
            sys.exit(f"Could not read {base}/v1/models — is Rosy Bit running? ({error})")

    tools = [] if options.no_tools else [DICTIONARY, VOLUME_GET]
    extra = {} if not tools else {"tools": tools}
    url = f"{base}/v1/chat/completions"

    # A unique system prompt makes each prefix cold, which is what a freshly
    # started server looks like. Without it the second run would measure the
    # first run's cache.
    def system(tag):
        return {"role": "system",
                "content": f"You are Rosy Bit, a small local assistant. Session {tag}."}

    print(f"endpoint {base}   model {model}   "
          f"tools {'off' if options.no_tools else 'on'}\n")

    print("cold — no warm, the way it behaves today")
    cold = system(uuid.uuid4())
    body, elapsed = post(url, {"model": model, "max_tokens": 64,
                               "messages": [cold, {"role": "user",
                                                   "content": "Define 'petrichor'."}],
                               **extra}, options.timeout)
    report("question straight away", body, elapsed)

    print("\nwarmed — one prefill first, then the same question")
    warm = system(uuid.uuid4())
    body, elapsed = post(url, {"model": model, "max_tokens": 0,
                               "messages": [warm, {"role": "user", "content": ""}],
                               **extra}, options.timeout)
    warm_cost = elapsed
    report("the warm itself", body, elapsed)
    body, elapsed = post(url, {"model": model, "max_tokens": 64,
                               "messages": [warm, {"role": "user",
                                                   "content": "Define 'petrichor'."}],
                               **extra}, options.timeout)
    report("question after the warm", body, elapsed)

    print(f"\nThe warm costs {warm_cost:.2f}s of Rosy's cores, once. Whether that is "
          f"worth\nspending before she has been asked anything is the actual decision.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
