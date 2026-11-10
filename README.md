# cloud-svc

Production-grade Go HTTP service with containerized deployment, CI/CD security gates, Terraform AWS provisioning, Kubernetes manifests, full observability stack, and host health automation.

## Repository Structure

| Path | Purpose |
| :--- | :--- |
| `app/` | Go service source, unit tests, multi-stage `Dockerfile` |
| `.github/workflows/` | PR quality/security gates and multi-arch release workflows |
| `monitoring/` | Prometheus, Alert rules, Loki, Grafana Alloy, and provisioned dashboards |
| `scripts/` | Host health monitoring script (`system_health.sh`) and scheduling configs |
| `terraform/` | AWS EC2, VPC/SG, IAM, CloudWatch Logs, and S3 remote state IaC |
| `k8s/` | Kubernetes Deployment, Service, Ingress, ConfigMap, Secret pattern, and HPA |

> Detailed architecture, runbooks, and operational guides are populated incrementally as each component lands.
