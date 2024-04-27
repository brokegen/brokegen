venv ?= venv
activate_script = $(venv)/bin/activate

.PHONY: install
install: $(activate_script)
	source $(activate_script) \
		&& pip install --upgrade pip setuptools

%/bin/activate:
	python3 -m venv "$*"

