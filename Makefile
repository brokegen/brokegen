.PHONY: dist
dist: build
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



-include python/history/targets.mk
-include python/inference/targets.mk
-include python/ingest/targets.mk

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
build: llava-v1.5-7b-q4.llamafile
llava-v1.5-7b-q4.llamafile:
	curl -L -O https://huggingface.co/Mozilla/llava-v1.5-7b-llamafile/resolve/main/llava-v1.5-7b-q4.llamafile?download=true
	chmod +x "$@"

mistral-7b-instruct-v0.2.Q8_0.llamafile:
	curl -L -O https://huggingface.co/Mozilla/Mistral-7B-Instruct-v0.2-llamafile/resolve/main/mistral-7b-instruct-v0.2.Q8_0.llamafile?download=true
	chmod +x "$@"

