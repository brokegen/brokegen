venv ?= venv
activate_script = $(venv)/bin/activate

.PHONY: serve
serve: $(activate_script)
	source $(activate_script) \
  && hypercorn --bind 0.0.0.0:9749 \
  	--reload \
  	--workers 8 \
  	brokegen.app:app

.PHONY: wheel
wheel:
	@:

.PHONY: python-3.11-brokegen-amd64-whl
wheel: python-3.11-brokegen-amd64-whl

# https://pip.pypa.io/en/stable/cli/pip_download/
python-3.11-brokegen-amd64-whl: $(activate_script)
	source $(activate_script) \
		&& python -m pip download \
			--dest "$@" \
			--only-binary=:all: \
			--platform macosx_14_0_universal2 --platform macosx_14_0_x86_64 \
			--python-version 311 \
			--implementation cp \
			'.[testing]'

wheel: brokegen-whl
brokegen-whl: $(activate_script)
	source $(activate_script) \
		&& pip wheel --wheel-dir=brokegen-whl '.[testing]'

.PHONY: install
install: $(activate_script)
	source $(activate_script) \
		&& pip install --upgrade pip setuptools \
		&& pip install --editable .

%/bin/activate:
	python3 -m venv "$*"
