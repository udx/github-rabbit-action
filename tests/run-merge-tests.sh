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

  : > "$output_file"
  INPUT_SOURCE_DIR="$source_dir" \
  INPUT_ENV_NAME="$env_name" \
  INPUT_LIFECYCLE="$lifecycle" \
  INPUT_IS_PROTECTED="false" \
  GITHUB_OUTPUT="$output_file" \
  "$PROJECT_ROOT/bin/merge-configs.sh" >/dev/null
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

echo ""
echo "Results: $PASSED passed, $FAILED failed"

if [[ $FAILED -gt 0 ]]; then
  exit 1
fi
