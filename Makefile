.PHONY: dist
dist:
	@:

.PHONY: build
build:
	@:

.PHONY: clean
clean:
	-rm -r build/
	-rm -r dist/

.PHONY: test
test:
	@:



-include python/_apps/targets.mk
-include python/_apps/server.mk
-include python/retrieval/targets.mk

venv:
	python3 -m venv "$@"
ifneq (,$(socks_proxy_wheel))
	source "$@"/bin/activate \
		&& pip install --no-deps $(socks_proxy_wheel) \
		&& pip install "httpx[socks]"
endif
	source "$@"/bin/activate \
		&& cd python \
		&& python -m pip \
			install --editable ".[inference,ingest,testing]"
	xcode-select --print-path
	source "$@"/bin/activate \
		&& CMAKE_ARGS="-DLLAMA_METAL=on -DLLAMA_ACCELERATE=on" \
			pip install --upgrade llama-cpp-python --no-cache-dir


data%/:
	[ -d $@/ ] || mkdir $@/
	echo "PRAGMA journal_model=wal" | sqlite3 $@/audit.db
	echo "PRAGMA journal_model=wal" | sqlite3 $@/requests-history.db

.PHONY: python-test
test: python-test
python-test: venv
python-test:
	source venv/bin/activate \
		&& PYTHONPATH=python/ pytest

.PHONY: venv-clean
clean: venv-clean
venv-clean:
	-rm -r venv



-include xcode/targets.mk

# https://github.com/Mozilla-Ocho/llamafile
# Use Mozilla Ocho `llamafile` binaries as the simplest-to-setup inference server
#
dist/llava-v1.5-7b-q4.llamafile:
	cd "$(dir $@)" && curl -L -O https://huggingface.co/Mozilla/llava-v1.5-7b-llamafile/resolve/main/llava-v1.5-7b-q4.llamafile?download=true
	@echo "[INFO] Expected filesize for $@: 4_294_064_438 bytes"
	@ls -l "$@"
	@echo "[INFO] Expected \`shasum\`: 1c77bc3d1df6be114e36a09c593e93affd1862c7"
	@shasum "$@"
	@chmod +x "$@"

dist/Mistral-7B-Instruct-v0.3.Q4_K_M.llamafile:
	cd "$(dir $@)" && curl -L -O https://huggingface.co/Mozilla/Mistral-7B-Instruct-v0.3-llamafile/resolve/main/Mistral-7B-Instruct-v0.3.Q4_K_M.llamafile?download=true
	@echo "[INFO] Expected filesize for $@: 4_408_359_087 bytes"
	@ls -l "$@"
	@echo "[INFO] Expected \`shasum\`: 3e0cc8c00ef0fe971424392491273fb2bbc3cbe3"
	@shasum "$@"
	@chmod +x "$@"

dist/mxbai-embed-large-v1-f16.llamafile:
	cd "$(dir $@)" && curl -L -O https://huggingface.co/Mozilla/mxbai-embed-large-v1-llamafile/resolve/main/mxbai-embed-large-v1-f16.llamafile?download=true
	@echo "[INFO] Expected filesize for $@: 698_955_952 bytes"
	@ls -l "$@"
	@echo "[INFO] Expected \`shasum\`: eca2e537d3129ca5cce7f2d3e929ae0a4da33ac6"
	@shasum "$@"
	@chmod +x "$@"

# Download the non-Electron binary
#
dist/ollama-darwin:
	cd "$(dir $@)" \
		&& curl -L -O https://github.com/ollama/ollama/releases/download/v0.5.2/ollama-darwin
	chmod +x "$@"
