KONG_TEST_IMAGE ?= kong/kong-gateway:3.8

.PHONY: test lint

test:
	docker run --rm -v "$(CURDIR):/workspace:ro" -w /workspace $(KONG_TEST_IMAGE) resty spec/run.lua

lint:
	docker run --rm -v "$(CURDIR):/workspace:ro" -w /workspace $(KONG_TEST_IMAGE) sh -c 'find kong spec -name "*.lua" -print0 | xargs -0 -n1 resty -e "assert(loadfile(arg[1]))"'
