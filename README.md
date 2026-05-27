# Rabbit Automation Action

**Declare cloud infrastructure in YAML. Deploy with `git push`.**

A GitHub Marketplace composite action that discovers YAML configuration from your `.rabbit/` directory and deploys cloud infrastructure across AWS, GCP, and Kubernetes using Terraform — all from a single `uses:` step.

---

## Quick Start

### 1. Add the workflow

Create `.github/workflows/infra-build.yaml` in your repository:

```yaml
name: Infrastructure Build

on:
  pull_request:
    branches: ["production", "staging", "develop-*"]
  push:
    branches: ["production", "staging", "develop-*"]
    paths: [".rabbit/**"]
  delete:
  schedule:
    - cron: "0 2 * * *"
  workflow_dispatch:
    inputs:
      plan_only:
        description: "Plan only (no apply)"
        type: boolean
        default: true
      environment:
        description: "Target environment"
        type: choice
        options: [development, staging, production]
        default: development
      terraform_action:
        description: "Terraform action"
        type: choice
        options: [apply, destroy]
        default: apply

permissions:
  contents: read
  pull-requests: write
  id-token: write

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: udx/github-rabbit-action@v1
        with:
          project_id: ${{ vars.GCP_PROJECT_ID }}
          gcp_auth_provider: ${{ vars.GCP_AUTH_PROVIDER }}
          gcp_service_account: ${{ vars.GCP_SERVICE_ACCOUNT }}
          aws_region: ${{ vars.AWS_REGION }}
          aws_role_arn: ${{ secrets.AWS_GITHUB_ACTIONS_ROLE_ARN }}
          slack_webhook: ${{ secrets.SLACK_WEBHOOK_ROUTINE }}
          dockerhub_username: ${{ vars.DOCKERHUB_USER_LOGIN }}
          dockerhub_token: ${{ secrets.DOCKERHUB_TOKEN_PULL_R2A }}
          r2a_version: "4.8.0"
          terraform_action: ${{ inputs.terraform_action || 'apply' }}
```

### 2. Define your infrastructure

Create YAML files inside `.rabbit/<environment>/`:

#### `.rabbit/production/10-dns.yaml`

```yaml
services:
  - module: aws-route53
    id: my-domain
    domain: example.com
    records:
      - type: A
        name: ""
        alias:
          name: d1234.cloudfront.net
          zone_id: Z2FDTNDATAQYW2
```

#### `.rabbit/production/20-cdn.yaml`

```yaml
services:
  - module: aws-cloudfront-distribution
    id: my-cdn-#{Environment}
    domain: example.com
    origins:
      - domain_name: my-app.example.com
        origin_id: app-origin
```

#### `.rabbit/production/30-app.yaml`

```yaml
services:
  - module: k8s-namespace
    id: my-app

  - module: k8s-deployment
    id: my-app
    image: my-org/my-app:latest
    replicas: 2
    ports:
      - containerPort: 8080

  - module: k8s-http-gateway-route
    id: my-app
    hostname: my-app.example.com
    service_port: 8080
```

### 3. Push and watch

- **Open a PR** → automatic plan preview posted as PR comment
- **Merge to production** → infrastructure applied automatically
- **Delete a branch** → ephemeral environment destroyed

---

## How It Works

```
┌─────────────────────────────────────────────────────┐
│ GitHub Action Trigger (push / PR / delete / manual) │
└──────────────────────┬──────────────────────────────┘
                       │
        ┌─────────────▼──────────────┐
        │   1. Resolve Lifecycle     │
        │   Branch/env policy via    │
        │   udx/rabbit-lifecycle     │
        └─────────────┬──────────────┘
                      │
        ┌─────────────▼──────────────┐
        │   2. Merge Configs         │
        │   Discover .rabbit/ YAML   │
        │   Deep merge by module::id │
         └─────────────┬──────────────┘
                       │
         ┌─────────────▼──────────────┐
         │   2. Safety Checks         │
         │   Block production manual  │
         │   Block production destroy │
         │   Auto plan-only for PRs   │
         └─────────────┬──────────────┘
                       │
         ┌─────────────▼──────────────┐
         │   3. Cloud Auth            │
         │   GCP Workload Identity    │
         │   AWS OIDC (optional)      │
         └─────────────┬──────────────┘
                       │
         ┌─────────────▼──────────────┐
         │   4. Terraform Engine      │
         │   Docker: r2a container    │
         │   Per-service init/plan/   │
         │   apply in deploy order    │
         └─────────────┬──────────────┘
                       │
         ┌─────────────▼──────────────┐
         │   5. Reporting             │
         │   Plan summary table       │
         │   PR comment               │
         │   GitHub step summary      │
         │   Slack notification       │
         └────────────────────────────┘
```

