# The full runtime is compacted by .github/workflows/runtime-image.yml and
# exported as a public, immutable release asset. Importing that flattened rootfs
# keeps Cloud in a Bottle hosts from unpacking ClassroomIO's multi-GiB upstream
# development images during installation.
FROM docker.io/library/debian:bookworm-slim

ARG ROOTFS_URL=https://github.com/cloud-in-a-bottle/bottled-classroomio-runtime/releases/download/runtime-f37d1cc/classroomio-rootfs.tar.gz
ARG ROOTFS_SHA256=172981b5d5b685abe4af75deb9bfb8142d7efa1b7d4040f3f5fd4f514ac777a7

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && curl -fsSL --retry 5 --retry-all-errors --connect-timeout 15 \
        --max-time 1800 "$ROOTFS_URL" -o /tmp/classroomio-rootfs.tar.gz \
    && printf '%s  %s\n' "$ROOTFS_SHA256" /tmp/classroomio-rootfs.tar.gz \
        | sha256sum -c - \
    && tar -xzf /tmp/classroomio-rootfs.tar.gz -C / \
        --exclude=dev \
        --exclude=etc/hostname \
        --exclude=etc/hosts \
        --exclude=etc/resolv.conf \
        --exclude=proc \
        --exclude=sys \
    && rm -f /tmp/classroomio-rootfs.tar.gz

ENV PNPM_HOME=/pnpm
ENV PATH=$PNPM_HOME:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/bottled-classroomio/start.sh"]
CMD []
