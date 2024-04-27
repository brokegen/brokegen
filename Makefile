venv ?= venv
activate_script = $(venv)/bin/activate

.PHONY: serve
serve: $(activate_script)
	source $(activate_script) \
  && hypercorn --bind 0.0.0.0:9749 \
  	--reload \
  	--workers 8 \
  	brokegen.app:app

.PHONY: install
install: $(activate_script)
	source $(activate_script) \
		&& pip install --upgrade pip setuptools \
		&& pip install --editable .

%/bin/activate:
	python3 -m venv "$*"
