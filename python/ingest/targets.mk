python_root := $(realpath $(dir $(realpath $(lastword $(MAKEFILE_LIST))))..)/
python_amd64 := /Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11-intel64

socks_proxy_wheel := $(wildcard $(HOME)/Documents/PySocks-1.7.1-py3-none-any.whl)
pyinstaller_ingest_venv := $(python_root)venv-ingest-amd64



.PHONY: ingest-cli
dist: ingest-cli
ingest-cli: $(pyinstaller_ingest_venv)
	source "$(pyinstaller_ingest_venv)"/bin/activate \
		&& arch -x86_64 pyinstaller \
			--target-architecture x86_64 \
			--noupx --console \
			--noconfirm \
			--specpath dist \
			--onefile --name "brokegen-ingest-cli" \
			$(python_root)ingest/ingest_cli.py

.PHONY: run-ingest
run-ingest:
	python $(python_root)ingest/ingest_cli.py $(python_root)



build: $(pyinstaller_ingest_venv)
$(pyinstaller_ingest_venv):
	arch -x86_64 $(python_amd64) -m venv "$@"
ifneq (,$(socks_proxy_wheel))
	source "$@"/bin/activate \
		&& pip install --no-deps $(socks_proxy_wheel) \
		&& pip install "httpx[socks]"
endif
	source "$@"/bin/activate \
		&& cd "$(python_root)" \
		&& arch -x86_64 python -m pip \
			install --editable ".[ingest]"

.PHONY: clean-ingest
clean: clean-ingest
clean-ingest:
	rm -rf "$(pyinstaller_ingest_venv)"
