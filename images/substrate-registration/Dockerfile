# The registration image: the tools that the substrate-registration chart runs.
# kubectl-ate, jq, curl and bash. Nothing is downloaded when a container starts.
#
# To change the Substrate version, set SUBSTRATE_TAG and SUBSTRATE_COMMIT together.
# The build fails if the tag no longer names the commit. Renovate updates both in one pull request (renovate.json).
# To change jq or curl, set the version and both checksums together. The build
# fails on a mismatch. Renovate cannot update the checksums, so these pins have no
# renovate comment. Take the checksums from the sha256sum.txt of the jq release.
#
# The build stage runs on the build platform and cross-compiles, so a build for
# arm64 needs no emulation.

ARG GO_IMAGE=golang:1.27.3-bookworm@sha256:dc0963f32053e4bc451d24d87e3892d42d01021b61f093e98eb95c0352bb84b0
ARG RUNTIME_IMAGE=debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS build
ARG TARGETOS=linux
ARG TARGETARCH
ARG SUBSTRATE_TAG=v1.0.1
ARG SUBSTRATE_COMMIT=20778a6dbb01f13024642851bb592bf67c9fec05
ARG JQ_VERSION=jq-1.8.2
ARG JQ_SHA256_AMD64=b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f
ARG JQ_SHA256_ARM64=8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309
# curl is for the chart substrate-idle-suspend of kube-ai-agents, which pulls this image. It is a static build (musl), so no RUN step is
# needed in the target architecture. To change it, set the version and both checksums together.
ARG CURL_VERSION=8.23.0-1
ARG CURL_SHA256_AMD64=2e0c54ba696afd0df1e899e4344fa63d53d73107f9ac08173314d9be85bc76fd
ARG CURL_SHA256_ARM64=e20f26e5b87c1883608f286f86bdabf39d3b8556e8a8e75dfe205e14bd206199
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

# xz-utils runs on the build platform, so it needs no emulation. Only the archive is for the target.
RUN apt-get update && apt-get install -y --no-install-recommends xz-utils && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) curl_arch=x86_64; curl_sha="${CURL_SHA256_AMD64}" ;; \
      arm64) curl_arch=aarch64; curl_sha="${CURL_SHA256_ARM64}" ;; \
      *) echo "unsupported architecture ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    file="curl-linux-${curl_arch}-musl-${CURL_VERSION}.tar.xz"; \
    curl -fsSL -o "/tmp/${file}" "https://github.com/stunnel/static-curl/releases/download/${CURL_VERSION}/${file}"; \
    echo "${curl_sha}  /tmp/${file}" | sha256sum -c -; \
    tar -xJf "/tmp/${file}" -C /out curl; \
    chmod +x /out/curl

FROM ${RUNTIME_IMAGE}
# renovate: datasource=github-tags depName=agent-substrate/substrate
ARG SUBSTRATE_TAG=v1.0.1
LABEL org.opencontainers.image.source="https://github.com/bbaliyan/kube-agent-substrate" \
      org.opencontainers.image.description="Registers actors in Agent Substrate ${SUBSTRATE_TAG}" \
      org.opencontainers.image.licenses="Apache-2.0"
COPY --from=build /out/kubectl-ate /out/jq /out/curl /usr/local/bin/
# curl needs the CA certificates to verify the TLS of Prometheus. The slim base has none.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
USER 65532:65532
ENV HOME=/tmp
