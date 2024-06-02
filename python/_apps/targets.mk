python_root := $(realpath $(dir $(realpath $(lastword $(MAKEFILE_LIST))))..)/
python_amd64 := /Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11-intel64

socks_proxy_wheel := $(wildcard $(HOME)/Documents/PySocks-1.7.1-py3-none-any.whl)



.PHONY: server
dist: server
server: pyinstaller_venv := $(python_root)venv-inference-amd64
server: $(pyinstaller_venv)
	source "$(pyinstaller_venv)"/bin/activate \
		&& arch -x86_64 pyinstaller \
			--target-architecture x86_64 \
			--noupx --console \
			--noconfirm \
			--hidden-import colorlog \
			--paths $(python_root) \
			--specpath dist \
			--onefile --name "brokegen-server" \
			$(python_root)_apps/server.py
	# TODO: Check that the size of the target file hasn't dropped by too much

.PHONY: run-server
run-server: data/
	PYTHONPATH=$(python_root) \
		python $(python_root)_apps/server.py --data-dir data/ --log-level debug



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
			--paths $(python_root) \
			--specpath dist \
			--onefile --name "brokegen-ollama-proxy" \
			$(python_root)_apps/simple_proxy.py

.PHONY: run-ollama-proxy
run-ollama-proxy: data/
	PYTHONPATH=$(python_root) \
		python $(python_root)_apps/simple_proxy.py --data-dir data/
