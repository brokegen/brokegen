python_root := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))../
python_amd64 := /Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11-intel64
pyinstaller_venv := $(python_root)venv-inference-amd64

.PHONY: ollama-proxy
dist: ollama-proxy
ollama-proxy: $(pyinstaller_venv)
	pyinstaller \
		--target-architecture x86_64 \
		--noupx --console \
		--noconfirm \
		--specpath dist \
		--onefile --name "ollama-proxy" \
		$(python_root)inference/ollama_proxy_app.py

build: $(pyinstaller_venv)
$(pyinstaller_venv):
	arch -x86_64 $(python_amd64) -m venv "$@"
	source "$@"/bin/activate \
		&& cd "$(python_root)" \
		&& arch -x86_64 python -m pip \
			install --editable ".[inference]"

.PHONY: clean-inference
clean: clean-inference
clean-inference:
	rm -rf "$(pyinstaller_venv)"
