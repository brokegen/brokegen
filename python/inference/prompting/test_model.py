"""
DSPy-focused test suite for inducting new inference models

- `pip install "dspy-ai[chromadb]"`
- Behind a proxy, the `pystemmer==2.2.0.1` package tries to download a file.
  In its working directory, run: `curl -L -O https://snowballstem.org/dist/libstemmer_c-2.2.0.tar.gz`
- The training dataset is also always downloaded, so: HF_DATASETS_OFFLINE=1
"""
import json
import logging
from contextlib import contextmanager, asynccontextmanager
from typing import Any

import dspy
from dspy import Example
from dspy.datasets import HotPotQA
from dspy.teleprompt import BootstrapFewShot

from providers.inference_models.orm import FoundationModelRecordOrm, FoundationModelRecord, FoundationModelResponse
from providers.orm import ProviderType
from providers.registry import ProviderRegistry
from providers_registry.echo.registry import EchoProvider

logger = logging.getLogger(__name__)


class DSPyLMProxy(dspy.LM):
    def __init__(
            self,
            inference_model: FoundationModelRecord | FoundationModelResponse,
            use_chat_endpoint: bool = True,
    ):
        super().__init__(model)
        pass

    def basic_request(self, prompt, **kwargs):
        pass

    def __call__(
            self,
            prompt: str,
            only_completed: bool = True,
            return_sorted: bool = False,
            **kwargs,
    ) -> list[dict[str, Any]]:
        """Retrieves completions from Ollama.

        Args:
            prompt (str): prompt to send to Ollama
            only_completed (bool, optional): return only completed responses and ignores completion due to length. Defaults to True.
            return_sorted (bool, optional): sort the completion choices using the returned probabilities. Defaults to False.

        Returns:
            list[dict[str, Any]]: list of completion choices
        """

        assert only_completed, "for now"
        assert return_sorted is False, "for now"

        response = self.request(prompt, **kwargs)

        choices = response["choices"]

        completed_choices = [c for c in choices if c["finish_reason"] != "length"]

        if only_completed and len(completed_choices):
            choices = completed_choices

        completions = [self._get_choice_text(c) for c in choices]

        return completions


@asynccontextmanager
async def dspy_proxy_any(type: ProviderType | None):
    # inference_model = ProviderRegistry()
    x = await anext(EchoProvider(__name__).list_models())

    with dspy.context(lm=DSPyLMProxy(x)):
        yield


@contextmanager
def dspy_proxy(inference_model: FoundationModelRecordOrm):
    with dspy.context(lm=DSPyLMProxy(inference_model)):
        yield


def xtest_providers():
    pass

    lm = dspy.OllamaLocal
    with dspy_proxy():
        pass


def xtest_philosophy():
    dataset = HotPotQA(train_seed=15586946, train_size=20, eval_seed=426205314, dev_size=20, test_size=20)
    hf_dataset_test = [x.with_inputs('question') for x in dataset.test]
    hf_dataset_train = [x.with_inputs('question') for x in dataset.train]

    class PhilosophyQA(dspy.Signature):
        """Answer open-ended questions with nuanced, insightful applications."""
        question = dspy.InputField()
        answer = dspy.OutputField(desc="often between 3 to 5 paragraphs, with concrete examples")

    generator = dspy.ChainOfThoughtWithHint(PhilosophyQA)
    logger.info(f"Finished downloading dataset: {dataset=}")

    class LifeCoachJudge(dspy.Signature):
        """Judge if the answer is thoughtful and applicable based on the context."""
        question = dspy.InputField(desc="Question to be answered")
        answer = dspy.InputField(desc="Answer for the question")
        insightful = dspy.OutputField(desc="Is the answer insightful?",
                                      prefix="Insightful[Yes/No]:")

    judge = dspy.ChainOfThought(LifeCoachJudge)

    def lifecoach_metric(example, prediction, trace):
        insightful = judge(question=example.question, answer=prediction.answer)
        return (
            int(insightful == "Yes") * 200
            # Clamp the length, so we optimize for greater than 200 characters
            + 0 if len(prediction.answer) > 200 else max(1400, len(prediction.answer))
        )

    class TheProgram(dspy.Module):
        def __init__(self):
            super().__init__()
            self.prog = generator

        def forward(self, question):
            return self.prog(question=question)

    teleprompter = BootstrapFewShot(
        metric=lifecoach_metric, max_bootstrapped_demos=4, max_labeled_demos=16, max_rounds=1, max_errors=5
    )
    optimized_program: TheProgram = teleprompter.compile(TheProgram(), trainset=hf_dataset_train)

    # Actually "run" the "program"
    result = optimized_program(question='Why am I so concerned about completing my task lists?')
    print(result)

    # Save and load
    class DictEncoder(json.JSONEncoder):
        def default(self, obj):
            if isinstance(obj, Example):
                return obj.toDict()
            else:
                return json.JSONEncoder.default(self, obj)

    try:
        print(json.dumps(optimized_program.dump_state(), indent=2, cls=DictEncoder))
    except TypeError:
        print(optimized_program.dump_state())


if __name__ == '__main__':
    ollama_lm = dspy.OllamaLocal(model='llama3-8b-instruct:bpefix-Q8_0-8k', max_tokens=256)
    dspy.settings.configure(lm=ollama_lm)

    xtest_philosophy()

    ollama_lm.inspect_history(n=1)
    print("OK")
