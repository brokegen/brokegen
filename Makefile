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



-include python/inference/targets.mk
-include python/ingest/targets.mk

venv:
	python3 -m venv "$@"
ifneq (,$(socks_proxy_wheel))
	source "$@"/bin/activate \
		&& pip install --no-deps $(socks_proxy_wheel)
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
		&& pytest

.PHONY: venv-clean
clean: venv-clean
venv-clean:
	-rm -r venv
