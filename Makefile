# Every check lives here. The CI workflow only sets up the environment and
# calls a target, so a run on a laptop matches a run on GitHub.
#
# Run inside the kube-devenv image. Values arrive as Make variables:
#   BASE_REF  commit the branch started from; empty skips commit-messages
#   IMAGE     name of the install image, for image and test-image
#   REGISTRATION_IMAGE  name of the registration image, for image-registration and test-image-registration
#   PLATFORM  target platform of image, such as linux/arm64; empty builds for this host
#
# image, test-image, test-shim and test-integration need Docker. Run them on the host, not in the devenv image.

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

CHECKS   ?= /usr/share/kube-devenv/checks
BASE_REF ?= $(shell git rev-parse --verify --quiet origin/main)
IMAGE    ?= substrate-install:local
REGISTRATION_IMAGE ?= substrate-registration:local
PLATFORM ?=
export REQUIRE_SIGNOFF := 0

.PHONY: test-examples test-commit test-fast hooks lint-yaml lint-pipelines lint-renovate charts test-charts test-register test-idle-suspend test-contract test-shim secrets commit-messages image test-image publish image-registration test-image-registration publish-registration test-integration

test-commit: test-fast lint-yaml lint-pipelines lint-renovate charts test-charts test-register test-idle-suspend test-contract test-examples commit-messages

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

# The idle-suspend script against stubs of kubectl-ate and curl: idle, each busy signal, each query error, and the actors that are not running or missing.
test-idle-suspend:
	bash charts/substrate-idle-suspend/tests/idle_suspend_test.sh

# The registration chart must plan the template names and egress hashes that the substrate-actor chart renders.
test-contract:
	for profile in aws onprem; do \
	  actor=$$(helm template x charts/substrate-actor -f charts/substrate-actor/ci/$$profile-values.yaml | sed -n 's/^  template-name: //p;s/^  egress-hash: //p' | paste -sd' ' -); \
	  plan=$$(helm template x charts/substrate-registration -f charts/substrate-registration/ci/$$profile-values.yaml | awk '/^  plan: \|/{f=1;next} f&&/^    /{print $$3, $$4;next} {f=0}' | paste -sd' ' -); \
	  test -n "$$actor" && test "$$actor" = "$$plan" || { echo "contract drift in $$profile: actor=[$$actor] plan=[$$plan]"; exit 1; }; \
	done

# The webhook shim that the substrate-actor chart renders, run in Docker against a stand-in router that needs a client certificate.
# It checks the token rules, the mTLS hop and the rotation of the secret file. Needs docker, helm, openssl and curl on the host.
test-shim:
	bash tests/shim/run.sh

