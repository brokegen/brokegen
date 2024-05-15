As the simplest example, take the three `User` models used in [FastAPI's tutorial](https://fastapi.tiangolo.com/tutorial/extra-models/):

1. `UserIn` needs to have a password
2. `UserOut` should not have a password
3. `UserInDB` should have a hashed password

As an extension of this, Alamofire (a Swift networking library) supports the distinct in/out cases,
and also tends to embed the output into a fancy union:

4. `struct ModelRequestData: Encodable`
5. `struct ModelResponseData: Decodable` => `Publisher<ModelResponseData, AFError>`

So with these 4-ish contexts in mind, here are the domains we have to worry about for LLM inference:

1. **server-side inference + statistics**: model config, service used.
   concrete stuff that determines things like "should I keep using this provider" and "how much time/money did it cost?"
2. **api inputs**: what _actual_ queries were made, what text/image/file input data was provided to the model
   - this data should be enough to let us transfer requests to a different provider, and compare how e.g. llama3-70B performs
   - the model config mentioned above bleeds into this layer, as well
3. **api outputs**: most of the time, different random seeds are used. or the model is changed under the hood, without any fanfare (OpenAI and ChatGPT, as the most visible case)
   - one variation on this: most LLMs take time to execute, and stream their output.
     how much of this streaming do we want to preserve? can we just combine the streamed output at the end, or do we truly want detailed statistics like tokens per second over time? (can we even identify entire tokens?)
4. **user-visible inputs**: what did the end user to provide, that we would expect to get us similar output?
   - text data, chat history, and any middleware that transforms things like RAG context into the complete prompt parsed by the LLM
