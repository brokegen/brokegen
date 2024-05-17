python_root := $(realpath $(dir $(realpath $(lastword $(MAKEFILE_LIST))))..)/
python_amd64 := /Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11-intel64

# On local development system, we need to set `https_proxy` to download new pip wheels.
socks_proxy_wheel := $(wildcard $(HOME)/Documents/PySocks-1.7.1-py3-none-any.whl)



.PHONY: run-ingest
run-ingest:
	python $(python_root)ingest_cli.py $(python_root)

# Leave this a permanent .PHONY because pyinstaller will take care of rebuild checks.
.PHONY: ingest-cli
dist: ingest-cli
ingest-cli: pyinstaller_venv := $(python_root)venv-ingest-amd64
ingest-cli: $(pyinstaller_venv)
	source "$(pyinstaller_venv)"/bin/activate \
		&& arch -x86_64 pyinstaller \
			--target-architecture x86_64 \
			--noupx --console \
			--noconfirm \
			--specpath dist \
			--onefile --name "brokegen-ingest-cli" \
			$(python_root)ingest_cli.py



build: $(python_root)venv-ingest-amd64
$(python_root)venv-ingest-amd64:
	arch -x86_64 $(python_amd64) -m venv "$@"
ifneq (,$(socks_proxy_wheel))
	source "$@"/bin/activate \
		&& pip install --no-deps $(socks_proxy_wheel) \
		&& pip install "httpx[socks]"
endif
	source "$@"/bin/activate \
		&& cd "$(python_root)" \
		&& arch -x86_64 python -m pip \
			install --editable ".[ingest,testing]"

.PHONY: clean-ingest
clean: clean-ingest
clean-ingest:
	rm -rf "$(python_root)venv-ingest-amd64"
