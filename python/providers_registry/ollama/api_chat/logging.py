import logging

from _util.json import JSONDict, safe_get
from providers.inference_models.database import HistoryDB
from providers_registry.ollama.json import OllamaResponseContentJSON

logger = logging.getLogger(__name__)


async def inference_event_logger(
        consolidated_response: JSONDict,
        history_db: HistoryDB,
) -> None:
    pass


async def construct_new_sequence_from(
        consolidated_response: JSONDict,
        history_db: HistoryDB,
) -> None:
    pass


def ollama_log_indexer(
        chunk_json: JSONDict,
) -> str:
    return safe_get(chunk_json, 'message', 'content') or ""


def ollama_response_consolidator(
        chunk: JSONDict,
        consolidated_response: OllamaResponseContentJSON,
) -> OllamaResponseContentJSON:
    if not consolidated_response:
        return chunk

    for k, v in chunk.items():
        if k not in consolidated_response:
            consolidated_response[k] = v
            continue

        if k == 'created_at':
            consolidated_response['terminal_created_at'] = v
            continue

        elif k == 'done':
            if consolidated_response[k]:
                logger.warning(f"Received additional JSON after streaming indicated we were {k}={v}")

        elif k == 'model':
            if consolidated_response[k] != v:
                raise ValueError(
                    f"Received new model name \"{v}\" during streaming response, expected {consolidated_response[k]}")

        # This tends to be the output from /api/generate
        elif k == 'response':
            consolidated_response[k] += v
            continue

        # And this is /api/chat, which we don't care too much about.
        # Except as a stopgap, for now.
        elif k == 'message':
            if set(v.keys()) != {'content', 'role'}:
                logger.warning(f"Received unexpected message content with keys: {v.keys()}")
            if v['role'] != 'assistant':
                logger.warning(f"Received content for unexpected role \"{v['role']}\", continuing anyway")

            consolidated_response[k]['content'] += v['content']
            continue

        else:
            raise ValueError(
                f"Received unidentified JSON pair {k}={v}, abandoning consolidation of JSON blobs.\n"
                f"Current consolidated response has key set: {consolidated_response.keys()}")

        # In the non-exceptional case, just update with the new value.
        consolidated_response[k] = v

    return consolidated_response
