.PHONY: test validate-shell validate-shellcheck validate-action validate-workflow

test: validate-shell validate-shellcheck validate-action validate-workflow
	tests/run-merge-tests.sh

validate-shell:
	bash -n \
		bin/merge-configs.sh \
		bin/resolve-lifecycle.sh \
		bin/render-plan-summary.sh \
		bin/lib/config.sh \
		bin/lib/discovery.sh \
		bin/lib/github.sh \
		bin/lib/lifecycle.sh \
		bin/lib/validation.sh \
		bin/lib/environment.sh \
		bin/lib/logging.sh \
		bin/lib/merge.sh \
		bin/lib/output.sh \
		tests/run-merge-tests.sh

validate-shellcheck:
	shellcheck --external-sources --severity=error \
		bin/merge-configs.sh \
		bin/resolve-lifecycle.sh \
		bin/render-plan-summary.sh \
		bin/lib/config.sh \
		bin/lib/discovery.sh \
		bin/lib/environment.sh \
		bin/lib/github.sh \
		bin/lib/lifecycle.sh \
		bin/lib/logging.sh \
		bin/lib/merge.sh \
		bin/lib/output.sh \
		bin/lib/validation.sh \
		tests/run-merge-tests.sh

validate-action:
	yq eval '.' action.yml >/dev/null

validate-workflow:
	yq eval '.' .github/workflows/ci.yml >/dev/null
	yq eval '.' .github/workflows/release.yml >/dev/null