# The ready-to-use values in examples/onprem must lint, render and pass the schemas of each chart.
# The stub CRD for the GKE PodMonitoring kind must validate too. A placeholder digest stands in for the image of the install, registration and idle-suspend charts.
test-examples:
	set -e; E=examples/onprem; \
	digest=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd; \
	for pair in install:install workers:workers actor:actors idle-suspend:idle-suspend registration:actors; do \
	  chart=$${pair%%:*}; file=$$E/$${pair##*:}-values.yaml; \
	  set --; case $$chart in actor|workers) ;; *) set -- --set image.digest=$$digest;; esac; \
	  helm lint charts/substrate-$$chart -f $$file "$$@" >/dev/null; \
	  helm template x charts/substrate-$$chart -f $$file "$$@" | kubeconform -strict -ignore-missing-schemas -summary >/dev/null; \
	  echo "examples/onprem: $$chart renders"; \
	done
	helm template x charts/substrate-install -f examples/onprem/install-values.yaml -s templates/configmap.yaml | grep -q 'value: http://rustfs.rustfs.svc:9000$$'
	helm template x charts/substrate-install -f examples/onprem/install-values.yaml -s templates/configmap.yaml | grep -q 'patch-25-atelet-selinux'
	kubeconform -strict -ignore-missing-schemas -summary examples/onprem/podmonitoring-crd.yaml
	grep -q 'name: podmonitorings.monitoring.googleapis.com$$' examples/onprem/podmonitoring-crd.yaml
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
	  helm template r charts/substrate-install -f charts/substrate-install/ci/$$profile-values.yaml -s templates/configmap.yaml \
	    | awk '/^  patch-25-atelet-selinux: /{f=1;next} f&&/^    /{sub(/^    /,"");print;next} f{exit}' > "$$dir.selinux"; \
	  if [ -s "$$dir.selinux" ]; then mkdir "$$dir/25-atelet-selinux" && mv "$$dir.selinux" "$$dir/25-atelet-selinux/kustomization.yaml"; fi; \
	  docker run --rm --entrypoint sh -e PROFILE=$$profile -v "$(CURDIR)/$$dir:/patches:ro" "$(IMAGE)" -euc '\
	    mkdir /tmp/work && cp -a /opt/substrate/. /tmp/work/ && \
	    mkdir /tmp/work/manifests/ate-install/patches && cp -r /patches/. /tmp/work/manifests/ate-install/patches/ && \
	    cd /tmp/work/manifests/ate-install/base && \
	    kustomize edit add component $$(printf "../patches/%s " $$(ls ../patches)) && \
	    kustomize build --load-restrictor LoadRestrictionsNone . > /tmp/out.yaml && \
	    keys=0 && if [ "$$PROFILE" = onprem ]; then keys=2; fi && \
	    spc=0 && if [ "$$PROFILE" = onprem ]; then spc=1; fi && \
	    test "$$(grep -c "type: spc_t$$" /tmp/out.yaml)" -eq $$spc && \
	    test "$$(grep -c "name: ATE_STORAGE_BACKEND$$" /tmp/out.yaml)" -eq 2 && \
	    test "$$(grep -A1 "name: ATE_STORAGE_BACKEND$$" /tmp/out.yaml | grep -c "value: s3$$")" -eq 2 && \
	    test "$$(grep -c "value: gcs$$" /tmp/out.yaml)" -eq 0 && \
	    test "$$(grep -c "name: AWS_REGION$$" /tmp/out.yaml)" -eq 2 && \
	    test "$$(grep -c "name: AWS_ENDPOINT_URL$$" /tmp/out.yaml)" -eq $$keys && \
	    test "$$(grep -c "name: AWS_ACCESS_KEY_ID$$" /tmp/out.yaml)" -eq $$keys && \
	    echo "profile $$PROFILE: backend set on both plugin sidecars, spc_t on $$spc atelet pod spec"' || exit 1; \
	done
	for case in default changed renamed; do \
	  case $$case in \
	    default|renamed) sets=""; req='cpu: "2" memory: 1Gi'; lim='cpu: "16" memory: 2Gi'; storage=500Gi;; \
	    changed) sets="--set postgres.resources.requests.cpu=500m --set postgres.resources.requests.memory=512Mi --set-string postgres.resources.limits.cpu=4 --set postgres.resources.limits.memory=3Gi --set postgres.storage=5Gi"; req='cpu: 500m memory: 512Mi'; lim='cpu: "4" memory: 3Gi'; storage=5Gi;; \
	  esac; \
	  dir=build/postgres-$$case; mkdir -p "$$dir/patches/30-postgres-sizing" "$$dir/pg-build"; \
	  cp -r charts/substrate-install/patches/. "$$dir/patches/"; \
	  helm template r charts/substrate-install -f charts/substrate-install/ci/aws-values.yaml $$sets -s templates/configmap.yaml > "$$dir/configmap.yaml"; \
	  awk '/^  patch-30-postgres-sizing: /{f=1;next} f&&/^    /{sub(/^    /,"");print;next} f{exit}' "$$dir/configmap.yaml" > "$$dir/patches/30-postgres-sizing/kustomization.yaml"; \
	  awk '/^  pg-build: /{f=1;next} f&&/^    /{sub(/^    /,"");print;next} f{exit}' "$$dir/configmap.yaml" > "$$dir/pg-build/kustomization.yaml"; \
	  cmd=$$(helm template r charts/substrate-install -f charts/substrate-install/ci/aws-values.yaml $$sets -s templates/job.yaml | awk '/name: patch-postgres/{f=1} f&&/command:/{c=1;next} c&&/^ +- /{sub(/^ +- /,"");print;next} c{exit}'); \
	  test -n "$$cmd" || { echo "no patch-postgres command in the Job"; exit 1; }; \
	  docker run --rm --user 0 --entrypoint sh -e CASE=$$case -e REQ="$$req" -e LIM="$$lim" -e STORAGE="$$storage" -v "$(CURDIR)/$$dir:/in:ro" "$(IMAGE)" -euc '\
	    mkdir /work && cp -a /opt/substrate/. /work/ && \
	    mkdir /work/manifests/ate-install/patches /work/manifests/ate-install/pg-build && \
	    cp -r /in/patches/. /work/manifests/ate-install/patches/ && \
	    cp /in/pg-build/kustomization.yaml /work/manifests/ate-install/pg-build/ && \
	    if [ "$$CASE" = renamed ]; then \
	      sed -i "s/^  name: postgres\$$/  name: postgres-renamed/" /work/manifests/ate-install/postgres/postgres.yaml && \
	      if "$$@"; then echo "the Job command passed although no StatefulSet is named postgres"; exit 1; fi && \
	      echo "renamed StatefulSet: the Job command fails, as it must" && exit 0; \
	    fi && \
	    "$$@" && \
	    flat=$$(tr -s " \n" " " < /work/manifests/ate-install/postgres/postgres.yaml) && \
	    case "$$flat" in *"requests: $$REQ limits: $$LIM"*|*"limits: $$LIM requests: $$REQ"*) ;; *) echo "postgres sizing $$REQ / $$LIM not found"; exit 1;; esac && \
	    case "$$flat" in *"storage: $$STORAGE "*) ;; *) echo "storage $$STORAGE not found"; exit 1;; esac && \
	    echo "postgres sizing $$REQ / $$LIM, storage $$STORAGE: written over the postgres manifest by the command of the Job"' sh $$cmd || exit 1; \
	done

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
