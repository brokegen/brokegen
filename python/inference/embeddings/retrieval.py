import logging
import operator
from abc import abstractmethod
from typing import List, Callable, Awaitable

from langchain_core.documents import Document

from embeddings.knowledge import KnowledgeSingleton
from inference.prompting.models import ChatMessage, PromptText

logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)


class RetrievalPolicy:
    @abstractmethod
    async def parse_chat_history(
            self,
            messages: List[ChatMessage],
            generate_retrieval_str_fn: Callable[[PromptText], Awaitable[PromptText]] | None,
    ) -> PromptText | None:
        raise NotImplementedError()


class SkipRetrievalPolicy(RetrievalPolicy):
    async def parse_chat_history(
            self,
            messages: List[ChatMessage],
            generate_retrieval_str_fn: Callable[[PromptText], Awaitable[PromptText]] | None,
    ) -> PromptText | None:
        return None


class DefaultRetrievalPolicy(RetrievalPolicy):
    def __init__(self, knowledge: KnowledgeSingleton):
        self.retriever = knowledge.as_retriever()

    async def parse_chat_history(
            self,
            messages: List[ChatMessage],
            generate_retrieval_str_fn: Callable[[PromptText], Awaitable[PromptText]] | None,
    ) -> PromptText | None:
        latest_message_content = messages[-1]['content']
        retrieval_str = latest_message_content

        matching_docs: List[Document] = await self.retriever.ainvoke(retrieval_str)
        formatted_docs = '\n\n'.join(
            [d.page_content for d in matching_docs]
        )

        big_prompt = f"""\
Use any sources you can. Some recent context is provided to try and provide newer information:

<context>
{formatted_docs}
</context>

Reasoning: Let's think step by step in order to produce the answer.

Question: {latest_message_content}"""

        return big_prompt


class CustomRetrievalPolicy(RetrievalPolicy):
    def __init__(self, knowledge: KnowledgeSingleton):
        self.retriever = knowledge.as_retriever(
            search_type='similarity',
            search_kwargs={
                'k': 8,
            },
        )

    async def parse_chat_history(
            self,
            messages: List[ChatMessage],
            generate_retrieval_str_fn: Callable[[PromptText], Awaitable[PromptText]] | None,
    ) -> PromptText | None:
        latest_message_content = messages[-1]['content']
        retrieval_str: PromptText = await generate_retrieval_str_fn(f"""\
Summarize the important terms in the following query, in one or two sentences,
to allow for rapid RAG retrieval of related content:

{latest_message_content}
""")

        matching_docs0: List[Document] = await self.retriever.ainvoke(retrieval_str)
        if len(matching_docs0) == 0:
            return None

        def total_doc_length(docs: List[Document]):
            return sum(
                map(len,
                    map(operator.attrgetter('page_content'),
                        docs)))

        # Truncation part 1: AI-mediated reduction.
        if total_doc_length(matching_docs0) < 20_000:
            formatted_docs = "\n\n".join([d.page_content for d in matching_docs0])

        else:
            logger.debug(
                f"Returned {len(matching_docs0)} docs, with {total_doc_length(matching_docs0)} chars text, truncating")

            matching_docs1 = []
            for n in range(len(matching_docs0)):
                summarized_doc = await generate_retrieval_str_fn(f"""\
Summarize the important parts of the following document,
in a way relevant to the original query:

<query>
{latest_message_content}
</query>

<document>
{matching_docs0[n].page_content}
</document>
""")
                matching_docs0[n].page_content = summarized_doc
                matching_docs1.append(matching_docs0[n])

                if total_doc_length(matching_docs1) > 20_000:
                    logger.debug(f"Already failed to truncate docs, AI-mediated summaries are still too long")
                    break

                # Otherwise, check if our reduction was actually successful, and it's time to stop
                if total_doc_length(matching_docs0) < 20_000:
                    matching_docs1 = matching_docs0
                    break

            # Truncation part 2: sheer length
            if total_doc_length(matching_docs1) < 20_000:
                formatted_docs = "\n\n".join([d.page_content for d in matching_docs1])

            else:
                matching_docs2 = list(matching_docs1)
                while total_doc_length(matching_docs2) > 20_000:
                    matching_docs2 = matching_docs2[:-1]

                if len(matching_docs2) == 0:
                    logger.debug(f"Last remaining RAG doc is {len(matching_docs1[0].page_content)} chars, truncating it")
                    formatted_docs = matching_docs1[0][:20_000]

                else:
                    formatted_docs = "\n\n".join(
                        [d.page_content for d in matching_docs2]
                    )

        big_prompt = f"""\
Use any sources you can. Some recent context is provided to try and provide newer information:

<context>
{formatted_docs}
</context>

Reasoning: Let's think step by step in order to produce the answer.

Question: {latest_message_content}"""

        return big_prompt
