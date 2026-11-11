FROM --platform=$BUILDPLATFORM golang:1.26-alpine@sha256:30b1e546a9c7fa3b747c2bdba3a0c7bdf3a02ebb4c5b8405d2f948d7e8aac4ec AS builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY . .
ARG TARGETOS TARGETARCH APP_VERSION=0.1.0
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH:-amd64} \
    go build -trimpath -ldflags="-s -w -X main.version=${APP_VERSION}" -o /app .

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab

ARG APP_VERSION=0.1.0
LABEL org.opencontainers.image.title="devops-stack" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.licenses="MIT"

COPY --from=builder /app /app
USER 65532:65532
EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD ["/app", "-healthcheck"]

ENTRYPOINT ["/app"]
