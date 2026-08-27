# The full runtime is compacted by .github/workflows/runtime-image.yml and
# exported as a public, immutable release asset. This importer installs the
# small system base itself, then retains only the portable application trees
# from that release so no multi-GiB rootfs is duplicated during the build.
FROM docker.io/library/node:20.20.2-bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG ROOTFS_URL=https://github.com/cloud-in-a-bottle/bottled-classroomio-runtime/releases/download/runtime-f37d1cc/classroomio-rootfs.tar.gz
ARG ROOTFS_SHA256=172981b5d5b685abe4af75deb9bfb8142d7efa1b7d4040f3f5fd4f514ac777a7

ENV PNPM_HOME=/pnpm
ENV PATH=$PNPM_HOME:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY scripts/extract-rootfs.py /tmp/extract-rootfs.py

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        ffmpeg \
        gosu \
        nginx \
        openssl \
        postgresql-common \
        python3 \
        redis-server \
        tini \
    && install -d -m 0755 /usr/share/postgresql-common/pgdg \
    && curl -fsSL --retry 5 --retry-all-errors --connect-timeout 10 --max-time 120 \
        https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends postgresql-16 postgresql-client-16 \
    && corepack enable \
    && corepack prepare pnpm@10.19.0 --activate \
    && curl -fsSL --retry 5 --retry-all-errors --connect-timeout 15 \
        --max-time 1800 "$ROOTFS_URL" -o /tmp/classroomio-rootfs.tar.gz \
    && printf '%s  %s\n' "$ROOTFS_SHA256" /tmp/classroomio-rootfs.tar.gz \
        | sha256sum -c - \
    && mkdir -p /tmp/classroomio-rootfs \
    && python3 /tmp/extract-rootfs.py /tmp/classroomio-rootfs.tar.gz /tmp/classroomio-rootfs \
    && mv /tmp/classroomio-rootfs/opt/classroomio /opt/classroomio \
    && mv /tmp/classroomio-rootfs/opt/bottled-classroomio /opt/bottled-classroomio \
    && cp /tmp/classroomio-rootfs/etc/nginx/nginx.conf /etc/nginx/nginx.conf \
    && cp /tmp/classroomio-rootfs/etc/nginx/dashboard-proxy.conf /etc/nginx/dashboard-proxy.conf \
    && cp /tmp/classroomio-rootfs/usr/local/bin/minio /usr/local/bin/minio \
    && cp /tmp/classroomio-rootfs/usr/local/bin/mc /usr/local/bin/mc \
    && rm -rf /tmp/classroomio-rootfs /tmp/classroomio-rootfs.tar.gz \
        /tmp/extract-rootfs.py /var/lib/apt/lists/* /etc/nginx/sites-enabled/default \
        /var/lib/postgresql/16/main \
    && useradd --system --uid 1500 --user-group --create-home \
        --home-dir /home/classroomio --shell /usr/sbin/nologin classroomio \
    && install -d -o postgres -g postgres -m 0755 /run/postgresql \
    && install -d -o www-data -g www-data -m 0755 \
        /run/nginx /tmp/nginx/client_temp /tmp/nginx/proxy_temp \
    && chmod 0755 /opt/bottled-classroomio/start.sh \
        /usr/local/bin/minio /usr/local/bin/mc

# Keep lightweight package-owned files updateable without regenerating the
# large runtime release asset.
COPY nginx.conf /etc/nginx/nginx.conf
COPY dashboard-proxy.conf /etc/nginx/dashboard-proxy.conf
COPY sidecar.js /opt/bottled-classroomio/sidecar.js
COPY start.sh /opt/bottled-classroomio/start.sh
RUN chmod 0755 /opt/bottled-classroomio/start.sh \
    && node -e 'const fs = require("node:fs"); const path = "/opt/classroomio/db/package.json"; const pkg = JSON.parse(fs.readFileSync(path, "utf8")); pkg.packageManager = "pnpm@10.19.0"; fs.writeFileSync(path, JSON.stringify(pkg, null, 2) + "\n")'

EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/bottled-classroomio/start.sh"]
CMD []
