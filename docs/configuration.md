# Configuration Contract

`github-rabbit-action` consumes Rabbit infrastructure config from a lifecycle-rooted source directory. The default source directory is `.rabbit`, and callers can set `source_dir` when configs live under another root such as `.rabbit/infra_configs`.

## Layout

Config files must live under one of the direct lifecycle roots in `source_dir`:

```text
.rabbit/
├── production/
│   ├── 10-infra.yaml
│   └── customer-branch/
│       └── 10-infra.yaml
├── staging/
│   └── 10-infra.yaml
└── development/
    ├── 10-infra.yaml
    └── feature-branch/
        └── 10-infra.yaml
```

Root-level files in `source_dir` are ignored. Nested lifecycle roots are also ignored unless `source_dir` points at the nested root.

## Merge Order

For an externally resolved lifecycle and environment, the action discovers config files in this order:

1. Lifecycle root files, sorted by path.
2. Environment or branch override files under `<lifecycle>/<environment>`, sorted by path.

The lifecycle root is the base config. Environment or branch files override and extend that base config. Services with the same `module::id` are merged by the action's manifest merge logic.

## Lifecycle Boundary

Lifecycle, environment, protected-branch status, and resolution reason are resolved by `udx/rabbit-lifecycle` in the normal action path. This repo owns only Rabbit deployment config discovery, merge ordering, manifest merge behavior, deployment safety checks, cloud auth, Terraform/R2A execution, PR comments, summaries, and Slack notifications.

Direct local script runs that do not provide `INPUT_LIFECYCLE` use a simple compatibility fallback: explicit lifecycle name, preferred lifecycle subdirectory, then `development`.

## Source Contract

The repo-owned layout manifest is [src/configs/lifecycle-policy.yaml](../src/configs/lifecycle-policy.yaml). Its `kind: rabbitConfigLayout` declares which lifecycle roots support subdirectory overrides.

For local direct script runs, [.env.example](../.env.example) documents the merge-script environment variables that mirror action inputs and lifecycle outputs.
