# brokegen

----

<picture>
  <img alt="screenshot" src="screenshot.webp">
</picture>

macOS app that lets you scan through documents and then ask a local LLM about them.

- UI tested on macOS 14.2+, M1 MBP + 2019 Intel MBP
- Inference tested with Ollama, llama.cpp server, and Mozilla-Ocho llamafiles

## Development Notes

UI code is kept simpler, a lot of complexity is pulled in through Python libraries.
Python code is built with `pyinstaller`, and run as a service by the SwiftUI app.

Langchain is mostly there for embeddings; any prompt engineering code should probably
be handled by DSPy, in the future.
