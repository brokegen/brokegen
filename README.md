# brokegen

----

<picture>
  <img alt="screenshot" src="screenshot.webp">
</picture>

macOS app that lets you scan through documents and then ask an LLM about them.
Key differentiator is a focus on data retention; text and inference stats are stored in a SQLite database.

Tested and developed on macOS 14.2+, M1 MBP + 2019 Intel MBP

## Special Features

- Chats are auto-named by the AI
- Retrieval is working, but we can only read from FAISS vector stores (no writes)

## Development Notes

UI code is kept simpler, a lot of complexity is pulled in through a built-in Python "server".

Python code is built with `pyinstaller`, and run as a service by the SwiftUI app.
An embedded copy of ollama is also included, though you'll have to download models yourself, for now.

