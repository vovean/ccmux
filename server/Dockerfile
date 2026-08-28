# Optional. The binary is static and needs nothing at runtime, so the image is the binary
# plus a CA bundle — under 10 MB. systemd is the documented path (see docs/server.md);
# this exists for hosts where a container is the house style.
#
#   docker build -t ccmuxd server
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /ccmuxd .

FROM scratch
# api.anthropic.com is verified against these; without them every refresh fails TLS.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /ccmuxd /ccmuxd
# Never root: the sealed store and the master key beside it are the whole prize.
USER 10001:10001
ENV CCMUXD_DATA_DIR=/var/lib/ccmuxd
VOLUME ["/var/lib/ccmuxd"]
EXPOSE 8443
ENTRYPOINT ["/ccmuxd"]
