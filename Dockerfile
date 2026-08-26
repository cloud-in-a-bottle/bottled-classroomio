# ClassroomIO publishes three independently built application images. Keep each
# complete /app tree because pnpm's workspace links point into its root virtual
# store. The digests below are a coherent upstream snapshot published on
# 2026-08-24.
FROM docker.io/classroomio/api@sha256:89f33303bf4988395895db6b3682505de44987e0b849a15a46dbbd71264f18ec AS classroomio-api
FROM docker.io/classroomio/dashboard@sha256:5d71e9f39aaed493151f2a2a3a796e8a9f3d38e11a3c7b9e033b79ceb9e7b98f AS classroomio-dashboard

# MinIO and its client are pinned to immutable multi-architecture manifests.
FROM docker.io/minio/minio@sha256:a1ea29fa28355559ef137d71fc570e508a214ec84ff8083e39bc5428980b015e AS minio
FROM docker.io/minio/mc@sha256:aead63c77f9db9107f1696fb08ecb0faeda23729cde94b0f663edf4fe09728e3 AS minio-client

# The jobs image is the final base because it already contains Node 20, the
# complete worker dependency tree, ffmpeg, and ffprobe.
FROM docker.io/classroomio/jobs@sha256:c36ef703f102fa538aaffc78366ab0d9b72bcf3474f7fd2f890294e65bffbc2c

ARG DEBIAN_FRONTEND=noninteractive
USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        gosu \
        nginx \
        openssl \
        postgresql-common \
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
    && rm -rf /var/lib/apt/lists/* /etc/nginx/sites-enabled/default

COPY --from=minio /usr/bin/minio /usr/local/bin/minio
COPY --from=minio-client /usr/bin/mc /usr/local/bin/mc
COPY --from=classroomio-api /app /opt/classroomio/api
COPY --from=classroomio-dashboard /app /opt/classroomio/dashboard

RUN useradd --system --uid 1500 --user-group --create-home \
        --home-dir /home/classroomio --shell /usr/sbin/nologin classroomio \
    && install -d -o postgres -g postgres -m 0755 /run/postgresql \
    && install -d -o www-data -g www-data -m 0755 \
        /run/nginx /tmp/nginx/client_temp /tmp/nginx/proxy_temp

COPY nginx.conf /etc/nginx/nginx.conf
COPY dashboard-proxy.conf /etc/nginx/dashboard-proxy.conf
COPY sidecar.js /opt/bottled-classroomio/sidecar.js
COPY start.sh /opt/bottled-classroomio/start.sh
RUN chmod 0755 /opt/bottled-classroomio/start.sh \
    && chmod 0755 /usr/local/bin/minio /usr/local/bin/mc

EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/bottled-classroomio/start.sh"]
CMD []
