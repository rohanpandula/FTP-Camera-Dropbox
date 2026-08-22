# pure-ftpd fork: Debian's own package source, rebuilt with patches/ applied.
#
# Stock pure-ftpd -0 (atomic uploads) writes to a hidden .pureftpd-upload.*
# temp and then renames it onto the real name BEFORE checking whether the
# transfer completed (src/ftpd.c, dostor()). A camera whose Wi-Fi dies mid-file
# gets "451 Transfer aborted" — and the truncated partial still lands in
# incoming/ under its final name. patches/0001 skips that rename on failure so
# the temp is unlinked instead. patches/0002 is the capability tweak
# stilliard/docker-pure-ftpd already applies to its own build.
#
# The build stage starts from the same stilliard image as the runtime so the
# binary is compiled against the exact Debian release and libraries it runs
# with, using Debian's own debian/rules target (same configure flags and
# hardening). Only /usr/sbin/pure-ftpd is replaced; run.sh, pure-pw, rsyslog
# and the ADDED_FLAGS contract stay identical.
#
#   build:   docker build -t ftp-camera-dropbox/pure-ftpd pure-ftpd/
#   verify:  tests/pure-ftpd-abort.py ftp://cameras:cameras@HOST/
#   version: docker run --rm ftp-camera-dropbox/pure-ftpd cat /etc/pure-ftpd/FORK
ARG BASE=stilliard/pure-ftpd:latest

FROM ${BASE} AS build
WORKDIR /build
# Fetch Debian's source for the exact revision the base image installed (or
# the archive's current one if that revision has rolled off the mirror).
RUN set -eux; \
    sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources; \
    apt-get update; \
    apt-get build-dep -y --no-install-recommends pure-ftpd; \
    ver="$(dpkg-query -W -f='${Version}' pure-ftpd)"; \
    apt-get source "pure-ftpd=$ver" || apt-get source pure-ftpd; \
    echo "$ver" > /build/BASE_VERSION
COPY patches/ /build/patches/
RUN set -eux; \
    cd pure-ftpd-*/; \
    for p in /build/patches/*.patch; do patch -p1 -F0 --no-backup-if-mismatch < "$p"; done; \
    eval "$(dpkg-buildflags --export=sh)"; \
    debian/rules src/vanilla/pure-ftpd; \
    strip --strip-unneeded src/vanilla/pure-ftpd; \
    cp src/vanilla/pure-ftpd /build/pure-ftpd; \
    { echo "source: pure-ftpd $(dpkg-parsechangelog -S Version)"; \
      echo "base:   $(cat /build/BASE_VERSION)"; \
      ls /build/patches/*.patch | xargs -n1 basename | sed 's/^/patch:  /'; } > /build/FORK

FROM ${BASE}
COPY --from=build /build/pure-ftpd /usr/sbin/pure-ftpd
COPY --from=build /build/FORK /etc/pure-ftpd/FORK
RUN pure-ftpd --help 2>&1 | grep -q '^pure-ftpd v' && cat /etc/pure-ftpd/FORK
LABEL org.opencontainers.image.title="pure-ftpd (FTP-Camera-Dropbox fork)" \
      org.opencontainers.image.source="https://github.com/rohanpandula/FTP-Camera-Dropbox" \
      org.opencontainers.image.description="Debian pure-ftpd with aborted uploads unlinked instead of published"
