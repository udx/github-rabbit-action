#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASSED=0
FAILED=0

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

write_yaml() {
  local path="$1"
  local body="$2"

  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$body" > "$path"
}

read_output() {
  local file="$1"
  local key="$2"

  awk -F= -v key="$key" '$1 == key { value=substr($0, length(key) + 2) } END { print value }' "$file"
}

run_merge() {
  local source_dir="$1"
  local env_name="$2"
  local lifecycle="$3"
  local output_file="$4"
  local policy_path="${5:-}"

  : > "$output_file"
  GITHUB_WORKSPACE="$ROOT" \
  INPUT_SOURCE_DIR="$source_dir" \
  INPUT_ENV_NAME="$env_name" \
  INPUT_LIFECYCLE="$lifecycle" \
  INPUT_LIFECYCLE_POLICY_PATH="$policy_path" \
  INPUT_IS_PROTECTED="false" \
  GITHUB_OUTPUT="$output_file" \
  "$PROJECT_ROOT/bin/merge-configs.sh" >/dev/null
}

run_resolve() {
  local source_dir="$1"
  local env_name="$2"
  local output_file="$3"
  local policy_path="${4:-}"
  local mock_bin="${5:-}"
  local github_token="${6:-}"
  local github_repository="${7:-}"

  : > "$output_file"
  PATH="${mock_bin:+$mock_bin:}$PATH" \
  GITHUB_WORKSPACE="$ROOT" \
  INPUT_SOURCE_DIR="$source_dir" \
  INPUT_ENV_NAME="$env_name" \
  INPUT_LIFECYCLE_POLICY_PATH="$policy_path" \
  GITHUB_TOKEN="$github_token" \
  GITHUB_REPOSITORY="$github_repository" \
  GITHUB_OUTPUT="$output_file" \
  "$PROJECT_ROOT/bin/resolve-lifecycle.sh" >/dev/null
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local name="$3"

  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS $name"
    PASSED=$((PASSED + 1))
  else
    echo "  FAIL $name - expected '$expected', got '$actual'"
    FAILED=$((FAILED + 1))
  fi
}

assert_file_exists() {
  local path="$1"
  local name="$2"

  if [[ -f "$path" ]]; then
    echo "  PASS $name"
    PASSED=$((PASSED + 1))
  else
    echo "  FAIL $name - missing '$path'"
    FAILED=$((FAILED + 1))
  fi
}

scenario() {
  echo ""
  echo "$1"
  echo "------------------------------------------------------------"
}

ROOT="$TEMP_DIR/workspace"
SOURCE="$ROOT/.rabbit"
INFRA_SOURCE="$ROOT/.rabbit/infra_configs"

scenario "Action requires caller-managed cloud credentials"
assert_eq "$(yq -r '.inputs | has("gcp_auth_provider")' "$PROJECT_ROOT/action.yml")" "false" "GCP provider input is not accepted"
assert_eq "$(yq -r '.inputs | has("gcp_service_account")' "$PROJECT_ROOT/action.yml")" "false" "GCP service account input is not accepted"
assert_eq "$(yq -r '.inputs | has("aws_role_arn")' "$PROJECT_ROOT/action.yml")" "false" "AWS role input is not accepted"
assert_eq "$(yq -r '.inputs | has("aws_region")' "$PROJECT_ROOT/action.yml")" "false" "AWS region input is not accepted"
assert_eq "$(yq -r '.inputs.state_backend.required' "$PROJECT_ROOT/action.yml")" "false" "State backend input is optional"
assert_eq "$(yq -r '.runs.steps[] | select(.name == "Upload terraform artifacts") | .uses' "$PROJECT_ROOT/action.yml")" "actions/upload-artifact@v6" "Artifact upload uses Node.js 24 action runtime"
assert_eq "$(yq -r '.runs.steps[] | select(.name == "Upload terraform plans") | .uses' "$PROJECT_ROOT/action.yml")" "actions/upload-artifact@v6" "Plan upload uses Node.js 24 action runtime"
assert_eq "$(yq -r '[.runs.steps[] | select(.uses == "google-github-actions/auth@v3" or .uses == "aws-actions/configure-aws-credentials@v6")] | length' "$PROJECT_ROOT/action.yml")" "0" "Action does not configure cloud credentials"
assert_eq "$(grep -c 'Authenticate with Google Cloud before invoking github-rabbit-action' "$PROJECT_ROOT/action.yml")" "1" "Action requires caller-provided GCP credentials"
assert_eq "$(grep -c 'AWS credentials configured by the caller workflow' "$PROJECT_ROOT/action.yml")" "1" "Action forwards caller AWS credentials"

write_yaml "$SOURCE/production/10-base.yaml" 'services:
  - module: test-module
    id: app
    replicas: 2
    base: true'

write_yaml "$SOURCE/production/main/20-override.yaml" 'services:
  - module: test-module
    id: app
    replicas: 4
    override: true'

write_yaml "$SOURCE/staging/10-stage.yaml" 'services:
  - module: test-module
    id: stage
    replicas: 1'

write_yaml "$SOURCE/staging/ignored/20-ignored.yaml" 'services:
  - module: test-module
    id: ignored
    replicas: 99'

write_yaml "$SOURCE/development/10-base.yaml" 'services:
  - module: test-module
    id: app
    replicas: 1
    base: true'

write_yaml "$SOURCE/development/dev-alice/20-override.yaml" 'services:
  - module: test-module
    id: app
    replicas: 3
    developer: alice'

write_yaml "$INFRA_SOURCE/production/10-base.yaml" 'services:
  - module: test-module
    id: infra
    replicas: 2'

