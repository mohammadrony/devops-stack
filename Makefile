.PHONY: test lint build up down logs

test:
	cd app && go test -v -race ./...

lint:
	cd app && test -z "$$(gofmt -l .)" && go vet ./...
	docker run --rm -i hadolint/hadolint:v2.12.0 < app/Dockerfile

build:
	docker build -t devops-stack:0.1.0 ./app

up:
	docker compose up -d --build

down:
	docker compose down

logs:
	docker compose logs -f app
