.PHONY: test validate-shell validate-action validate-workflow

test: validate-shell validate-action validate-workflow
	tests/run-merge-tests.sh

validate-shell:
	bash -n \
		bin/merge-configs.sh \
		bin/lib/config.sh \
		bin/lib/lifecycle.sh \
		bin/lib/validation.sh \
		bin/lib/environment.sh \
		tests/run-merge-tests.sh

validate-action:
	yq eval '.' action.yml >/dev/null

validate-workflow:
	yq eval '.' .github/workflows/ci.yml >/dev/null
