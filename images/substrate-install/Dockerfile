# The install image: the tools and the pinned Substrate checkout that the
# substrate-install chart runs. Nothing is downloaded when a container starts.
#
# To change the Substrate version, set SUBSTRATE_TAG and the
# SUBSTRATE_COMMIT together. The build fails if the tag no longer names the
# commit. Renovate updates both in one pull request (renovate.json).
#
# The build stage runs on the build platform and cross-compiles, so a build for
# arm64 needs no emulation.

# renovate: datasource=docker depName=golang
ARG GO_IMAGE=golang:1.27.3-bookworm@sha256:dc0963f32053e4bc451d24d87e3892d42d01021b61f093e98eb95c0352bb84b0
# renovate: datasource=docker depName=debian
ARG RUNTIME_IMAGE=debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS build
ARG TARGETOS=linux
ARG TARGETARCH
ARG SUBSTRATE_TAG=v1.0.0
ARG SUBSTRATE_COMMIT=b34fbee742906494b5eb4f1f36987176bf8770a4
# renovate: datasource=go depName=sigs.k8s.io/kustomize/kustomize/v5
ARG KUSTOMIZE_VERSION=v5.8.3
ENV CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH}

RUN git clone --quiet --depth 1 --branch "${SUBSTRATE_TAG}" https://github.com/agent-substrate/substrate /src \
 && test "$(git -C /src rev-parse HEAD)" = "${SUBSTRATE_COMMIT}"

# The release ships no ate-setup binary. The checkout vendors its modules.
WORKDIR /src
RUN go build -trimpath -ldflags='-s -w' -o /out/ate-setup ./cmd/ate-setup

# kustomize edits the checkout's kustomization to add the patch components.
WORKDIR /kustomize
RUN go mod init kustomize-build \
 && go get "sigs.k8s.io/kustomize/kustomize/v5@${KUSTOMIZE_VERSION}" \
 && go build -trimpath -ldflags='-s -w' -o /out/kustomize sigs.k8s.io/kustomize/kustomize/v5

# Only the manifests and the module file are needed to deploy.
RUN mkdir -p /out/substrate && cp -a /src/manifests /src/go.mod /out/substrate/

FROM ${RUNTIME_IMAGE}
# renovate: datasource=github-releases depName=agent-substrate/substrate
ARG SUBSTRATE_TAG=v1.0.0
LABEL org.opencontainers.image.source="https://github.com/bbaliyan/kube-agent-substrate" \
      org.opencontainers.image.description="Installs Agent Substrate ${SUBSTRATE_TAG}" \
      org.opencontainers.image.licenses="Apache-2.0"
# The registry check of ate-setup needs the system roots, which this base lacks.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/ate-setup /out/kustomize /usr/local/bin/
COPY --from=build /out/substrate /opt/substrate
USER 65532:65532
ENV HOME=/tmp
WORKDIR /opt/substrate
