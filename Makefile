# Every check lives here. The CI workflow only sets up the environment and
# calls a target, so a run on a laptop matches a run on GitHub.
#
# Run inside the kube-devenv image. Values arrive as Make variables:
#   BASE_REF  commit the branch started from; empty skips commit-messages

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

CHECKS   ?= /usr/share/kube-devenv/checks
BASE_REF ?= $(shell git rev-parse --verify --quiet origin/main)
export REQUIRE_SIGNOFF := 0

.PHONY: test-commit test-fast hooks lint-yaml lint-pipelines lint-renovate charts test-charts secrets commit-messages

test-commit: test-fast lint-yaml lint-pipelines lint-renovate charts test-charts commit-messages

test-fast: secrets

hooks:
	git config core.hooksPath .githooks

lint-yaml:
	yamllint -d '{extends: relaxed, rules: {line-length: disable}}' charts/*/Chart.yaml charts/*/values.yaml charts/*/ci .github/workflows

lint-pipelines:
	$(CHECKS)/pipeline-lint.sh .

lint-renovate:
	python3 -c "import json; json.load(open('renovate.json'))"

# A quick lint, not proof of an install. It lints and renders each chart with every
# ci/*values.yaml file (one per profile and actor count), then validates the output
# against the Kubernetes and CRD schemas. It cannot show that a cluster accepts the result.
charts:
	$(CHECKS)/helm-kubeconform.sh .

# What the charts render, as declared tests (helm-unittest).
test-charts:
	helm unittest charts/*

secrets:
	$(CHECKS)/secrets.sh .

commit-messages:
	$(CHECKS)/commit-messages.sh "$(BASE_REF)"
