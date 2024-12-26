python_root := $(realpath $(dir $(realpath $(lastword $(MAKEFILE_LIST))))..)/
python_amd64 := /Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11-intel64

# On local development system, we need to set `https_proxy` to download new pip wheels.
socks_proxy_wheel := $(wildcard $(HOME)/Documents/PySocks-1.7.1-py3-none-any.whl)
pyinstaller_inference_venv := $(python_root)venv-inference-amd64



# Leave these a permanent .PHONY because pyinstaller will take care of rebuild checks.
.PHONY: ollama-proxy
build: ollama-proxy
ollama-proxy: $(pyinstaller_inference_venv)
	source "$(pyinstaller_inference_venv)"/bin/activate \
		&& arch -x86_64 pyinstaller \
			--target-architecture x86_64 \
			--noupx --console \
			--noconfirm \
			--paths $(python_root) \
			--specpath build \
			--onefile --name "brokegen-ollama-proxy" \
			$(python_root)_apps/simple_proxy.py

.PHONY: run-ollama-proxy
run-ollama-proxy: data/
	PYTHONPATH=$(python_root) \
		python $(python_root)_apps/simple_proxy.py --data-dir data/



.PHONY: ollama-rag-proxy
build: ollama-rag-proxy
ollama-rag-proxy: $(pyinstaller_inference_venv)
	source "$(pyinstaller_inference_venv)"/bin/activate \
		&& arch -x86_64 pyinstaller \
			--target-architecture x86_64 \
			--console \
			--noconfirm \
			--paths $(python_root) \
			--specpath build \
			--onefile --name "brokegen-rag-proxy" \
			$(python_root)_apps/rag_proxy.py

.PHONY: run-ollama-rag-proxy
run-ollama-rag-proxy: data/
	PYTHONPATH=$(python_root) \
		python $(python_root)_apps/rag_proxy.py --data-dir data/



build: $(pyinstaller_inference_venv)
$(pyinstaller_inference_venv):
	arch -x86_64 $(python_amd64) -m venv "$@"
ifneq (,$(socks_proxy_wheel))
	source "$@"/bin/activate \
		&& arch -x86_64 python -m pip install --no-deps $(socks_proxy_wheel) \
		&& arch -x86_64 python -m pip install "httpx[socks]"
endif
	source "$@"/bin/activate \
		&& cd "$(python_root)" \
		&& arch -x86_64 python -m pip \
			install --editable ".[inference]"
	xcode-select --print-path
	# These llama.cpp flags are labeled "~2013 CPU Dynamic library" in ollama.
	# Probably the important baseline is AVX2, but the UI app already indicates macOS 14, which is even more limitng.
	source "$@"/bin/activate \
		&& CMAKE_ARGS="-DLLAMA_METAL=on -DLLAMA_ACCELERATE=on -DLLAMA_AVX=on -DLLAMA_AVX2=on -DLLAMA_AVX512=off -DLLAMA_FMA=on -DLLAMA_F16C=on" \
			arch -x86_64 python -m pip \
			install --upgrade 'llama-cpp-python>=0.3.5' --no-cache-dir
	# A bunch of extra Python dependencies are included that we don't use, remove them to save space
	source "$@"/bin/activate \
		&& arch -x86_64 python -m pip \
			uninstall pyarrow transformers pandas sympy

.PHONY: clean-inference
clean: clean-inference
clean-inference:
	rm -rf "$(pyinstaller_inference_venv)"
