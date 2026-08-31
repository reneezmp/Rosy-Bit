# Changelog

Rosy Bit follows semantic versioning from the first public baseline. This file
records user-visible changes; the detailed engineering history remains in Git.

## Unreleased

## [1.1.0] — 2026-08-31

### Added

- The cached prefix is now prefilled when the server becomes ready, instead of
  being charged to whoever asks the first question. A question then prefills
  only its own words — 15 tokens rather than 203 in measurement. If one is
  submitted while that is still running it waits for it, which costs nothing:
  the prefill had to happen either way. The ask bar shows an unobtrusive
  "Preparing context…" while it runs and stays typeable throughout.
- The Ask bar can now ground word questions in the dictionaries already enabled
  on the Mac. The retrieved entry is shown verbatim in a visually distinct code
  block before Rosy’s short gloss; it is never replaced by model prose. The tool
  is local, read-only, limited to one call per turn, and enabled only for the
  measured Bonsai 1.7B Q1_0 build.
- Explicit definition phrasings such as “define X” and “what does X mean?” now
  route directly to Dictionary Services instead of asking the model whether it
  feels like calling the tool. Ambiguous and multi-line requests remain with
  normal model routing, avoiding both missed lookups and pasted-text triggers.
- Rosy can now report the Mac’s current output volume through a validated,
  read-only `volume_get` tool backed by Core Audio.
- Exact one-line commands can set volume from 0–100 or mute/unmute immediately,
  without a confirmation round-trip or model inference. Rosy Bit parses the
  value from the user’s own text and executes it natively; state-changing
  schemas are never exposed to the model. Vague requests get a local prompt
  for an exact level; out-of-range, decimal, and multi-line requests cannot
  mutate the Mac.
- Oversized dictionary articles are shortened locally before they reach the
  model, with the reduction disclosed beside the source excerpt. This keeps a
  bilingual mega-entry from consuming Rosy’s context window and both CPU cores.
- A memory-only chat window now supports multiple sessions, a collapsible
  conversation sidebar, streamed multi-turn replies, Markdown, cancellation,
  new and deleted sessions, and a visible reminder that history clears on quit.
- Full sessions remain visible while model context is bounded to the newest
  complete turns that fit. Long chats therefore do not make every later reply
  feed the entire transcript back through Rosy’s two cores.
- Completed Ask bar turns can move into a new chat session through **Continue
  in Chat**, beside Copy, without asking the model to regenerate either message.
- The chat window now uses an integrated native title bar and sidebar,
  date-grouped session rows, open-canvas assistant answers, compact right-aligned
  user capsules, per-answer Copy controls, and a floating composer with Rosy’s
  restrained sakura accent. Its 900×650 opening size remains compact enough to
  resize for the 12-inch display rather than inheriting a modern-screen void.
- Recent conversation prefixes can now survive slot reuse in a bounded,
  memory-only prompt cache. Rosy defaults to a 256 MB ceiling and 256-token
  checkpoints instead of llama-server's 8 GB / 8,192-token server defaults;
  both controls are visible in Performance settings and clear on quit.
- Chat messages now carry Osaurus-inspired native controls without copying its
  interface wholesale. User actions (Copy, Edit, Delete, More) appear on hover;
  assistant actions (Copy, Regenerate, More) remain visible beside measured
  TTFT, generation speed, and output-token totals. More shows the timestamp and
  opens the exact memory-only Insights request for that response.
- Editing or deleting an earlier question trims the dependent branch rather
  than leaving answers attached to words that no longer exist. Editing then
  regenerates from the corrected turn; deleting asks before removing it.
- Large chat windows now let the conversation rail grow beyond its original
  720-point opening-width cap, up to a readable 960-point ceiling.
- User-turn timestamps now use Foundation's native short time-zone notation
  (`GMT-3` for São Paulo) instead of the hand-selected `BRT` abbreviation.

### Fixed

- Flattened Dictionary Services articles now regain readable structure in the
  source block: headword and pronunciation, numbered and bullet senses,
  indented examples, later parts of speech, and origin/derivative sections each
  receive appropriate line breaks. Formatting changes whitespace only and
  never rewrites the authoritative entry.
- Dictionary code blocks now wrap to the available Ask bar or chat width instead
  of becoming one indefinitely scrolling line.
- Text inside user-message capsules is right-aligned as well as the capsule
  itself, so multi-line turns retain the intended conversational geometry.
- User-message capsules now hug short messages and grow only until their
  wrapping maximum, instead of rendering every turn at the maximum width.
- **New Chat** now shares the sidebar's top row with its collapse control, and
  collapsed mode lets the transcript and composer reclaim the released width.
  Its compact controls now align with the assistant/Copy content rail instead
  of preserving either a ghost-sidebar gutter or hugging the window edge.

- The Ask bar never appeared on macOS 13 and 15. Assigning a hosting controller
  with no sizing options let AppKit adopt a zero content size, so the panel
  opened at 0x0 — present, on screen, and invisible. It also now recovers its
  width rather than only its height, so a lost frame heals on the next open.
- `id_slot` was being sent on every internal request while having no effect.
  A single-slot server accepts `id_slot: 7` without complaint, so the field is
  not read on this endpoint; it now defaults to off.
- Insights showed "No response body" for every tool call. A tool response
  carries an empty `content` and puts the substance in `tool_calls`, which was
  never read; the empty string then shadowed the raw-body fallback. Tool calls
  are now shown, streamed ones included.

## [1.0.0] — 2026-08-30

The first complete release: a local-AI home for Rosy, the 2017 12-inch MacBook
that inspired the project.

### Added

- Universal macOS 13+ menu bar app for Intel and Apple Silicon.
- Bundled `llama-server` supervisor with an OpenAI-compatible loopback endpoint.
- First-run Bonsai model download and selectable 1.7B, 4B, and 8B downloads.
- Real installed GGUF sizes in the model menu.
- Configurable global Ask bar with streaming Markdown output.
- Compact local timestamps on user messages for temporal context.
- Bounded, scrollable answers that remain visible while generation is active.
- In-memory Insights for prompts, responses, parameters, and performance.
- Settings for inference, sampling, CORS, system prompt, ports, and shortcut.
- Active-inference indicator, request cancellation, launch at login, and logs.
- Automated regression coverage for the proxy, HTTP parsing, Markdown,
  timestamp formatting, and model display metadata.

### Fixed before release

- Replaced the Network framework proxy with BSD sockets for reliable operation
  on native Ventura as well as OCLP Sequoia.
- Corrected keep-alive, chunked transfer, trailers, HEAD, 204, and 304 handling.
- Prevented stale async starts, orphaned servers, unsafe port cleanup, and
  installer relaunch races.
- Prevented cancelled downloads from completing later or leaving partial GGUFs.
- Stopped the Ask bar selecting submitted questions, growing without limit,
  disappearing during generation, or exposing raw Markdown delimiters.
- Kept the system prompt stable while adding timestamp context to user turns.

### Attribution

- Added visible Prism ML/Bonsai credit and the requested Bonsai citation.
- Added third-party license notices to the repository and built app bundle.

[1.0.0]: https://github.com/reneezmp/Rosy-Bit/releases/tag/v1.0.0
[1.1.0]: https://github.com/reneezmp/Rosy-Bit/releases/tag/v1.1.0
