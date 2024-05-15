"""
For now, this file is not intended to be used.

It encodes the target API for both database models and HTTP requests/responses,
and hopes to encode enough information to translate each of these into any backend
that we might want to use. This is likely not possible, so for now, we'll just use
Pydantic as a way to keep the code compiling, and otherwise use external definitions.

TODO: Look into https://sqlmodel.tiangolo.com/
"""
from datetime import datetime
from typing import Any

from pydantic import BaseModel


class ProviderConfigRecord(BaseModel):
    executor_hw: dict
    """
    We could probably get by with a string, but sometimes things like the macOS version
    will affect things like how many layers CoreML can hw-accelerate.
    """

    executor_sw: dict

    inference_params: dict
    """
    Mostly useful for local LLM services, where you only have one or so machines,
    and care deeply about how they were set up, e.g. how much RAM on the system is usable,
    or how many layers were offloaded to the GPU/TPU.
    """


class ModelConfigRecord(BaseModel):
    inference_params: dict
    """
    These would be the settings that are more easily configured at runtime.
    
    Since they are frequently changeable, potentially for every chat/request, these
    are intended to be diff-able so we can expose that data in the client UI.
    
    (It's very hard to visually diff two enormous JSON blobs, so something like
    "prompt was modified" or "min_k changed from 0.05 -> 0.20".)
    """

    machine_id: str
    human_id: str
    first_seen_at: datetime
    """
    This would be the created_at time, but we want to be clear that we are _not_ polling
    for model config with every request we make.
    """


class InferenceJob(BaseModel):
    """
    This class will be extremely unique; every chat `Message` will have at least one of these.

    In use cases like "condense the request into a RAG-friendly version" or "here are ten additional
    documents to provide context", a given Message will have multiple jobs attached.

    This is where the data-ness of things stops; later UI layers could probably be derived from this,
    DSPy and langchain notwithstanding.
    """

    class Statistics(BaseModel):
        stop_reason: str
        elapsed_time: float
        time_to_first_token: float

        stop_token: str
        "This is usually specific to a ModelConfig, since different models are trained with different tokens"

    provider_model_config: ProviderModelConfigRecord
    model_config: ModelConfigRecord

    api_request_content_json: dict[str | Any]
    "Content of every request is expected to be convertible to JSON"
    api_request_bytes: bytes
    """
    Also, store the entire request as raw bytes, in case we need to parse out fields or files in the future.
    
    Specifically, we'll probably need to figure out external storage for large/image requests,
    which will probably be .warc files.
    
    TODO: Check if there's any consistency in hash calculations:
    
    - langchain's _HashedDocument() does something to "generate" UUIDs
    - ollama uses sha256 to store and identify virtually every payload, including model configs 
    """

    api_response: dict | None
    "Most responses should be convertible to JSON; it's not _exceptional_ to get error cases like \"server dies\", though."
    api_response_bytes: bytes


class MessageAttachment(BaseModel):
    machine_id: str


class NormalizedMessage(BaseModel):
    """
    This class only stores completed messages; partial messages will be encoded elsewhere.
    """
    role: str
    """This is virtually always "system" or "user"."""

    content_text: str
    content_image: MessageAttachment | None

    guidance_text: str | None
    """
    For use if the API supports classifier-free guidance
    
    - StableDiffusion, in particular, relies on this almost exclusively
    - llama.cpp supports CFG prompts and a weight for them
    - other APIs are starting to support "negative" prompts, which combine with how
      the original query maps to latent space.
    """


class MessageIsh(NormalizedMessage):
    """
    This class stores anything that might _look_ like a message, in terms of presenting
    info to the end user.

    - if a model config changed, that's encoded into a textual message here
    - if an error occurred mid-processing, the partial content is included here
    - if this is only a pending message, that hasn't actually been sent anywhere
    """
    desc_for_human: str
    desc_for_llm: str


class ChatBlock(BaseModel):
    """
    This strings together a bunch of `MessageIsh` to construct future queries.

    It relies on MessageIshes knowing how to encode their data for different endpoints;
    some further examples of odd cases:

    - if the user modifies anything in the history, to make it look like the LLM
      said something than what it actually said
    - if there was hidden content in an earlier RAG that should be included in future queries
    - the ollama API sometimes returns a set of "context" weights that represent the LLM's
      short-term memory (whatever it was primed with)
    """
    messages: list[NormalizedMessage | MessageIsh]
    machine_id: str
    human_id: str

    create_time: datetime
