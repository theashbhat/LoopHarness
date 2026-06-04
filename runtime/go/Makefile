BINARY := loop-runner
MODULE := github.com/getathelas/LoopHarness/runtime/go

.PHONY: build build-linux run test clean

build:
	CGO_ENABLED=0 go build -o $(BINARY) .

build-linux:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o $(BINARY) .

run: build
	./$(BINARY)

test:
	CGO_ENABLED=0 go test ./... -v

clean:
	rm -f $(BINARY)
