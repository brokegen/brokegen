root_dir := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))
python_amd64 := /Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11-intel64
pyinstaller_venv := $(root_dir)venv-ingest-amd64

# As a quick smoke test, just run the top-level Python apps, and make sure they do something.
.PHONY: run-ingest
test: run-ingest
run-ingest:
	python3 $(root_dir)ingest_cli.py $(root_dir)

# Leave this a permanent .PHONY because pyinstaller will take care of rebuild checks.
.PHONY: dist-ingest
dist: dist-ingest
dist-ingest: $(pyinstaller_venv)
	pyinstaller \
		--target-architecture x86_64 \
		--noupx --console \
		--noconfirm \
		--specpath dist \
		--onefile --name "ingest-cli" \
		$(root_dir)ingest_cli.py

build: $(pyinstaller_venv)
$(pyinstaller_venv):
	arch -x86_64 $(python_amd64) -m venv "$@"
	source "$@"/bin/activate \
		&& cd "$(root_dir)" \
		&& arch -x86_64 python -m pip \
			install --editable ".[ingest]"

.PHONY: clean-ingest
clean: clean-ingest
clean-ingest:
	rm -rf "$(pyinstaller_venv)"
