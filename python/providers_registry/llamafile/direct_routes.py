import logging
from typing import Annotated, AsyncIterable, cast

import fastapi
import httpx
import orjson
import starlette.datastructures
from fastapi import Query, Depends, HTTPException
from starlette.background import BackgroundTask
from starlette.responses import JSONResponse

import providers_registry.llamafile.registry
from _util.json import JSONDict
from _util.typing import TemplatedPromptText
from audit.http import AuditDB, get_db as get_audit_db
from audit.http_raw import HttpxLogger
from client.database import HistoryDB, get_db as get_history_db
from providers.orm import ProviderID
from providers.registry import BaseProvider, ProviderRegistry

logger = logging.getLogger(__name__)


def install_test_points(router_ish: fastapi.FastAPI | fastapi.routing.APIRouter) -> None:
    @router_ish.post("/providers/llamafile/{provider_id:path}/models/any/completion")
    async def generate_from_provider(
            provider_id: ProviderID,
            templated_text: TemplatedPromptText,
            options_json: Annotated[str, Query()] \
                    = """{"n_predict": 500, "top_k": 82.4, "n_ctx": 16384}""",
            stream_response: bool = True,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        # Fetch the first LlamafileProvider that matches
        provider: BaseProvider | None = None
        for label, provider_candidate in registry.by_label.items():
            if label.type != "llamafile":
                continue

            if label.id == provider_id:
                provider = provider_candidate
                break

        if provider is None:
            raise HTTPException(400, f"Could not find matching Provider")

        request_content = {
            'prompt': templated_text,
            'stream': True,
        }
        request_content.update(orjson.loads(options_json))

        headers = httpx.Headers()
        headers['content-type'] = 'application/json'
        # https://github.com/encode/httpx/discussions/2959
        # httpx tries to reuse a connection later on, but asyncio can't, so "RuntimeError: Event loop is closed"
        headers['connection'] = 'close'

        # TODO: Add HttpEvent logger
        # TODO: Add InferenceEventOrm

        httpx_client = cast(providers_registry.providers_llamafile.registry.LlamafileProvider, provider) \
            .server_comms

        upstream_request = httpx_client.build_request(
            method='POST',
            url="/completion",
            content=orjson.dumps(request_content),
            headers=headers,
        )

        with HttpxLogger(httpx_client, audit_db):
            upstream_response: httpx.Response = await httpx_client.send(upstream_request, stream=True)

            async def post_forward_cleanup():
                await upstream_response.aclose()

        if stream_response:
            streaming_response = starlette.responses.StreamingResponse(
                content=upstream_response.aiter_bytes(),
                status_code=upstream_response.status_code,
                headers=upstream_response.headers,
                background=BackgroundTask(post_forward_cleanup),
            )

            return streaming_response

        else:
            async def content_to_json_adapter() -> JSONDict:
                async def consolidate_stream(
                        primordial: AsyncIterable[JSONDict],
                ):
                    consolidated_response: JSONDict | None = None
                    async for decoded_line in primordial:
                        if consolidated_response is None:
                            consolidated_response = dict(decoded_line)
                            continue

                        for k, v in decoded_line.items():
                            if k == 'content':
                                consolidated_response[k] += v
                                continue

                            consolidated_response[k] = v

                    return consolidated_response

                async def jsonner() -> AsyncIterable[JSONDict]:
                    async for chunk in upstream_response.aiter_bytes():
                        # The first few bytes of the llamafile response always start with 'data: '
                        if chunk[0:6] == b'data: ':
                            chunk = chunk[6:]

                        yield orjson.loads(chunk)

                return await consolidate_stream(jsonner())

            return JSONResponse(
                content=await content_to_json_adapter(),
                status_code=upstream_response.status_code,
                headers=upstream_response.headers,
                background=BackgroundTask(post_forward_cleanup),
            )
