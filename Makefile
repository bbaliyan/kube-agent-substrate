# Every check lives here. The CI workflow only sets up the environment and
# calls a target, so a run on a laptop matches a run on GitHub.
#
# Run inside the kube-devenv image. Values arrive as Make variables:
#   BASE_REF  commit the branch started from; empty skips commit-messages
#   IMAGE     name of the install image, for image and test-image
#   PLATFORM  target platform of image, such as linux/arm64; empty builds for this host
#
# image and test-image need Docker. Run them on the host, not in the devenv image.

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

CHECKS   ?= /usr/share/kube-devenv/checks
BASE_REF ?= $(shell git rev-parse --verify --quiet origin/main)
IMAGE    ?= substrate-install:local
PLATFORM ?=
export REQUIRE_SIGNOFF := 0

.PHONY: test-commit test-fast hooks lint-yaml lint-pipelines lint-renovate charts test-charts secrets commit-messages image test-image publish

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

# Builds the install image for the platform of this host. Nothing is pushed.
image:
	docker build $(if $(PLATFORM),--platform $(PLATFORM)) --tag "$(IMAGE)" images/substrate-install

# Runs the steps of the install Job on the real release checkout in the image:
# copy it, add the chart patches in order, then render the control plane. The
# credential provider flags must be present before the patches and gone after.
test-image: image
	docker run --rm --entrypoint sh -v "$(CURDIR)/charts/substrate-install/patches:/patches:ro" "$(IMAGE)" -euc '\
	  mkdir /tmp/work && cp -a /opt/substrate/. /tmp/work/ && \
	  mkdir /tmp/work/manifests/ate-install/patches && cp -r /patches/. /tmp/work/manifests/ate-install/patches/ && \
	  cd /tmp/work/manifests/ate-install/base && \
	  render="kustomize build --load-restrictor LoadRestrictionsNone ." && \
	  before=$$($$render | grep -c image-credential-provider || true) && \
	  kustomize edit add component $$(printf "../patches/%s " $$(ls ../patches)) && \
	  after=$$($$render | grep -c image-credential-provider || true) && \
	  echo "credential provider lines: before=$$before after=$$after" && \
	  test "$$before" -gt 0 && test "$$after" -eq 0 && \
	  ate-setup --help >/dev/null'

# Pushes the multi-arch install image and prints its digest. CI runs it on main only.
publish:
	docker buildx build --platform linux/amd64,linux/arm64 --push --tag "$(IMAGE)" --metadata-file /tmp/publish-metadata.json images/substrate-install
	@echo "Published $(IMAGE)"
	@echo "Digest: $$(python3 -c "import json; print(json.load(open('/tmp/publish-metadata.json'))['containerimage.digest'])")"
