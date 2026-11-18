# Every check lives here. The CI workflow only sets up the environment and
# calls a target, so a run on a laptop matches a run on GitHub.
#
# Run inside the kube-devenv image. Values arrive as Make variables:
#   BASE_REF  commit the branch started from; empty skips commit-messages
#   IMAGE     name of the install image, for image and test-image
#   REGISTRATION_IMAGE  name of the registration image, for image-registration and test-image-registration
#   PLATFORM  target platform of image, such as linux/arm64; empty builds for this host
#
# image, test-image and test-integration need Docker. Run them on the host, not in the devenv image.

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

CHECKS   ?= /usr/share/kube-devenv/checks
BASE_REF ?= $(shell git rev-parse --verify --quiet origin/main)
IMAGE    ?= substrate-install:local
REGISTRATION_IMAGE ?= substrate-registration:local
PLATFORM ?=
export REQUIRE_SIGNOFF := 0

.PHONY: test-commit test-fast hooks lint-yaml lint-pipelines lint-renovate charts test-charts test-register test-contract secrets commit-messages image test-image publish image-registration test-image-registration publish-registration test-integration

test-commit: test-fast lint-yaml lint-pipelines lint-renovate charts test-charts test-register test-contract commit-messages

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
# The ate.dev WorkerPool has no public JSON schema. The kube-devenv script cannot skip one kind (kubeconform env var KUBECONFORM_SKIP has no effect), so it ignores every missing schema. The unit tests assert the WorkerPool shape.
charts:
	KUBECONFORM_IGNORE_MISSING_SCHEMAS=1 $(CHECKS)/helm-kubeconform.sh .

# What the charts render, as declared tests (helm-unittest).
test-charts:
	helm unittest charts/*

# The registration script against a stub of kubectl-ate: the idle gate and the no-change rerun.
test-register:
	bash charts/substrate-registration/tests/register_test.sh

# The registration chart must plan the template names and egress hashes that the substrate-actor chart renders.
test-contract:
	for profile in aws onprem; do \
	  actor=$$(helm template x charts/substrate-actor -f charts/substrate-actor/ci/$$profile-values.yaml | sed -n 's/^  template-name: //p;s/^  egress-hash: //p' | paste -sd' ' -); \
	  plan=$$(helm template x charts/substrate-registration -f charts/substrate-registration/ci/$$profile-values.yaml | awk '/^  plan: \|/{f=1;next} f&&/^    /{print $$3, $$4;next} {f=0}' | paste -sd' ' -); \
	  test -n "$$actor" && test "$$actor" = "$$plan" || { echo "contract drift in $$profile: actor=[$$actor] plan=[$$plan]"; exit 1; }; \
	done

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
# It then does the same for the storage patch that the chart generates for each
# ci values file. The backend must appear twice (the plugin sidecar of
# ate-api-server and of atelet), the GCS default must be gone, and the keys must
# appear only with the s3-compatible profile. Needs helm and awk on the host.
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
	for profile in aws onprem; do \
	  dir=build/storage-$$profile; mkdir -p "$$dir/20-storage-profile"; \
	  cp -r charts/substrate-install/patches/. "$$dir/"; \
	  helm template r charts/substrate-install -f charts/substrate-install/ci/$$profile-values.yaml -s templates/configmap.yaml \
	    | awk '/^  patch-20-storage-profile: /{f=1;next} f&&/^    /{sub(/^    /,"");print;next} f{exit}' > "$$dir/20-storage-profile/kustomization.yaml"; \
	  docker run --rm --entrypoint sh -e PROFILE=$$profile -v "$(CURDIR)/$$dir:/patches:ro" "$(IMAGE)" -euc '\
	    mkdir /tmp/work && cp -a /opt/substrate/. /tmp/work/ && \
	    mkdir /tmp/work/manifests/ate-install/patches && cp -r /patches/. /tmp/work/manifests/ate-install/patches/ && \
	    cd /tmp/work/manifests/ate-install/base && \
	    kustomize edit add component $$(printf "../patches/%s " $$(ls ../patches)) && \
	    kustomize build --load-restrictor LoadRestrictionsNone . > /tmp/out.yaml && \
	    keys=0 && if [ "$$PROFILE" = onprem ]; then keys=2; fi && \
	    test "$$(grep -c "name: ATE_STORAGE_BACKEND$$" /tmp/out.yaml)" -eq 2 && \
	    test "$$(grep -A1 "name: ATE_STORAGE_BACKEND$$" /tmp/out.yaml | grep -c "value: s3$$")" -eq 2 && \
	    test "$$(grep -c "value: gcs$$" /tmp/out.yaml)" -eq 0 && \
	    test "$$(grep -c "name: AWS_REGION$$" /tmp/out.yaml)" -eq 2 && \
	    test "$$(grep -c "name: AWS_ENDPOINT_URL$$" /tmp/out.yaml)" -eq $$keys && \
	    test "$$(grep -c "name: AWS_ACCESS_KEY_ID$$" /tmp/out.yaml)" -eq $$keys && \
	    echo "storage profile $$PROFILE: backend set on both plugin sidecars"' || exit 1; \
	done

# Pushes the multi-arch install image and prints its digest. CI runs it on main only.
publish:
	docker buildx build --platform linux/amd64,linux/arm64 --push --tag "$(IMAGE)" --metadata-file /tmp/publish-metadata.json images/substrate-install
	@echo "Published $(IMAGE)"
	@echo "Digest: $$(python3 -c "import json; print(json.load(open('/tmp/publish-metadata.json'))['containerimage.digest'])")"

# Builds the registration image for the platform of this host. Nothing is pushed.
image-registration:
	docker build $(if $(PLATFORM),--platform $(PLATFORM)) --tag "$(REGISTRATION_IMAGE)" images/substrate-registration

# Runs the tools of the image: kubectl-ate reports its version and jq parses.
test-image-registration: image-registration
	docker run --rm --entrypoint sh "$(REGISTRATION_IMAGE)" -euc '\
	  kubectl-ate --version && echo "{\"a\":1}" | jq -e .a >/dev/null && bash --version >/dev/null'

# Pushes the multi-arch registration image and prints its digest. CI runs it on main only.
publish-registration:
	docker buildx build --platform linux/amd64,linux/arm64 --push --tag "$(REGISTRATION_IMAGE)" --metadata-file /tmp/publish-registration-metadata.json images/substrate-registration
	@echo "Published $(REGISTRATION_IMAGE)"
	@echo "Digest: $$(python3 -c "import json; print(json.load(open('/tmp/publish-registration-metadata.json'))['containerimage.digest'])")"

# Installs Substrate on a kind cluster with the charts and the production images, registers a
# sample actor and checks that it suspends and resumes. It is not part of test-commit: it needs
# Docker and takes minutes. Needs docker, kubectl, helm, jq and curl. See tests/integration/.
test-integration:
	bash tests/integration/run.sh
