# Rabbit Automation Action

**Declare cloud infrastructure in YAML. Deploy with `git push`.**

A GitHub Marketplace composite action that discovers YAML configuration from your `.rabbit/` directory and deploys cloud infrastructure across AWS, GCP, Azure, and Kubernetes using OpenTofu — all from a single `uses:` step.

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
  workflow_dispatch:
    inputs:
      plan_only:
        description: "Plan only (no apply)"
        type: boolean
        default: true
      terraform_action:
        description: "Action"
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
      - uses: actions/checkout@v5

      # Authenticate with your cloud provider(s) before calling the action
      - uses: google-github-actions/auth@v3
        with:
          workload_identity_provider: ${{ vars.GCP_WORKLOAD_IDENTITY_PROVIDER }}
          service_account: ${{ vars.GCP_SERVICE_ACCOUNT }}

      - uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: ${{ secrets.AWS_GITHUB_ACTIONS_ROLE_ARN }}
          aws-region: us-east-1

      - uses: udx/github-rabbit-action@v5
        with:
          project_id: ${{ vars.GCP_PROJECT_ID }}
          dockerhub_username: ${{ vars.DOCKERHUB_USER_LOGIN }}
          dockerhub_token: ${{ secrets.DOCKERHUB_TOKEN_PULL_R2A }}
          slack_webhook: ${{ secrets.SLACK_WEBHOOK_ROUTINE }}
          terraform_action: ${{ inputs.terraform_action || 'apply' }}
```

#### AWS-only with S3 state backend

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5

      - uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: ${{ secrets.AWS_GITHUB_ACTIONS_ROLE_ARN }}
          aws-region: us-east-1

      - uses: udx/github-rabbit-action@v5
        with:
          project_id: my-project
          state_backend: s3
          state_backend_config: |
            bucket = "my-tfstate-bucket"
            region = "us-east-1"
          state_prefix_key: key
          terraform_action: ${{ inputs.terraform_action || 'apply' }}
```

#### Azure with azurerm state backend

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5

      - uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      - uses: udx/github-rabbit-action@v5
        with:
          project_id: my-project
          state_backend: azurerm
          state_backend_config: |
            storage_account_name = "mytfstate"
            container_name       = "tfstate"
            resource_group_name  = "my-rg"
          state_prefix_key: key
          terraform_action: ${{ inputs.terraform_action || 'apply' }}
```

### 2. Define your infrastructure

Create YAML files inside `.rabbit/<environment>/`:

#### `.rabbit/production/10-dns.yaml`

```yaml
services:
  - module: aws-route53
    id: my-domain
    configurations:
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
    configurations:
      domain: example.com
      origins:
        app:
          domain_name: my-app.example.com
          origin_id: app-origin
```

### 3. Push and watch

- **Open a PR** → automatic plan preview posted as PR comment
- **Merge to production** → infrastructure applied automatically
- **Delete a branch** → ephemeral environment destroyed

---

## Authentication

Cloud authentication is **your workflow's responsibility**. The action auto-detects credentials from the environment:

| Provider | Auth Action | Detected Via |
| --- | --- | --- |
| GCP | `google-github-actions/auth@v3` | `GOOGLE_APPLICATION_CREDENTIALS` file |
| AWS | `aws-actions/configure-aws-credentials@v6` | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` |
| Azure | `azure/login@v2` | `ARM_CLIENT_ID` / `ARM_CLIENT_SECRET` / `ARM_TENANT_ID` / `ARM_SUBSCRIPTION_ID` |

Only include auth steps for the providers you need. The action passes detected credentials to the IaC engine container automatically.

---

## State Backend

By default, Terraform/OpenTofu state is stored in GCS (Google Cloud Storage). Override with any supported backend:

| Backend | `state_backend` | `state_prefix_key` | Config Keys |
| --- | --- | --- | --- |
| GCS (default) | — | `prefix` | `bucket` |
| S3 | `s3` | `key` | `bucket`, `region` |
| Azure Blob | `azurerm` | `key` | `storage_account_name`, `container_name`, `resource_group_name` |
| HTTP | `http` | — | `address`, `lock_address`, `unlock_address` |
| Consul | `consul` | — | `address`, `path` |

The backend override is injected at runtime using OpenTofu override files — no module changes needed.

---

## How It Works

```
┌─────────────────────────────────────────────────────┐
│ GitHub Action Trigger (push / PR / delete / manual) │
└──────────────────────┬──────────────────────────────┘
                       │
         ┌─────────────▼──────────────┐
         │   1. Merge Configs         │
         │   Discover .rabbit/ YAML   │
         │   Resolve lifecycle        │
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
         │   3. IaC Engine            │
         │   Docker: r2a container    │
         │   OpenTofu (default) or    │
         │   Terraform (via IAC_TOOL) │
         │   Per-service init/plan/   │
         │   apply in deploy order    │
         └─────────────┬──────────────┘
                       │
         ┌─────────────▼──────────────┐
         │   4. Reporting             │
         │   Plan summary table       │
         │   PR comment               │
         │   GitHub step summary      │
         │   Slack notification       │
         └────────────────────────────┘
```

### Environment Detection

The environment is automatically resolved from:

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
- Root-level files in `.rabbit/` are ignored (must be in a lifecycle directory)

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
    configurations:
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

### GCP Secret Manager References

Reference secrets directly in your YAML:

```yaml
services:
  - module: k8s-secret
    id: app-secrets
    configurations:
      data:
        DATABASE_URL: gcp://projects/my-project/secrets/db-url/versions/latest
```

The action automatically resolves `gcp://` prefixed values to actual secret values at deploy time (requires GCP auth).

---

## Inputs Reference

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `project_id` | yes | — | Project identifier for state isolation |
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
| `state_backend` | — | `gcs` | Backend type (`s3`, `azurerm`, `http`, `consul`) |
| `state_backend_config` | — | — | Backend config as key=value lines |
| `state_prefix_key` | — | `prefix` | Backend key for state path |
| `source_dir` | — | `.rabbit` | Config source directory |
| `github_token` | — | `github.token` | GitHub token for PR comments |

## Outputs

| Output | Description |
| --- | --- |
| `environment` | Resolved environment name |
| `lifecycle` | Resolved lifecycle (production/staging/development) |
| `plan_only` | Whether run was plan-only |
| `terraform_action` | Action executed (apply/destroy/skip) |
| `has_changes` | Whether Terraform detected changes |
| `changes_msg` | Human-readable change summary |
| `cloudfront_distribution_id` | CloudFront distribution ID (if applicable) |
| `k8s_namespace` | Kubernetes namespace |
| `config_path` | Path to merged config file |

---

## License

GPL-2.0
