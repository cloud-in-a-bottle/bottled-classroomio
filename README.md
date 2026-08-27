# bottled-classroomio

[ClassroomIO](https://github.com/classroomio/classroomio), an open-source learning management system, packaged as a single Cloud in a Bottle app.

## Included services

One container runs the complete self-hosted stack:

- ClassroomIO API
- ClassroomIO dashboard
- ClassroomIO jobs worker
- PostgreSQL 16
- Redis
- MinIO object storage
- nginx

The browser reaches nginx on port 8080. Dashboard and authentication traffic stays same-origin; the dashboard proxies API calls internally. MinIO uses the root `/videos`, `/documents`, and `/media` bucket paths so its signed URLs remain valid through the Cloud in a Bottle router.

## Deploy

```sh
oh app deploy https://github.com/cloud-in-a-bottle/bottled-classroomio --name classroomio --wait
```

The app is available at `https://classroomio.<your-zone>/`.

## First boot

Sign in to your Cloud in a Bottle zone as its owner, then open `/signup` and create the first account. Until the first organization exists, the package blocks ClassroomIO authentication requests that do not carry the router's authenticated-owner header. This prevents an internet visitor from claiming a fresh deployment.

ClassroomIO recognizes the empty self-hosted instance, verifies the first account automatically, and guides it through creating the single organization. The package then opens normal authentication automatically, and later users join as learners according to the organization's signup settings.

ClassroomIO owns authentication for this package. The manifest intentionally makes all paths public at the Cloud in a Bottle router layer so learners, invite links, API clients, and signed uploads can reach the app; ClassroomIO still enforces its own authorization.

## Persistence

State is stored under `$OPENHOST_APP_DATA_DIR`:

```text
postgres/    PostgreSQL cluster
redis/       BullMQ queues and Redis persistence
minio/       uploaded videos, documents, and media
secrets/     generated database, auth, API, and MinIO credentials
```

Transcoding scratch data uses `$OPENHOST_APP_TEMP_DIR` and does not need to survive a redeploy. Back up PostgreSQL with `pg_dump` and object data with an S3-compatible tool rather than copying a live database directory.

## Optional configuration

The package starts without external services. Email delivery and AI features remain disabled until their normal ClassroomIO environment variables are injected into the app:

| Feature | Variables |
| --- | --- |
| SMTP | `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_SENDER` |
| Google OAuth | `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` |
| AI | `OPENAI_API_KEY`, `GOOGLE_API_KEY`, `ANTHROPIC_API_KEY` |
| Unsplash | `UNSPLASH_API_KEY` |
| Enterprise license | `LICENSE_KEY` |

`MEDIA_WORKER_CONCURRENCY` defaults to `1` to limit ffmpeg memory spikes. Increase the app's CPU and memory limits before raising it.

## Upstream version

`Dockerfile.components` pins the API, dashboard, and jobs images by immutable manifest digest. GitHub Actions compacts those images into one runtime, exports it to the public `bottled-classroomio-runtime` release repository, and the deployment Dockerfile verifies that release asset by SHA-256 before importing it. Update all three upstream digests together; never mix versions across the services.

## Validate

```sh
python3 -m unittest discover -s tests -v
```
