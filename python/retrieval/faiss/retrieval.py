import logging
import operator
from abc import abstractmethod
from typing import List, TypeAlias, Optional

from langchain_core.documents import Document
from langchain_core.messages import ChatMessage
from pydantic import BaseModel, PositiveInt

from _util.json import safe_get_arrayed, JSONDict
from _util.status import ServerStatusHolder, StatusContext
from _util.typing import PromptText, FoundationModelRecordID, GenerateHelper
from .knowledge import KnowledgeSingleton, get_knowledge

logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)

RetrievalPolicyID: TypeAlias = str


class RetrievalLabel(BaseModel):
    retrieval_policy: Optional[RetrievalPolicyID] = None
    retrieval_search_args: Optional[str] = None
    preferred_embedding_model: Optional[FoundationModelRecordID] = None


class RetrievalPolicy:
    @abstractmethod
    async def parse_chat_history(
            self,
            messages: List[ChatMessage],
            _: GenerateHelper,
            status_holder: ServerStatusHolder | None = None,
    ) -> PromptText | None:
        raise NotImplementedError()


class SkipRetrievalPolicy(RetrievalPolicy):
    async def parse_chat_history(
            self,
            messages: List[ChatMessage],
            _: GenerateHelper,
            status_holder: ServerStatusHolder | None = None,
    ) -> PromptText | None:
        return None


class AllMessageSimilarity(RetrievalPolicy):
    """
    Looks up matching docs that are similar to the last message in the provided list.
    """

    def __init__(
            self,
            knowledge: KnowledgeSingleton,
            search_type: str,
            search_kwargs: dict,
    ):
        self.retriever = knowledge.as_retriever(
            search_type=search_type,
            search_kwargs=search_kwargs,
        )

    async def parse_chat_history(
            self,
            messages: List[ChatMessage],
            _: GenerateHelper,
            status_holder: ServerStatusHolder | None = None,
    ) -> PromptText | None:
        with StatusContext("Loading retrieval databases…", status_holder):
            await get_knowledge().load_queued_data_dirs(status_holder)

        latest_message_content = safe_get_arrayed(messages, -1, "content") or getattr(messages[-1], "content", "")
        retrieval_str = '\n\n'.join([
            # TODO: We can remove one of these clauses, once we write enough tests to decide which one.
            safe_get_arrayed(message, "content") or getattr(message, "content", "")
            for message in messages
        ])

        matching_docs: List[Document] = await self.retriever.ainvoke(retrieval_str)
        formatted_docs = '\n\n'.join(
            [d.page_content for d in matching_docs]
        )

        big_prompt = f"""\
Use any sources you can. Some recent context is provided to try and provide newer information:

<context>
{formatted_docs}
</context>

Reasoning: Let's think step by step in order to produce the answer. Take a deep breath and do your best.

Question: {latest_message_content}"""

        return big_prompt


class SomeMessageSimilarity(AllMessageSimilarity):
    """
    Looks up matching docs that are similar to the last message in the provided list.
    """
    messages_to_read: int

    def __init__(self, messages_to_read: PositiveInt = 1, **kwargs):
        super().__init__(**kwargs)

        self.messages_to_read = messages_to_read
        if messages_to_read < 1:
            raise ValueError(f"SomeMessageSimilarity() requires a positive number of messages to read!")

    async def parse_chat_history(
            self,
            messages: List[ChatMessage],
            generate_helper_fn: GenerateHelper,
            status_holder: ServerStatusHolder | None = None,
    ) -> PromptText | None:
        return await super().parse_chat_history(
            messages[-self.messages_to_read:],
            generate_helper_fn,
            status_holder,
        )


class SummarizingRetrievalPolicy(RetrievalPolicy):
    def __init__(
            self,
            knowledge: KnowledgeSingleton,
            search_type: str,
            search_kwargs: JSONDict,
    ):
        self.retriever = knowledge.as_retriever(
            search_type=search_type,
            search_kwargs=search_kwargs,
        )

    async def parse_chat_history(
            self,
            messages: List[ChatMessage],
            generate_helper_fn: GenerateHelper,
            status_holder: ServerStatusHolder | None = None,
    ) -> PromptText | None:
        with StatusContext("Loading retrieval databases…", status_holder):
            await get_knowledge().load_queued_data_dirs(status_holder)

        latest_message_content = safe_get_arrayed(messages, -1, "content") or getattr(messages[-1], "content", "")

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
