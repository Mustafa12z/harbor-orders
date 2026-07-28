# syntax=docker/dockerfile:1
# Build with: docker build --platform=linux/amd64 ...
# TARGETOS/TARGETARCH are set by BuildKit from --platform (GKE Autopilot = linux/amd64).
FROM --platform=$BUILDPLATFORM golang:1.22-alpine AS build
ARG TARGETOS=linux
ARG TARGETARCH=amd64
WORKDIR /src
RUN apk add --no-cache ca-certificates git
COPY go.mod ./
COPY go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -ldflags="-s -w" -o /out/app .

FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /
COPY --from=build /out/app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
