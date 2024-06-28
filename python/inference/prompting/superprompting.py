import logging
import random
import types

import fastapi
from transformers import T5Tokenizer, T5ForConditionalGeneration

from _util.typing import TemplatedPromptText

logger = logging.getLogger(__name__)


class ModelManager:
    torch_module: types.ModuleType | None = None
    model_data_dir: str

    tokenizer: T5Tokenizer | None = None
    model: T5ForConditionalGeneration | None = None

    def __init__(self, data_dir: str):
        self.model_data_dir = data_dir

        try:
            import torch
            self.torch_module = torch
        except ImportError:
            pass

    @staticmethod
    def download_model(
            data_dir: str,
            hf_model_name: str = "roborovski/superprompt-v1",
    ):
        try:
            import torch
        except ImportError:
            logger.error(f"Couldn't find pytorch, superprompting inference will fail")
            return

        tokenizer = T5Tokenizer.from_pretrained(hf_model_name)
        tokenizer.save_pretrained(data_dir)

        model = T5ForConditionalGeneration.from_pretrained(hf_model_name, torch_dtype=torch.float16)
        model.save_pretrained(data_dir)

    def load(self):
        if self.torch_module is None:
            return

        if self.tokenizer is None:
            self.tokenizer = T5Tokenizer.from_pretrained(self.model_data_dir)

        if self.model is None:
            self.model = T5ForConditionalGeneration.from_pretrained(
                self.model_data_dir,
                torch_dtype=self.torch_module.float32
            )

    def unload(self):
        self.tokenizer = None
        self.model = None

    def __call__(
            self,
            input_text: TemplatedPromptText,
            max_new_tokens: int = 100,
            repetition_penalty: float = 2,
            temperature: float = 0.5,
            top_p: float = 0.9,
            top_k: int = 1,
            seed: int | None = None,
    ) -> str | None:
        if self.torch_module is None:
            return None

        self.torch_module.manual_seed(seed or random.randint(1, 1000000))
        if seed is None:
            if temperature == 1:
                temperature = 0.95
            if top_p == 1:
                top_p = 0.95

        if self.torch_module.cuda.is_available():
            device = 'cuda'
        else:
            device = 'cpu'

        input_ids = self.tokenizer(input_text, return_tensors="pt").input_ids.to(device)
        if self.torch_module.cuda.is_available():
            self.model.to('cuda')

        # TODO: Add InferenceEvent
        outputs = self.model.generate(
            input_ids,
            max_new_tokens=max_new_tokens,
            repetition_penalty=repetition_penalty,
            do_sample=True,
            emperature=temperature,
            top_p=top_p,
            top_k=top_k,
        )

        return (
            self.tokenizer.decode(outputs[0])
            .replace("<pad>", "")
            .replace("</s>", "")
            .strip()
        )


loaded_mm: ModelManager | None = None


def install_routes(
        router_ish: fastapi.FastAPI | fastapi.routing.APIRouter,
        data_dir: str,
) -> None:
    global loaded_mm
    loaded_mm = ModelManager(data_dir)

    @router_ish.put("/superprompting/download-files")
    async def superprompting_download():
        ModelManager.download_model(data_dir)

    @router_ish.get(
        "/superprompting",
        response_model=None,
    )
    async def superprompting(
            input_text: TemplatedPromptText,
    ) -> str:
        loaded_mm.load()
        return loaded_mm(input_text)


if __name__ == '__main__':
    import sys

    loaded_mm = ModelManager(sys.argv[1])
    loaded_mm.download_model(sys.argv[1])

    while True:
        prompt: TemplatedPromptText = input("Enter original prompt: ")

        loaded_mm.load()
        result = loaded_mm(prompt)
        if result is not None:
            print(result)
            print()
        else:
            print("Failed")
            print()
