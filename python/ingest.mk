ROOT_DIR ?= $(dir $(realpath $(lastword $(MAKEFILE_LIST))))

.PHONY: run-ingest
test: run-ingest
run-ingest:
	python3 $(ROOT_DIR)ingest_cli.py $(ROOT_DIR)

