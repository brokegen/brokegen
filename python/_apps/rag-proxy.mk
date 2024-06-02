python_root := $(realpath $(dir $(realpath $(lastword $(MAKEFILE_LIST))))..)/
python_amd64 := /Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11-intel64

socks_proxy_wheel := $(wildcard $(HOME)/Documents/PySocks-1.7.1-py3-none-any.whl)



.PHONY: rag-proxy
dist: rag-proxy
rag-proxy: pyinstaller_venv := $(python_root)venv-inference-amd64
rag-proxy: $(pyinstaller_venv)
	source "$(pyinstaller_venv)"/bin/activate \
		&& arch -x86_64 pyinstaller \
			--target-architecture x86_64 \
			--console \
			--noconfirm \
			--hidden-import colorlog \
			--paths $(python_root) \
			--specpath dist \
			--onefile --name "brokegen-rag-proxy" \
			$(python_root)_apps/rag_proxy.py

.PHONY: run-rag-proxy
run-rag-proxy: data/
	PYTHONPATH=$(python_root) \
		python $(python_root)_apps/rag_proxy.py --data-dir data/



build: $(python_root)venv-inference-amd64
$(python_root)venv-inference-amd64:
	arch -x86_64 $(python_amd64) -m venv "$@"
ifneq (,$(socks_proxy_wheel))
	source "$@"/bin/activate \
		&& pip install --no-deps $(socks_proxy_wheel) \
		&& pip install "httpx[socks]"
endif
	source "$@"/bin/activate \
		&& cd "$(python_root)" \
		&& arch -x86_64 python -m pip \
			install --editable ".[inference,testing]"

.PHONY: clean-inference
clean: clean-inference
clean-inference:
	rm -rf "$(python_root)venv-inference-amd64"