### Environment Detection

The environment is automatically resolved from the workflow event, then passed to `udx/rabbit-lifecycle` for lifecycle policy resolution:

| Trigger | Environment Source |
| --- | --- |
| `push` | Branch name (`production`, `staging`, `develop-foo`) |
| `pull_request` | Base branch (`github.base_ref`) |
| `delete` | Deleted branch ref |
| `workflow_dispatch` | User-selected input |
| `schedule` | Branch name (default branch) |

### Lifecycle Model

Infrastructure configs live in `.rabbit/` directories organized by lifecycle:

```
.rabbit/
├── production/           # Protected branches → production lifecycle
│   ├── 10-infra.yaml
│   ├── 20-app.yaml
│   └── us-east-1/        # Environment-specific overrides (smart merged)
│       └── 10-infra.yaml
├── staging/              # Root-only (no subdirectories)
│   └── infra.yaml
└── development/          # Fallback lifecycle
    ├── infra.yaml
    └── dev-andy/          # Per-developer environments
        └── infra.yaml
```

- Files are sorted by name (`10-infra.yaml` before `20-monitoring.yaml`)
- Services with the same `module::id` are deep-merged across files
- Root-level files in the configured `source_dir` are ignored (must be in a lifecycle directory)
- Only direct lifecycle roots under `source_dir` are eligible; use `source_dir: .rabbit/infra_configs` for nested config roots

See [docs/configuration.md](docs/configuration.md) for the repo-owned Rabbit config layout and merge contract.

### Plan Mode

| Trigger | Mode |
| --- | --- |
| `pull_request` | Plan only (preview changes) |
| `schedule` | Plan only (drift detection) |
| `push` | Apply (deploy changes) |
| `workflow_dispatch` | User choice |
| `delete` | Destroy (remove environment) |

### Safety Guardrails

- **Manual production apply blocked** — production changes must go through the merge pipeline
- **Production destroy blocked** — production infrastructure cannot be destroyed
- **Delete environment mismatch** — aborts if branch name doesn't match resolved environment
- **PR always plans** — pull requests never apply changes

---

## List of Modules

### AWS

| Module | Description | Order |
| --- | --- | --- |
| `aws-route53` | DNS zones and records | 5 |
| `aws-acm` | SSL/TLS certificates | 8 |
| `aws-waf` | Web Application Firewall rules | 125 |
| `aws-cloudfront-distribution` | CDN distribution with origins, behaviors, cache | 130 |

### GCP

| Module | Description | Order |
| --- | --- | --- |
| `gcp-networking` | VPC networks and firewall rules | 10 |
| `gcp-static-ip` | Regional/global static IP addresses | 15 |
| `gcp-postgresql-instance` | Cloud SQL PostgreSQL instances | 20 |
| `gcp-sql-instance` | Cloud SQL MySQL instances | 20 |
| `gcp-gke-cluster` | GKE cluster provisioning | 30 |
| `gcp-gke-nodepool` | GKE node pool configuration | 40 |
| `gcp-iam` | IAM roles and service accounts | — |
| `gcp-secret-manager` | Secret Manager entries | — |
| `gcp-storage` | Cloud Storage buckets | — |
| `gcp-monitoring` | Monitoring alert policies | 140 |

### Kubernetes

| Module | Description | Order |
| --- | --- | --- |
| `k8s-shared-http-gateway` | Shared HTTP gateway for routing | 55 |
| `k8s-namespace` | Namespace with labels and annotations | 60 |
| `k8s-secret` | Kubernetes secrets from config or GCP Secret Manager | 70 |
| `k8s-access` | RBAC roles and bindings | 80 |
| `k8s-service` | ClusterIP/LoadBalancer/NodePort services | 90 |
| `k8s-http-health-check-policy` | Health check policies for gateway routes | 92 |
| `k8s-http-gateway-route` | HTTP routing rules for gateway | 93 |
| `k8s-configmap` | ConfigMaps from inline data or files | 95 |
| `k8s-deployment` | Deployments with rolling updates | 100 |
| `k8s-memcached` | Memcached StatefulSet | 102 |
| `k8s-hpa` | Horizontal Pod Autoscaler | 110 |
| `k8s-pdb` | Pod Disruption Budget | 120 |

