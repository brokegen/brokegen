import pytest

from history.prompting import apply_llm_template

template = """\
{{ if .System }}<|start_header_id|>system<|end_header_id|>

{{ .System }}<|eot_id|>{{ end }}{{ if .Prompt }}<|start_header_id|>user<|end_header_id|>

{{ .Prompt }}<|eot_id|>{{ end }}<|start_header_id|>assistant<|end_header_id|>

{{ .Response }}<|eot_id|>"""

user_prompt_marker = "XXX make it big, make it multiple XXX"


@pytest.mark.asyncio
async def test_llama():
    result = await apply_llm_template(
        model_template=template,
        system_message='',
        user_prompt=user_prompt_marker,
        assistant_response='',
        break_early_on_response=True,
    )

    assert result == f"""\
<|start_header_id|>user<|end_header_id|>

{user_prompt_marker}<|eot_id|><|start_header_id|>assistant<|end_header_id|>

"""
