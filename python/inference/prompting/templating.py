import re

from _util.typing import PromptText, TemplatedPromptText


async def apply_llm_template(
        model_template: str,
        system_message: PromptText | None,
        user_prompt: PromptText | None,
        assistant_response: PromptText | None,
        break_early_on_response: bool = False,
) -> TemplatedPromptText:
    """
    Use the world's most terrible regexes to parse the Ollama template format

    TODO: Use pip `transformers` library to build from templates/etc
    """
    template1 = model_template
    try:
        if_pattern = r'{{-?\s*if\s+(\.[^\s]+)\s*}}(.*?){{-?\s*end\s*}}'
        while True:
            match = next(re.finditer(if_pattern, template1, re.DOTALL))
            if_match, block = match.groups()

            if system_message and if_match == '.System':
                substituted_block = block
            elif user_prompt and if_match == '.Prompt':
                substituted_block = block
            elif assistant_response and if_match == '.Response':
                substituted_block = block
            else:
                substituted_block = ''

            template1 = re.sub(if_pattern, lambda m: substituted_block, template1, count=1, flags=re.DOTALL)

    except StopIteration:
        pass

    # And then substitute in the concrete values
    response_used_once: bool = False
    template3 = template1
    try:
        real_pattern = r'{{\s*(\.[^\s]+?)\s*\}}'
        while True:
            match = next(re.finditer(real_pattern, template3, re.DOTALL))
            (real_match,) = match.groups()

            if system_message and real_match == '.System':
                substituted_block = system_message
            elif user_prompt and real_match == '.Prompt':
                substituted_block = user_prompt
            elif real_match == '.Response':
                if break_early_on_response:
                    # Actually, we should just plain exit right after this match.
                    template3 = template3[:match.start()]
                    # But also, prepend the assistant prompt, so the LLM continues to elaborate
                    template3 += assistant_response or ''
                    response_used_once = True
                    break
                else:
                    substituted_block = assistant_response or ''
                    response_used_once = True
            else:
                substituted_block = ''

            template3 = re.sub(real_pattern, lambda m: substituted_block, template3, count=1, flags=re.DOTALL)

    except StopIteration:
        pass

    # For some model templates (mistral), `.Response` doesn't even show up in the template.
    # Add it, if needed.
    if not response_used_once:
        if assistant_response:
            template3 += '\n'
            template3 += assistant_response

    return template3