### Monitoring

| Module | Description | Order |
| --- | --- | --- |
| `newrelic-synthetic-monitors` | New Relic synthetic monitoring | 150 |

**Deployment Order** — services are deployed in ascending order by their module's deployment order. Destroy operations reverse the order.

---

## Configuration Reference

### Service Shape

Each service in your YAML config follows this structure:

```yaml
services:
  - module: <module-name>       # Required: Terraform module to use
    id: <unique-id>             # Required: Unique identifier for this service
    # ... module-specific fields
```

### Placeholders

Use `#{Variable}` syntax in YAML values — they're replaced at runtime:

| Placeholder | Value |
| --- | --- |
| `#{Environment}` | Resolved environment name |
| `#{Lifecycle}` | Resolved lifecycle (production/staging/development) |
| `#{GcpProject}` | GCP project ID |
| `#{GitOwner}` | GitHub repository owner |
| `#{GitRepository}` | GitHub repository name |
| `#{Namespace}` | Kubernetes namespace (derived from repo name) |
| `#{SharedProject}` | Shared GCP project ID |

Example:

```yaml
services:
  - module: k8s-deployment
    id: my-app-#{Environment}
    namespace: #{Namespace}
    image: gcr.io/#{GcpProject}/my-app:latest
```

### GCP Secret Manager References

Reference secrets directly in your YAML:

```yaml
services:
  - module: k8s-secret
    id: app-secrets
    data:
      DATABASE_URL: gcp://projects/my-project/secrets/db-url/versions/latest
```

The action automatically resolves `gcp://` prefixed values to actual secret values at deploy time.

---

## Setup Guide

### Required GitHub Variables

Set these in your repository or organization settings → Variables:

| Variable | Description |
| --- | --- |
| `GCP_PROJECT_ID` | Google Cloud project ID |
| `GCP_AUTH_PROVIDER` | GCP Workload Identity Provider resource name |
| `GCP_SERVICE_ACCOUNT` | GCP Service Account email |

### Optional GitHub Variables

| Variable | Description |
| --- | --- |
| `AWS_REGION` | AWS region (e.g., `us-east-1`) |
| `DOCKERHUB_USER_LOGIN` | Docker Hub username for image pulls |
| `K8S_CLUSTER_NAME` | GKE cluster name |
| `NEWRELIC_ACCOUNT_ID` | New Relic account ID |
| `SHARED_PROJECT` | Shared GCP project for cross-project access |

### Required GitHub Secrets

| Secret | Description |
| --- | --- |
| `SLACK_WEBHOOK_ROUTINE` | Slack incoming webhook for notifications |

### Optional GitHub Secrets

| Secret | Description |
| --- | --- |
| `AWS_GITHUB_ACTIONS_ROLE_ARN` | AWS IAM OIDC role for Route53/CloudFront/WAF/ACM |
| `DOCKERHUB_TOKEN_PULL_R2A` | Docker Hub token (paired with `DOCKERHUB_USER_LOGIN`) |
| `DOCKERHUB_HELM_TOKEN` | Docker Hub token for Helm OCI charts |
| `NEWRELIC_API_KEY` | New Relic API key |

### Workflow Permissions

```yaml
permissions:
  contents: read
  pull-requests: write    # For PR comments with plan summary
  id-token: write         # For GCP Workload Identity & AWS OIDC
```

---

## Advanced Usage

### Multi-Environment Overrides

Override specific values per environment using subdirectories:

```
.rabbit/
└── production/
    ├── 10-infra.yaml          # Base production config
    └── us-east-1/
        └── 10-infra.yaml      # Overrides for us-east-1 environment
```

Files in subdirectories are deep-merged on top of the parent directory files. Services with matching `module::id` pairs are merged, not duplicated.

### Multi-Repo Projects

For monorepo or multi-repo setups where multiple repositories share infrastructure:

```yaml
- uses: udx/github-rabbit-action@v1
  with:
    multi_repo: "true"
    shared_project: "shared-infra-project"
    # ... other inputs
```

This isolates Terraform state per repository while allowing shared GCP project access.

### Pinning R2A Version

Always pin to a specific version for reproducible builds:

```yaml
- uses: udx/github-rabbit-action@v1
  with:
    r2a_version: "4.8.0"
```

### Ephemeral Environments (Branch Delete → Destroy)

Add `delete` to your workflow triggers and matching feature branches:

