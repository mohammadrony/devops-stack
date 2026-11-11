.PHONY: test lint build up down up-monitoring down-monitoring logs

test:
	cd app && go test -v -race ./...

lint:
	cd app && test -z "$$(gofmt -l .)" && go vet ./...
	docker run --rm -i hadolint/hadolint:v2.15.1 < app/Dockerfile
	docker run --rm -v "$$(pwd):/mnt" -w /mnt koalaman/shellcheck:v0.11.0 scripts/*.sh
	docker run --rm -v "$$(pwd):/repo" -w /repo rhysd/actionlint:1.7.12

build:
	docker build -t devops-stack:0.1.0 ./app

up:
	docker compose up -d --build

down:
	docker compose down

up-monitoring:
	docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d --build

down-monitoring:
	docker compose -f docker-compose.yml -f docker-compose.monitoring.yml down

logs:
	docker compose logs -f app
