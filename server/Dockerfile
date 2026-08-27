# Build context is the REPOSITORY ROOT, not server/ — ccmuxd depends on CCMuxCore by
# path, and that is where the credential logic actually lives:
#   docker build -f server/Dockerfile -t ccmuxd .
FROM swift:6.0-noble AS build

WORKDIR /src
# The root manifest declares macOS-only targets (CCMuxKit, ccmux, the test suite). They
# are never compiled here — `--product ccmuxd` does not reach them — but SwiftPM validates
# every target's path when it loads the manifest, so the directories have to exist.
COPY Package.swift ./
COPY Sources ./Sources
COPY Tests ./Tests
COPY server ./server

WORKDIR /src/server
RUN swift build -c release --product ccmuxd \
    && install -m 0755 "$(swift build -c release --product ccmuxd --show-bin-path)/ccmuxd" \
       /usr/local/bin/ccmuxd

# Slim rather than a bare distro: it carries the Swift runtime and Foundation's
# dependencies, which is a smaller risk than chasing which .so a static build still wants.
FROM swift:6.0-noble-slim

# api.anthropic.com is verified against these; without them every refresh fails TLS.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Never root: the sealed secret store and the master key beside it are the whole prize.
RUN useradd --system --create-home --uid 10001 ccmuxd
COPY --from=build /usr/local/bin/ccmuxd /usr/local/bin/ccmuxd

USER ccmuxd
ENV CCMUXD_DATA_DIR=/var/lib/ccmuxd
VOLUME ["/var/lib/ccmuxd"]
EXPOSE 8443

ENTRYPOINT ["/usr/local/bin/ccmuxd"]
