.PHONY: test lint build up down up-monitoring down-monitoring logs

test:
	cd app && go test -v -race ./...

lint:
	cd app && test -z "$$(gofmt -l .)" && go vet ./...
	docker run --rm -i hadolint/hadolint:v2.15.1 < app/Dockerfile
	docker run --rm -v "$$(pwd):/mnt" -w /mnt koalaman/shellcheck:v0.11.0 scripts/*.sh
	docker run --rm -v "$$(pwd):/repo" -w /repo rhysd/actionlint:1.7.12
	terraform fmt -check -recursive terraform
	[ -d terraform/bootstrap/.terraform ] || terraform -chdir=terraform/bootstrap init -backend=false -input=false >/dev/null
	terraform -chdir=terraform/bootstrap validate
	[ -d terraform/.terraform ] || terraform -chdir=terraform init -backend=false -input=false >/dev/null
	terraform -chdir=terraform validate
	trivy config --ignorefile terraform/.trivyignore.yaml --tf-vars terraform/environments/staging.tfvars --severity HIGH,CRITICAL --exit-code 1 terraform
	trivy config --severity HIGH,CRITICAL --exit-code 1 k8s
	helm lint charts/devops-stack
	helm lint charts/devops-stack -f charts/devops-stack/values-staging.yaml
	helm lint charts/devops-stack -f charts/devops-stack/values-production.yaml
	trivy config --severity HIGH,CRITICAL --exit-code 1 charts/devops-stack
	trivy config --helm-values charts/devops-stack/values-staging.yaml --severity HIGH,CRITICAL --exit-code 1 charts/devops-stack
	trivy config --helm-values charts/devops-stack/values-production.yaml --severity HIGH,CRITICAL --exit-code 1 charts/devops-stack

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
