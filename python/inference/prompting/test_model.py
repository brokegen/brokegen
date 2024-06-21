"""
DSPy-focused test suite for inducting new inference models

- `pip install "dspy-ai[qdrant]"`
- Behind a proxy, the `pystemmer==2.2.0.1` package tries to download a file.
  In its working directory, run: `curl -L -O https://snowballstem.org/dist/libstemmer_c-2.2.0.tar.gz`
- The training dataset is also always downloaded, so: HF_DATASETS_OFFLINE=1
"""
import json
import logging

import dspy
from dspy.datasets import DataLoader, HotPotQA
from dspy.datasets.gsm8k import GSM8K, gsm8k_metric
from dspy.evaluate import Evaluate
from dspy.teleprompt import BootstrapFewShot

from dspy.teleprompt import BootstrapFewShotWithRandomSearch
from dspy.teleprompt.ensemble import Ensemble

logger = logging.getLogger(__name__)


def test_philosophy():
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
    print(json.dumps(optimized_program.dump_state(), indent=2))


if __name__ == '__main__':
    ollama_lm = dspy.OllamaLocal(model='llama3-8b-instruct:bpefix-Q8_0-8k', max_tokens=256)
    dspy.settings.configure(lm=ollama_lm)

    test_philosophy()

    ollama_lm.inspect_history(n=1)
    print("OK")
