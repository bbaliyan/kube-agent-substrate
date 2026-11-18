# The registration image: the tools that the substrate-registration and substrate-idle-suspend charts run.
# kubectl-ate, jq, curl and bash. Nothing is downloaded when a container starts.
#
# To change the Substrate version, set SUBSTRATE_TAG and SUBSTRATE_COMMIT together.
# The build fails if the tag no longer names the commit.
# To change jq, set the version and both checksums together. The build
# fails on a mismatch. Renovate cannot update the checksums, so these pins have no
# renovate comment. Take the checksums from the sha256sum.txt of the jq release.
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
      amd64) jq_sha="${JQ_SHA256_AMD64}" ;; \
      arm64) jq_sha="${JQ_SHA256_ARM64}" ;; \
      *) echo "unsupported architecture ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /out/jq "https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/jq-linux-${TARGETARCH}"; \
    echo "${jq_sha}  /out/jq" | sha256sum -c -; \
    chmod +x /out/jq

FROM ${RUNTIME_IMAGE}
# renovate: datasource=github-releases depName=agent-substrate/substrate
ARG SUBSTRATE_TAG=v1.0.0
LABEL org.opencontainers.image.source="https://github.com/bbaliyan/kube-agent-substrate" \
      org.opencontainers.image.description="Registers actors in Agent Substrate ${SUBSTRATE_TAG}" \
      org.opencontainers.image.licenses="Apache-2.0"
# curl lets the substrate-idle-suspend chart query Prometheus. It comes from the Debian
# repository of the pinned base image, so the build is not byte for byte repeatable. The
# charts pin the image by digest.
RUN apt-get update  && apt-get install -y --no-install-recommends curl ca-certificates  && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/kubectl-ate /out/jq /usr/local/bin/
USER 65532:65532
ENV HOME=/tmp
