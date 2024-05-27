"""
Content gathered from custom-imported models

- ollama --version => 0.1.33+e9ae607e
"""

api_tags_result = """
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
    "digest": "fa475f107201e73560279adcfd8727a6a4b9b138eee7a90b1c6a93eb007c7a77",
    "model": "llama3-120b-instruct:Q2_K",
    "modified_at": "2024-05-17T01:41:20.230336512Z",
    "name": "llama3-120b-instruct:Q2_K",
    "size": 45098777019
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
    "modelfile": "# Modelfile generate by \"ollama show\"\n# To build a new Modelfile based on this, replace FROM with:\n# FROM llama3-120b-instruct:Q2_K\n\nFROM ~/.ollama/models/blobs/sha256-84e5f41ad998aeaae554ab86dcb2b69c739beab10645849d09fbc55dda8d92f7\nTEMPLATE \"{{ if .System }}<|start_header_id|>system<|end_header_id|>\n\n{{ .System }}<|eot_id|>{{ end }}{{ if .Prompt }}<|start_header_id|>user<|end_header_id|>\n\n{{ .Prompt }}<|eot_id|>{{ end }}<|start_header_id|>assistant<|end_header_id|>\n\n{{ .Response }}<|eot_id|>\"\nPARAMETER stop <|start_header_id|>\nPARAMETER stop <|end_header_id|>\nPARAMETER stop <|eot_id|>\nPARAMETER stop <|reserved_special_token\n",
    "parameters": "stop                           \"<|start_header_id|>\"\nstop                           \"<|end_header_id|>\"\nstop                           \"<|eot_id|>\"\nstop                           \"<|reserved_special_token\"",
    "template": "{{ if .System }}<|start_header_id|>system<|end_header_id|>\n\n{{ .System }}<|eot_id|>{{ end }}{{ if .Prompt }}<|start_header_id|>user<|end_header_id|>\n\n{{ .Prompt }}<|eot_id|>{{ end }}<|start_header_id|>assistant<|end_header_id|>\n\n{{ .Response }}<|eot_id|>"
}
"""
