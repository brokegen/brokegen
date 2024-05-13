python_root := $(realpath $(dir $(realpath $(lastword $(MAKEFILE_LIST))))..)/
python_amd64 := /Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11-intel64

socks_proxy_wheel := $(wildcard $(HOME)/Documents/PySocks-1.7.1-py3-none-any.whl)

.PHONY: ollama-proxy
dist: ollama-proxy
ollama-proxy: pyinstaller_venv := $(python_root)venv-inference-amd64
ollama-proxy: $(pyinstaller_venv)
	source "$(pyinstaller_venv)"/bin/activate \
		&& arch -x86_64 pyinstaller \
			--target-architecture x86_64 \
			--noupx --console \
			--noconfirm \
			--hidden-import colorlog \
			--specpath dist \
			--onefile --name "brokegen-ollama-proxy" \
			$(python_root)inference/ollama_proxy_app.py

build: $(python_root)venv-inference-amd64
$(python_root)venv-inference-amd64:
	arch -x86_64 $(python_amd64) -m venv "$@"
ifneq (,$(socks_proxy_wheel))
	source "$@"/bin/activate \
		&& pip install --no-deps $(socks_proxy_wheel)
endif
	source "$@"/bin/activate \
		&& cd "$(python_root)" \
		&& arch -x86_64 python -m pip \
			install --editable ".[inference]"

.PHONY: clean-inference
clean: clean-inference
clean-inference:
	rm -rf "$(python_root)venv-inference-amd64"
