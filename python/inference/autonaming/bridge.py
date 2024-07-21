import json
import logging

logger = logging.getLogger(__name__)


def train_autonaming():
    """
    Intended for use inducting new inference models. Run once when using a new model record.

    NB DSPy may only work well with English.

    - `pip install "dspy-ai[chromadb]"`
    - Also need to disable `openai` loading by patching the dspy package, since we don't need to go online, like at all
    - Behind a proxy, the `pystemmer==2.2.0.1` package tries to download a file.
      In its working directory, run: `curl -L -O https://snowballstem.org/dist/libstemmer_c-2.2.0.tar.gz`
    - The training dataset is also always downloaded, so: HF_DATASETS_OFFLINE=1
    """
    try:
        import dspy
        import openai
        from dspy.teleprompt import BootstrapFewShot
    except ImportError:
        logger.error(f"Couldn't load DSPy")
        return
    except openai.OpenAIError:
        logger.fatal(f"Must disable openai loading in DSPy source")
        return

    class SequenceToName(dspy.Signature):
        """
        Provides a summary of the provided chat history, suitable as a short description for a tab title.
        """
        messages = dspy.InputField(desc="Provided chat history")
        summary = dspy.OutputField(desc="Just the title, at most one sentence")

    autonamer = dspy.ChainOfThoughtWithHint(SequenceToName)

    class AutonameJudge(dspy.Signature):
        messages = dspy.InputField(desc="Provided chat history")
        summary = dspy.OutputField(desc="Just the title, at most one sentence")
        recognizable = dspy.OutputField(
            desc="Does the title capture the contents of the chat, in a recognizable way?",
            prefix="Recognizable[Yes/No]:"
        )

    judge = dspy.ChainOfThought(AutonameJudge)

    def autoname_metric(example, prediction, trace):
        # Do not give long names.
        if len(prediction.summary) > 280:
            return 0

        recognizable = judge(messages=example.messages, summary=example.summary)
        return int(recognizable == "Yes")

    # Now that we've set up what we need, generate and store the DSPy program
    # training_set = prompt_db.execute().all()
    training_set = [
        dspy.Example(
            summary="Slice the first N items in a Python Iterable",
            messages="""\
You can use `itertools.islice` to slice the first N items from an iterable. Here's an example:
```
import itertools

my_iterable = [1, 2, 3, 4, 5, 6, 7, 8, 9]  # your iterable
N = 5  # number of items to slice

sliced_iterable = itertools.islice(my_iterable, N)

print(list(sliced_iterable))  # [1, 2, 3, 4, 5]
```
In this example, `itertools.islice` returns an iterator that yields the first N elements from `my_iterable`. The `list()` function is used to convert the iterator to a list for demonstration purposes.

Note that `itertools.islice` does not return a list or a slice of the original iterable; instead, it returns an iterator that yields the sliced elements on demand. This means you can use it with infinite iterables or lazy evaluations.

If you want to get a slice from the middle or end of the iterable, you can specify a start position as the second argument:
```
sliced_iterable = itertools.islice(my_iterable, 3, 6)  # slice from index 3 to 6
print(list(sliced_iterable))  # [4, 5]
""",
        )
        .with_inputs('messages'),
        dspy.Example(
            summary="Entries from the index at the back of a book",
            messages="""\
""",
        )
        .with_inputs('messages'),
    ]

    class TheProgram(dspy.Module):
        def __init__(self):
            super().__init__()
            self.prog = autonamer

        def forward(self, messages):
            return self.prog(messages=messages)

    teleprompter = BootstrapFewShot(
        metric=autoname_metric, max_bootstrapped_demos=4, max_labeled_demos=16, max_rounds=1, max_errors=5
    )
    optimized_program: TheProgram = teleprompter.compile(TheProgram(), trainset=training_set)

    # Actually "run" the "program"
    result = optimized_program(messages="hey what's up. thanks. i like oranges and carrots because they-")
    print(result)

    # Save and load
    class DictEncoder(json.JSONEncoder):
        def default(self, obj):
            if isinstance(obj, dspy.Example):
                return obj.toDict()
            else:
                return json.JSONEncoder.default(self, obj)

    try:
        print(json.dumps(optimized_program.dump_state(), indent=2, cls=DictEncoder))
    except TypeError:
        print(optimized_program.dump_state())


if __name__ == '__main__':
    import dspy

    ollama_lm = dspy.OllamaLocal(model='llama3-8b-instruct:bpefix-Q8_0-8k', max_tokens=256)
    dspy.settings.configure(lm=ollama_lm)

    train_autonaming()

    ollama_lm.inspect_history(n=1)
    print("OK")
