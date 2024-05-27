import logging
from datetime import datetime, timezone

import fastapi.routing
import orjson
import starlette.requests
from fastapi import FastAPI, Depends
from pydantic import BaseModel
from sqlalchemy import select

import history.ollama
from audit.http import AuditDB
from audit.http import get_db as get_audit_db
from history.chat.database import ChatMessageOrm, ChatSequence
from _util.typing import ChatSequenceID, PromptText, InferenceModelHumanID
from history.chat.routes_sequence import do_get_sequence
from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers.inference_models.orm import InferenceModelRecordOrm, InferenceEventOrm, InferenceEventID
from _util.json import JSONStreamingResponse
from inference.embeddings.retrieval import SkipRetrievalPolicy

logger = logging.getLogger(__name__)


class GenerateIn(BaseModel):
    user_prompt: PromptText
    sequence_id: ChatSequenceID


def install_routes(app: FastAPI):
    router = fastapi.routing.APIRouter()

    @router.post("/generate")
    async def get_simple_chat(
            empty_request: starlette.requests.Request,
            params: GenerateIn,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
    ) -> JSONStreamingResponse:
        # Manually construct a Request object, because that's how we pass any data around
        constructed_request = empty_request

        # Manually fetch the message + model config history from our requests
        messages_list = do_get_sequence(params.sequence_id, history_db, include_model_info_diffs=False)
        # And append our user message as its own message
        # TODO: Commit this message and/or check for duplicates
        messages_list.append(ChatMessageOrm(
            role='user',
            content=params.user_prompt,
            created_at=datetime.now(tz=timezone.utc),
        ))

        # Fetch the latest model config from ChatSequence
        inference_id: InferenceEventID = history_db.execute(
            select(InferenceEventOrm.id)
            .join(ChatSequence, ChatSequence.inference_job_id == InferenceEventOrm.id)
            .where(ChatSequence.id == params.sequence_id)
        ).scalar_one()

        model_name: InferenceModelHumanID = history_db.execute(
            select(InferenceModelRecordOrm.human_id)
            .join(InferenceEventOrm, InferenceEventOrm.model_record_id == InferenceModelRecordOrm.id)
            .where(InferenceEventOrm.id == inference_id)
        ).scalar_one()

        constructed_body = {
            "messages": [m.as_json() for m in messages_list],
            "model": model_name,
        }
        # NB This overwrites the internals of the Requests object;
        # we should really be passing decoded versions throughout the app.
        constructed_request._body = orjson.dumps(constructed_body)

        # Wrap the output in a… something that appends new ChatSequence information
        async def wrap_response(
                upstream_response: JSONStreamingResponse,
        ) -> JSONStreamingResponse:
            async def almost_identity_proxy(primordial):
                async for chunk in primordial:
                    chunk_json = orjson.loads(chunk)
                    if chunk_json["done"]:
                        chunk_json["new_sequence_id"] = -1
                        chunk_json["error"] = "sequence id's not actually implemented"
                        yield orjson.dumps(chunk_json)
                        return

                    yield chunk

            upstream_response._content_iterable = almost_identity_proxy(upstream_response._content_iterable)

            return upstream_response

        return await wrap_response(
            await history.ollama.chat_rag_routes.do_proxy_chat_rag(
                constructed_request,
                SkipRetrievalPolicy(),
                history_db,
                audit_db,
        ))

    app.include_router(router)
