# brokegen

----

<picture>
  <img alt="UI screenshot" src="screenshot.webp" height="480px">
</picture>
<picture>
  <img alt="UI with settings screenshot" src="crowded.webp" height="480px">
</picture>

macOS app to chat with local foundation models. Ollama is well-supported, and .gguf files are loaded via llama-cpp-python (put them in `~/Library/Application Support/faux.brokegen/`).
Key differentiator is a focus on data capture and retention; text and inference stats are stored in SQLite databases.

## Special Features

- Virtually all settings are overrideable (model template, system prompt, start of assistant response, ollama/llama.cpp inference options)
- Chats can be branched at any point, and a built-in Ollama proxy is provided to capture chats from other apps.
- Ollama proxy is built-in, so any messages sent through other apps will be captured and show up in brokegen (only `/api/chat` requests, not `/api/generate`). When the server is started, the proxy is available on `http://localhost:6635/ollama-proxy`.

## Requirements
Tested and developed on macOS 14.2+, M1 MBP + 2019 Intel MBP. Pre-built binaries are x86 only, compiled for AVX2 CPU's and will run inference very slowly (estimated 3-6 tokens/sec for quantized mistral-7b, maxing out the 8 CPU cores on an Intel MBP).

If you don't need to run custom models, install Ollama and use that as the inference provider:

1. Download from <https://ollama.ai> and open the application.
2. Once the command-line utility is installed, open a terminal and run `ollama pull <MODEL_NAME>`.
   The full list is available at <https://ollama.ai/library>.
3. Once the model has finished downloading, you can start using it.

Or, if you would rather use the embedded ollama binary, you can run a command like `./Brokegen.app/Contents/Resources/ollama-darwin pull mistral:7b`, and use that for inference.

## Development Notes

UI code is kept simpler, a lot of complexity is pulled in through a built-in Python server.

Python code is built with `pyinstaller`, and run as a service by the SwiftUI app.
An embedded copy of ollama is also included, though you'll have to download models yourself.
