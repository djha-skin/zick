.POSIX:
.PHONY: all build test clean docs

name=com.djhaskin.zick

all: build

build:
	./scripts/build

test:
	swanky '(asdf:test-system "$(name)")'

docs:
	./scripts/update-docs

clean:
	- rm -f $(name)
	- rm -rf ocicl/
	- find . -name '*.fasl' -delete 2>/dev/null || true
