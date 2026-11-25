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

.PHONY: test-examples test-commit test-fast hooks lint-yaml lint-pipelines lint-renovate charts test-charts test-register test-contract test-template-fields secrets commit-messages image test-image publish image-registration test-image-registration publish-registration test-integration

test-commit: test-fast lint-yaml lint-pipelines lint-renovate charts test-charts test-register test-contract test-template-fields test-examples commit-messages

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
# The template name hashes the fields that make the template, listed in the pick of the helper. A field that is not in
# the list can never change the name. Each field of an actor in the schema must be in the list or be one of the fields
# below that are not part of the template, and the two charts must list the same fields.
test-template-fields:
	set -e; \
	listed() { sed -n 's/.*pick .actor \(.*\) -}}$$/\1/p' "$$1" | tr -d '"' | tr ' ' '\n' | sort; }; \
	test -n "$$(listed charts/substrate-actor/templates/_helpers.tpl)"; \
	test "$$(listed charts/substrate-actor/templates/_helpers.tpl)" = "$$(listed charts/substrate-registration/templates/_helpers.tpl)" || { echo 'the two charts hash different fields'; exit 1; }; \
	fields=$$(jq -r '.definitions.actor.properties|keys[]' charts/substrate-actor/values.schema.json); test -n "$$fields"; \
	for field in $$fields; do \
	  case "$$field" in egress|warm) continue ;; esac; \
	  listed charts/substrate-actor/templates/_helpers.tpl | grep -qx "$$field" || { echo "actor field $$field is neither in the template name hash nor in the list of fields that are not part of the template (Makefile)"; exit 1; }; \
	done

test-contract:
	for profile in aws onprem; do \
	  actor=$$(helm template x charts/substrate-actor -f charts/substrate-actor/ci/$$profile-values.yaml | sed -n 's/^  template-name: //p;s/^  egress-hash: //p' | paste -sd' ' -); \
	  plan=$$(helm template x charts/substrate-registration -f charts/substrate-registration/ci/$$profile-values.yaml | awk '/^  plan: \|/{f=1;next} f&&/^    /{print $$3, $$4;next} {f=0}' | paste -sd' ' -); \
	  test -n "$$actor" && test "$$actor" = "$$plan" || { echo "contract drift in $$profile: actor=[$$actor] plan=[$$plan]"; exit 1; }; \
	done

# The ready-to-use values in examples/onprem must lint, render and pass the schemas of each chart.
# The install chart renders the stub CRD for the GKE PodMonitoring kind with these values. A placeholder digest stands in for the image of the install and registration charts.
test-examples:
	set -e; E=examples/onprem; \
	digest=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd; \
	for pair in install:install workers:workers actor:actors registration:actors; do \
	  chart=$${pair%%:*}; file=$$E/$${pair##*:}-values.yaml; \
	  set --; case $$chart in actor|workers) ;; *) set -- --set image.digest=$$digest;; esac; \
	  helm lint charts/substrate-$$chart -f $$file "$$@" >/dev/null; \
	  helm template x charts/substrate-$$chart -f $$file "$$@" | kubeconform -strict -ignore-missing-schemas -summary >/dev/null; \
	  echo "examples/onprem: $$chart renders"; \
	done
	helm template x charts/substrate-install -f examples/onprem/install-values.yaml -s templates/configmap.yaml | grep -q 'value: http://rustfs.rustfs.svc:9000$$'
	helm template x charts/substrate-install -f examples/onprem/install-values.yaml -s templates/configmap.yaml | grep -q 'patch-25-atelet-selinux'
	helm template x charts/substrate-install -f examples/onprem/install-values.yaml -s templates/podmonitoring-crd.yaml | grep -q 'name: podmonitorings.monitoring.googleapis.com$$'
	helm template x charts/substrate-workers -f examples/onprem/workers-values.yaml | grep -q 'kind: MutatingAdmissionPolicy$$'

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
# appear only with the s3-compatible profile. It last renders the Postgres sizing
# patch with the default values and with changed values, and applies it to the
# real postgres manifest with the command that the chart gives the Job (read from
# helm template, so a drift fails here): the requests, the limits and the volume
# claim must show the numbers. With no StatefulSet named postgres, it must fail.
# Needs helm and awk on the host.
test-image: image
	IMAGE="$(IMAGE)" bash tests/install-image/test.sh
	IMAGE="$(IMAGE)" bash tests/egress-ca/test-image.sh

# Pushes the multi-arch install image and prints its digest. CI runs it on main only.
publish:
	docker buildx build --platform linux/amd64,linux/arm64 --push --tag "$(IMAGE)" --metadata-file /tmp/publish-metadata.json images/substrate-install
	@echo "Published $(IMAGE)"
	@echo "Digest: $$(python3 -c "import json; print(json.load(open('/tmp/publish-metadata.json'))['containerimage.digest'])")"

# Builds the registration image for the platform of this host. Nothing is pushed.
image-registration:
	docker build $(if $(PLATFORM),--platform $(PLATFORM)) --tag "$(REGISTRATION_IMAGE)" images/substrate-registration

# Runs the tools of the image: kubectl-ate reports its version, jq parses and curl starts.
test-image-registration: image-registration
	docker run --rm --entrypoint sh "$(REGISTRATION_IMAGE)" -euc '\
	  kubectl-ate --version && echo "{\"a\":1}" | jq -e .a >/dev/null && bash --version >/dev/null && curl --version >/dev/null'

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