write_yaml "$INFRA_SOURCE/production/main/20-override.yaml" 'services:
  - module: test-module
    id: infra
    replicas: 5'

write_yaml "$SOURCE/lifecycle-policy.yaml" 'kind: rabbitConfigLayout
version: udx.dev/rabbit-infra-config/v1
config:
  lifecycles:
    production:
      allow_subdirs: true
      protected_only: true
      is_fallback: false
    staging:
      allow_subdirs: false
      protected_only: false
      is_fallback: false
    development:
      allow_subdirs: true
      protected_only: false
      is_fallback: true'

echo "Rabbit config merge smoke tests"
echo "==============================="

scenario "Scenario: production branch uses lifecycle base plus branch override"
production_out="$TEMP_DIR/production.out"
run_merge "$SOURCE" "main" "production" "$production_out"
production_config="$(read_output "$production_out" merged_config)"
assert_file_exists "$production_config" "Merged production config exists"
assert_eq "$(read_output "$production_out" environment)" "main" "Environment output is branch name"
assert_eq "$(read_output "$production_out" lifecycle)" "production" "Lifecycle output uses pre-resolved lifecycle"
assert_eq "$(yq -r '.services[0].replicas' "$production_config")" "4" "Production override wins"
assert_eq "$(yq -r '.services[0].base' "$production_config")" "true" "Production base field is retained"
assert_eq "$(yq -r '.services[0].override' "$production_config")" "true" "Production override field is retained"

scenario "Scenario: staging lifecycle is root-only"
staging_out="$TEMP_DIR/staging.out"
run_merge "$SOURCE" "staging" "staging" "$staging_out"
staging_config="$(read_output "$staging_out" merged_config)"
assert_file_exists "$staging_config" "Merged staging config exists"
assert_eq "$(yq -r '.services | length' "$staging_config")" "1" "Staging ignores nested override directory"
assert_eq "$(yq -r '.services[0].id' "$staging_config")" "stage" "Staging uses root config"

scenario "Scenario: development branch uses lifecycle base plus branch override"
development_out="$TEMP_DIR/development.out"
run_merge "$SOURCE" "dev-alice" "development" "$development_out"
development_config="$(read_output "$development_out" merged_config)"
assert_file_exists "$development_config" "Merged development config exists"
assert_eq "$(yq -r '.services[0].replicas' "$development_config")" "3" "Development override wins"
assert_eq "$(yq -r '.services[0].base' "$development_config")" "true" "Development base field is retained"
assert_eq "$(yq -r '.services[0].developer' "$development_config")" "alice" "Development override field is retained"

scenario "Scenario: configurable source_dir supports infra_configs-style layouts"
infra_out="$TEMP_DIR/infra.out"
run_merge "$INFRA_SOURCE" "main" "production" "$infra_out"
infra_config="$(read_output "$infra_out" merged_config)"
assert_file_exists "$infra_config" "Merged infra_configs config exists"
assert_eq "$(yq -r '.services[0].replicas' "$infra_config")" "5" "infra_configs override wins"

scenario "Scenario: in-repo lifecycle resolver honors explicit and subdirectory rules"
explicit_out="$TEMP_DIR/explicit.out"
run_resolve "$SOURCE" "staging" "$explicit_out"
assert_eq "$(read_output "$explicit_out" lifecycle)" "staging" "Explicit lifecycle resolves in-repo"
assert_eq "$(read_output "$explicit_out" resolution_reason)" "explicit_lifecycle" "Explicit lifecycle reason is recorded"

subdir_out="$TEMP_DIR/subdir.out"
run_resolve "$SOURCE" "dev-alice" "$subdir_out"
assert_eq "$(read_output "$subdir_out" lifecycle)" "development" "Development subdirectory resolves in-repo"
assert_eq "$(read_output "$subdir_out" resolution_reason)" "environment_subdirectory" "Subdirectory reason is recorded"

scenario "Scenario: resolver uses a caller lifecycle policy for both policy metadata and merge"
policy_out="$TEMP_DIR/policy.out"
run_resolve "$SOURCE" "dev-alice" "$policy_out" ".rabbit/lifecycle-policy.yaml"
assert_eq "$(read_output "$policy_out" lifecycle_policy_path)" "$SOURCE/lifecycle-policy.yaml" "Caller policy path is reported"
run_merge "$SOURCE" "dev-alice" "development" "$TEMP_DIR/policy-merge.out" ".rabbit/lifecycle-policy.yaml"
assert_file_exists "$(read_output "$TEMP_DIR/policy-merge.out" merged_config)" "Merge remains compatible with caller policy"

scenario "Scenario: protected branch resolves to production"
mock_bin="$TEMP_DIR/mock-bin"
mkdir -p "$mock_bin"
write_yaml "$mock_bin/curl" "#!/usr/bin/env bash
printf '%s\\n%s\\n' '{\"protected\":true}' '200'"
chmod +x "$mock_bin/curl"
protected_out="$TEMP_DIR/protected.out"
run_resolve "$SOURCE" "main" "$protected_out" "" "$mock_bin" "test-token" "udx/github-rabbit-action"
assert_eq "$(read_output "$protected_out" lifecycle)" "production" "Protected branch resolves to production"
assert_eq "$(read_output "$protected_out" is_protected)" "true" "Protected status is recorded"
assert_eq "$(read_output "$protected_out" resolution_reason)" "protected_branch" "Protected branch reason is recorded"

echo ""
echo "Results: $PASSED passed, $FAILED failed"

if [[ $FAILED -gt 0 ]]; then
  exit 1
fi
