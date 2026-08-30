# Changelog

Rosy Bit follows semantic versioning from the first public baseline. This file
records user-visible changes; the detailed engineering history remains in Git.

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
