KONG_TEST_IMAGE ?= kong/kong-gateway:3.8

.PHONY: test lint smoke release-check live-security-smoke

test:
	docker run --rm -v "$(CURDIR):/workspace:ro" -w /workspace $(KONG_TEST_IMAGE) resty spec/run.lua

lint:
	docker run --rm -v "$(CURDIR):/workspace:ro" -w /workspace $(KONG_TEST_IMAGE) resty -e 'for path in io.popen("find kong spec -name \"*.lua\""):lines() do local chunk, err = loadfile(path); assert(chunk, err) end'

smoke:
	bash scripts/smoke-gateway.sh

release-check:
	bash scripts/verify-release-assets.sh

live-security-smoke:
	bash scripts/live-security-smoke.sh