```yaml
on:
  delete:  # Triggers destroy when branch is deleted
  push:
    branches: ["production", "staging", "develop-*"]
```

When a `develop-*` branch is deleted, the action automatically runs `terraform destroy` for that environment.

### Debug Mode

Enable detailed config output in logs:

```yaml
- uses: udx/github-rabbit-action@v1
  with:
    print_config: "true"
```

### Manual Dispatch with Safety Controls

The workflow dispatch inputs provide safe manual control:

- **Plan only = true** → preview changes without applying
- **Environment = production** + **Plan only = false** → blocked (safety guardrail)
- **Terraform action = destroy** + **Environment = production** → blocked

---

## Inputs Reference

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `project_id` | ✅ | — | GCP project ID |
| `gcp_auth_provider` | ✅ | — | GCP Workload Identity Provider |
| `gcp_service_account` | ✅ | — | GCP Service Account email |
| `aws_role_arn` | — | — | AWS IAM OIDC role ARN |
| `aws_region` | — | — | AWS region |
| `dockerhub_username` | — | — | Docker Hub username |
| `dockerhub_token` | — | — | Docker Hub pull token |
| `dockerhub_helm_token` | — | — | Docker Hub Helm OCI token |
| `r2a_version` | — | `latest` | R2A Docker image tag |
| `terraform_action` | — | `apply` | `apply` or `destroy` |
| `plan_only` | — | auto | Override plan mode |
| `environment` | — | auto | Override environment |
| `print_config` | — | `true` | Debug config output |
| `multi_repo` | — | `false` | Per-repo state isolation |
| `shared_project` | — | — | Shared GCP project |
| `k8s_cluster_name` | — | — | GKE cluster name |
| `newrelic_account_id` | — | — | New Relic account ID |
| `newrelic_api_key` | — | — | New Relic API key |
| `slack_webhook` | — | — | Slack webhook URL |
| `source_dir` | — | `.rabbit` | Config source directory |
| `github_token` | — | `github.token` | GitHub token passed to lifecycle resolution and used for PR comments |

## Outputs

| Output | Description |
| --- | --- |
| `environment` | Resolved environment name |
| `lifecycle` | Resolved lifecycle (production/staging/development) |
| `is_protected` | Whether GitHub reported the environment branch as protected |
| `resolution_reason` | Lifecycle rule that selected the lifecycle |
| `plan_only` | Whether run was plan-only |
| `terraform_action` | Action executed (apply/destroy/skip) |
| `has_changes` | Whether Terraform detected changes |
| `changes_msg` | Human-readable change summary |
| `cloudfront_distribution_id` | CloudFront distribution ID (if applicable) |
| `k8s_namespace` | Kubernetes namespace |
| `config_path` | Path to merged config file |

---

## What You'll See

### GitHub Step Summary

Every run writes a configuration summary and deployment results to the GitHub Actions step summary — visible directly on the Actions run page.

### PR Comments

Pull requests get an automatically updated comment with a detailed Terraform plan breakdown:

```
## Terraform Plan Summary

| Module / Service | Add | Change | Destroy |
| --- | --- | --- | --- |
| **Total** | 5 | 2 | 0 |
| `aws-cloudfront-distribution/my-cdn` | 0 | 1 | 0 |
| `k8s-deployment/my-app` | 3 | 1 | 0 |
| `k8s-http-gateway-route/my-app` | 2 | 0 | 0 |
```

### Slack Notifications

Notifications are sent when:
- Infrastructure changes are detected or applied
- Any step fails

Notifications include environment, change counts, failure stage, and a link to the action run.

---

## Pro Tips

- **Use a Docker Hub token** (`dockerhub_username` + `dockerhub_token`) to prevent rate limits when pulling the R2A image
- **Pin `r2a_version`** to a specific tag for reproducible deploys (e.g., `4.8.0` instead of `latest`)
- **Name files with numeric prefixes** (`10-dns.yaml`, `20-cdn.yaml`, `30-app.yaml`) for deterministic ordering
- **Use `#{Environment}` placeholders** in service IDs to keep configs environment-aware
- **Set `source_dir` explicitly** when configs live below `.rabbit/infra_configs` or another nested root
- **Schedule nightly runs** (`cron: "0 2 * * *"`) to detect infrastructure drift
- **Keep `.rabbit/` configs small and focused** — one concern per file

## Development

The local validation contract is documented in [docs/validation.md](docs/validation.md). Run `make test` and `dev.kit repo` before updating a PR.

---

## License

GPL-2.0
