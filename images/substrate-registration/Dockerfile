# The registration image: the tools that the substrate-registration chart runs.
# kubectl-ate, kubectl, jq and bash. Nothing is downloaded when a container starts.
#
# To change the Substrate version, set SUBSTRATE_TAG and SUBSTRATE_COMMIT together.
# The build fails if the tag no longer names the commit.
# To change kubectl or jq, set the version and both checksums together. The build
# fails on a mismatch. Renovate cannot update the checksums, so these pins have no
# renovate comment. Take the kubectl checksum from dl.k8s.io/release/<version>/bin/linux/<arch>/kubectl.sha256
# and the jq checksum from the sha256sum.txt of the jq release.
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
# renovate: datasource=github-releases depName=agent-substrate/substrate
ARG SUBSTRATE_TAG=v1.0.0
ARG SUBSTRATE_COMMIT=b34fbee742906494b5eb4f1f36987176bf8770a4
ARG KUBECTL_VERSION=v1.37.2
ARG KUBECTL_SHA256_AMD64=c04487523e7aa7d1493f7808174c899db93d7a9cf57531420cd76b9bd415f8f4
ARG KUBECTL_SHA256_ARM64=fcc16f63186659d9722014b7e02d5fdd2d4e669cb8c0ab66365d7d3b8ba03509
ARG JQ_VERSION=jq-1.8.2
ARG JQ_SHA256_AMD64=b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f
ARG JQ_SHA256_ARM64=8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309
ENV CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH}

RUN git clone --quiet --depth 1 --branch "${SUBSTRATE_TAG}" https://github.com/agent-substrate/substrate /src \
 && test "$(git -C /src rev-parse HEAD)" = "${SUBSTRATE_COMMIT}"

# The release ships no kubectl-ate binary. The checkout vendors its modules.
WORKDIR /src
RUN go build -trimpath -ldflags='-s -w' -o /out/kubectl-ate ./cmd/kubectl-ate

# Download for the target architecture and verify the checksum before the file is used.
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) kubectl_sha="${KUBECTL_SHA256_AMD64}"; jq_sha="${JQ_SHA256_AMD64}" ;; \
      arm64) kubectl_sha="${KUBECTL_SHA256_ARM64}"; jq_sha="${JQ_SHA256_ARM64}" ;; \
      *) echo "unsupported architecture ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /out/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"; \
    echo "${kubectl_sha}  /out/kubectl" | sha256sum -c -; \
    curl -fsSL -o /out/jq "https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/jq-linux-${TARGETARCH}"; \
    echo "${jq_sha}  /out/jq" | sha256sum -c -; \
    chmod +x /out/kubectl /out/jq

FROM ${RUNTIME_IMAGE}
# renovate: datasource=github-releases depName=agent-substrate/substrate
ARG SUBSTRATE_TAG=v1.0.0
LABEL org.opencontainers.image.source="https://github.com/bbaliyan/kube-agent-substrate" \
      org.opencontainers.image.description="Registers actors in Agent Substrate ${SUBSTRATE_TAG}" \
      org.opencontainers.image.licenses="Apache-2.0"
COPY --from=build /out/kubectl-ate /out/kubectl /out/jq /usr/local/bin/
USER 65532:65532
ENV HOME=/tmp
