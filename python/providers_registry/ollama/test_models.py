"""
Content gathered from custom-imported models

- ollama --version => 0.1.33+e9ae607e
"""

api_tags_result = """
{
    "models": [
        {
            "name": "llava:34b",
            "model": "llava:34b",
            "modified_at": "2024-06-01T17:07:43.932066622Z",
            "size": 20166497526,
            "digest": "3d2d24f4667475bd28d515495b0dcc03b5a951be261a0babdb82087fc11620ee",
            "details": {
                "parent_model": "",
                "format": "gguf",
                "family": "llama",
                "families": [
                    "llama",
                    "clip"
                ],
                "parameter_size": "34B",
                "quantization_level": "Q4_0"
            }
        },
        {
            "name": "llava:34b",
            "model": "llava:34b",
            "modified_at": "2024-06-01T17:07:43.932066622Z",
            "size": 20166497526,
            "digest": "3d2d24f4667475bd28d515495b0dcc03b5a951be261a0babdb82087fc11620ee",
            "details": {
                "parent_model": "",
                "format": "gguf",
                "family": "llama",
                "families": [
                    "llama",
                    "clip"
                ],
                "parameter_size": "34B",
                "quantization_level": "Q4_0"
            }
        }
    ]
}
"""

api_show_result = """
{
    "details": {
        "families": [
            "llama"
        ],
        "family": "llama",
        "format": "gguf",
        "parameter_size": "121.9B",
        "parent_model": "",
        "quantization_level": "Q2_K"
    },
    "modelfile": "1 2 4 3",
    "parameters": "stop                           \"<|start_header_id|>\"\nstop                           \"<|end_header_id|>\"\nstop                           \"<|eot_id|>\"\nstop                           \"<|reserved_special_token\"",
    "template": "{{ if .System }}<|start_header_id|>system<|end_header_id|>\n\n{{ .System }}<|eot_id|>{{ end }}{{ if .Prompt }}<|start_header_id|>user<|end_header_id|>\n\n{{ .Prompt }}<|eot_id|>{{ end }}<|start_header_id|>assistant<|end_header_id|>\n\n{{ .Response }}<|eot_id|>"
}
"""

r2 = """
{
    "license": "licens",
    "modelfile": "1 2 4 3",
    "parameters": "stop                           \"<|im_start|>\"\nstop                           \"<|im_end|>\"",
    "template": "<|im_start|>system\n{{ .System }}<|im_end|>\n<|im_start|>user\n{{ .Prompt }}<|im_end|>\n<|im_start|>assistant\n",
    "details": {
        "parent_model": "",
        "format": "gguf",
        "family": "llama",
        "families": [
            "llama",
            "clip"
        ],
        "parameter_size": "34B",
        "quantization_level": "Q4_0"
    }
}
"""
