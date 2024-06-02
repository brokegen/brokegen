import logging
import operator
from abc import abstractmethod
from typing import List, Callable, Awaitable, TypeAlias, Any

import orjson
from langchain_core.documents import Document
from langchain_core.messages import ChatMessage

from _util.status import ServerStatusHolder
from inference.embeddings.knowledge import KnowledgeSingleton, get_knowledge
from _util.typing import PromptText, TemplatedPromptText
from providers.inference_models.orm import InferenceReason

logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)


RetrievalPolicyID: TypeAlias = str


class RetrievalPolicy:
    @abstractmethod
    async def parse_chat_history(
            self,
            messages: List[ChatMessage],
            _: Callable[[PromptText, PromptText, PromptText, InferenceReason], Awaitable[PromptText]],
            status_holder: ServerStatusHolder | None = None,
    ) -> PromptText | None:
        raise NotImplementedError()


class SkipRetrievalPolicy(RetrievalPolicy):
    async def parse_chat_history(
            self,
            messages: List[ChatMessage],
            _: Callable[[PromptText, PromptText, PromptText, InferenceReason], Awaitable[PromptText]],
            status_holder: ServerStatusHolder | None = None,
    ) -> PromptText | None:
        return None


class SimpleRetrievalPolicy(RetrievalPolicy):
    def __init__(self, knowledge: KnowledgeSingleton):
        self.retriever = knowledge.as_retriever(
            search_type="mmr",
            search_kwargs={
                "k": 18,
                "fetch_k": 60,
                "lambda_mult": 0.25,
            },
        )

    async def parse_chat_history(
            self,
            messages: List[ChatMessage],
            _: Callable[[PromptText, PromptText, PromptText, InferenceReason], Awaitable[PromptText]],
            status_holder: ServerStatusHolder | None = None,
    ) -> PromptText | None:
        if status_holder is not None:
            status_holder.push("Loading retrieval databases…")
        get_knowledge().load_queued_data_dirs()
        if status_holder is not None:
            status_holder.pop()

        latest_message_content = messages[-1]['content']
        retrieval_str = latest_message_content

        matching_docs: List[Document] = await self.retriever.ainvoke(retrieval_str)
        formatted_docs = '\n\n'.join(
            [d.page_content for d in matching_docs]
        )

        big_prompt = f"""\
Use the provided context where applicable. Ignore irrelevant context.

<context>
{formatted_docs}
</context>

Reasoning: Let's think step by step in order to produce the answer. Take a deep breath and do your best.

Question: {latest_message_content}"""

        return big_prompt


class SummarizingRetrievalPolicy(RetrievalPolicy):
    def __init__(
            self,
            knowledge: KnowledgeSingleton,
            # For thoroughness, this should be 18, but we haven't figured out prompt size/tuning yet.
            # More specifically, how to configure it in a reasonable way.
            search_args_json: str = """{"k":12}""",
    ):
        self.retriever = knowledge.as_retriever(
            search_type='similarity',
            search_kwargs=orjson.loads(search_args_json),
        )

    async def parse_chat_history(
            self,
            messages: List[ChatMessage],
            generate_helper_fn: Callable[[PromptText, PromptText, PromptText, InferenceReason], Awaitable[PromptText]],
            status_holder: ServerStatusHolder | None = None,
    ) -> PromptText | None:
        get_knowledge().load_queued_data_dirs()

        latest_message_content = messages[-1]['content']

        async def summarize_query():
            retrieval_str: PromptText = latest_message_content

            # If the query is exceptionally short, include recent messages
            # (but ONLY for the sake of retrieving docs)
            if len(retrieval_str) < 200:
                retrieval_str = ''
                for message in messages[::-1]:
                    if len(retrieval_str) > 4_000:
                        break

                    retrieval_str += message['content']
                    retrieval_str += '\n\n'

            # Only summarize the query if it's real long
            if len(retrieval_str) > 4_000:
                retrieval_str = await generate_helper_fn(
                    inference_reason="summarize prompt for retrieval",
                    system_message="Summarize the most important and unique terms in the following query",
                    user_prompt=latest_message_content,
                )
                # If the summary is blank or shorter than a tweet, skip.
                if not retrieval_str.strip() or len(retrieval_str) < 140:
                    retrieval_str = latest_message_content
                else:
                    logger.info(f"Summary of the provided query: {retrieval_str[:500]}")

            return retrieval_str

        final_retrieval_str = await summarize_query()

        matching_docs0: List[Document] = await self.retriever.ainvoke(final_retrieval_str)
        if len(matching_docs0) == 0:
            return None

        def total_doc_length(docs: List[Document]):
            return sum(
                map(len,
                    map(operator.attrgetter('page_content'),
                        docs)))

        # Truncation part 1: AI-mediated reduction.
        if total_doc_length(matching_docs0) < 40_000:
            formatted_docs = "\n\n".join([d.page_content for d in matching_docs0])

        else:
            logger.debug(
                f"Returned {len(matching_docs0)} docs, with {total_doc_length(matching_docs0)} chars text, truncating")

            matching_docs1 = []
            for n in range(len(matching_docs0)):
                summarized_doc = await generate_helper_fn(
                    inference_reason="summarize document",
                    system_message="""\
Provide a concise summary of the provided document. Call out any sections that seem closely related to the original query.""",
                    user_prompt=f"""\
<query>
{latest_message_content}
</query>

<document>
{matching_docs0[n].page_content}
</document>""",
                    assistant_response="Summary of the returned document: ",
                )
                # If the summary is blank or shorter than a tweet, skip.
                if not summarized_doc.strip() or len(summarized_doc) < 140:
                    pass
                else:
                    logger.info(f"Summarized, {len(matching_docs0[n].page_content)} => {len(summarized_doc)} chars: "
                                f"{summarized_doc[:500]}")
                    matching_docs0[n].page_content = summarized_doc

                matching_docs1.append(matching_docs0[n])
                if total_doc_length(matching_docs1) > 40_000:
                    logger.debug(f"Already failed to truncate docs, AI-mediated summaries are still too long")
                    break

                # Otherwise, check if our reduction was actually successful, and it's time to stop
                if total_doc_length(matching_docs0) < 40_000:
                    matching_docs1 = matching_docs0
                    break

            # Truncation part 2: sheer length
            if total_doc_length(matching_docs1) < 40_000:
                formatted_docs = "\n\n".join([d.page_content for d in matching_docs1])

            else:
                matching_docs2 = list(matching_docs1)
                while total_doc_length(matching_docs2) > 40_000:
                    matching_docs2 = matching_docs2[:-1]

                if len(matching_docs2) == 0:
                    logger.debug(
                        f"Last remaining RAG doc is {len(matching_docs1[0].page_content)} chars, truncating it")
                    formatted_docs = matching_docs1[0][:40_000]

                else:
                    formatted_docs = "\n\n".join(
                        [d.page_content for d in matching_docs2]
                    )

        big_prompt = f"""\
Use context where you can, but don't rely on it overmuch:

<context>
{formatted_docs}
</context>

Reasoning: Let's think step by step in order to produce the answer.

Question: {latest_message_content}"""

        return big_prompt
