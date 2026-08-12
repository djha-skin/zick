.POSIX:
.PHONY: all build test test-black-box clean docs

name=com.djhaskin.zick

all: build

build:
	./scripts/build

test:
	swanky '(asdf:test-system "$(name)")'

test-black-box:
	./tests/resources/scripts/test-all

docs:
	./scripts/update-docs

clean:
	- rm -f $(name)
	- rm -rf ocicl/
	- find . -name '*.fasl' -delete 2>/dev/null || true
