## Design Principles

1. Design for local, personal use.
   - Design for providers like Ollama and llama.cpp first, before OpenAI API compatibility.
2. Hoard data, in any conceivably useful way. 
   - Storage is cheap and getting cheaper, compute is the limited resource. So store as much as you can, and plan for future implementations to reconfigure/recompute things (like inference costs on new providers).
   - Data is easy to port around, a few GB of chat history is easier to preserve for ten years from now, rather than trying to get Python 3.5 working on an iOS device in 2034.
3. Store original JSON responses as much as possible
   - There's no reason to come up with our own distinct storage format for anything; we're simply not at a scale where we see any benefit from it.
   - User data is the most important thing, do everything you can to make sure it's not lost.

LLM inference (compute) is presumed to be the bottleneck, and will get worse as we stack on RAG and DSPy, so each "user" query fans out into dozens and hundreds of reified LLM queries.

Current Python is basically single-threaded, so we use `async` as much as possible. This is especially a pain for streaming network requests, where we end up jumping back and forth between perhaps a dozen contexts while wrapping up a stream.



----
## Project Glossary

There are a lot of different verbs, because data is created, fetched, constructed, updated, etc.

- `Templated` means the prompts and content have been adapted for use by a specific model type, since chat/instruct-type models are trained on special tokens to demarcate user/assistant input. (This is less useful for local models, where we don't have to fight a `system` prompt that's set in stone.) 
- `Records` is a suffix that implies we're storing every variant of a provided datom. For example, even if a model config changes by one tiny parameter (`top_k` going from 60 to 80), record that change.
- `Label` means it's intended to be human-readable identifiers.

Data + network calls:

- `lookup_` is a prefix meaning "look up in databases-owned-by-this-app" (strictly "offline")
  - `create_` is also strictly offline, but focused on objects rather than data.
  - `make_` is also for creating objects, but is expected to do heavy caching
- `fetch_` means look up in local databases, or hit Providers as a secondary step
- `construct_` means we expect to be hitting Providers first, but otherwise similar behavior as `fetch_`.

Other prefixes:

- `do_` is a prefix wart for "internal" usages, usually with only one actual caller.
  FastAPI/Starlette endpoint wrappers often call a `do_` version of themselves.
- "raw" is an overloaded term (main usage is Ollama takes it to mean "LLM templating has been applied"), and we should avoid it 

### Data fields

- `machine_` is an identifier that's basically meaningless, and needs to be looked up somewhere
- `human_` is primarily used when interacting with a human user, things like screennames and short identifiers that someone will probably be typing, or at least reading fairly frequently
