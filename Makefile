.PHONY: dist
dist: build
	@:

.PHONY: build
build:
	@:

.PHONY: clean
clean:
	@:

.PHONY: test
test:
	@:


-include python/inference/targets.mk
-include python/ingest/targets.mk
