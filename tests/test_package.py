import pathlib
import re
import subprocess
import tomllib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class PackageTests(unittest.TestCase):
    def test_manifest_exposes_native_multi_user_app(self):
        manifest = tomllib.loads((ROOT / "openhost.toml").read_text())

        self.assertEqual(manifest["app"]["name"], "classroomio")
        self.assertEqual(manifest["runtime"]["container"]["port"], 8080)
        self.assertEqual(manifest["routing"]["health_check"], "/_healthz")
        self.assertEqual(manifest["routing"]["public_paths"], ["/"])
        self.assertTrue(manifest["data"]["app_data"])
        self.assertTrue(manifest["data"]["app_temp_data"])

    def test_application_images_are_digest_pinned(self):
        dockerfile = (ROOT / "Dockerfile.components").read_text()

        for image in ("api", "dashboard", "jobs"):
            pattern = rf"classroomio/{image}@sha256:[0-9a-f]{{64}}"
            self.assertRegex(dockerfile, pattern)

        self.assertNotRegex(dockerfile, r"classroomio/(api|dashboard|jobs):latest")
        self.assertIn("--prod deploy --legacy /runtime/dashboard", dockerfile)
        self.assertIn("--prod deploy --legacy /runtime/jobs", dockerfile)

    def test_published_image_contains_all_component_runtimes(self):
        dockerfile = (ROOT / "Dockerfile.image").read_text()

        self.assertIn("bottled-classroomio-components:api-${COMPONENT_TAG}", dockerfile)
        self.assertIn("bottled-classroomio-components:dashboard-${COMPONENT_TAG}", dockerfile)
        self.assertIn("bottled-classroomio-components:jobs-${COMPONENT_TAG}", dockerfile)
        self.assertIn("COPY --from=api-runtime /opt/classroomio", dockerfile)

    def test_deployment_imports_checksum_pinned_rootfs(self):
        dockerfile = (ROOT / "Dockerfile").read_text()

        self.assertIn("bottled-classroomio-runtime/releases/download/runtime-f37d1cc", dockerfile)
        self.assertRegex(dockerfile, r"ARG ROOTFS_SHA256=[0-9a-f]{64}")
        self.assertIn("sha256sum -c -", dockerfile)
        self.assertIn("extract-rootfs.py", dockerfile)
        self.assertIn("mv /tmp/classroomio-rootfs/opt/classroomio /opt/classroomio", dockerfile)
        self.assertIn("rm -rf /tmp/classroomio-rootfs", dockerfile)
        self.assertNotIn("COPY --from=rootfs", dockerfile)
        self.assertNotIn("classroomio/api@", dockerfile)

    def test_signed_storage_routes_preserve_host_and_uri(self):
        nginx = (ROOT / "nginx.conf").read_text()

        self.assertIn("^/(videos|documents|media)(/|$)", nginx)
        self.assertIn("proxy_set_header Host $public_host;", nginx)
        self.assertIn("proxy_pass http://classroomio_minio;", nginx)
        self.assertNotIn("proxy_pass http://classroomio_minio/;", nginx)
        self.assertIn("proxy_request_buffering off;", nginx)
        storage_location = nginx.split("location ~ ^/(videos|documents|media)(/|$)", 1)[1].split("}", 1)[0]
        self.assertIn("access_log off;", storage_location)
        self.assertIn("proxy_buffer_size 64k;", (ROOT / "dashboard-proxy.conf").read_text())
        self.assertIn("proxy_buffers 8 64k;", (ROOT / "dashboard-proxy.conf").read_text())

    def test_owner_uses_openhost_sso(self):
        nginx = (ROOT / "nginx.conf").read_text()
        sidecar = (ROOT / "sidecar.js").read_text()

        self.assertIn("location = /_sso_auth", nginx)
        self.assertIn("location @openhost_sso", nginx)
        self.assertIn("location = /api/auth/login-link", nginx)
        self.assertIn("absolute_redirect off;", nginx)
        self.assertIn("location ^~ /api/auth/", nginx)
        self.assertIn("auth_request /_sso_auth;", (ROOT / "sso-dashboard-proxy.conf").read_text())
        self.assertIn("x-openhost-is-owner", sidecar)
        self.assertIn("type: 'login-link'", sidecar)
        self.assertIn("exp: now + 15", sidecar)
        self.assertIn("createOwnerSessionCookie", sidecar)
        self.assertIn("/_openhost_sso_complete", sidecar)
        self.assertIn("session?.user?.id === ownerUserId", sidecar)
        self.assertIn("add_header Set-Cookie $sso_cookie always;", nginx)

    def test_owner_account_is_bootstrapped_without_password(self):
        bootstrap = (ROOT / "bootstrap-openhost-owner.ts").read_text()

        self.assertIn("emailVerified: true", bootstrap)
        self.assertIn("roleId: ROLE.ADMIN", bootstrap)
        self.assertIn("db.transaction", bootstrap)
        self.assertIn("db.delete(session)", bootstrap)
        self.assertNotIn("password", bootstrap.lower())

    def test_start_script_is_valid_bash(self):
        result = subprocess.run(
            ["bash", "-n", str(ROOT / "start.sh")],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("corepack pnpm@10.19.0 db:setup", (ROOT / "start.sh").read_text())
        self.assertIn("PORT=3081 node dist/index.js", (ROOT / "start.sh").read_text())
        self.assertIn('pkg.packageManager = "pnpm@10.19.0"', (ROOT / "Dockerfile").read_text())
        self.assertIn("/opt/classroomio/workspace-links", (ROOT / "Dockerfile").read_text())
        self.assertIn('ln -s /opt/classroomio/workspace-links "$package/node_modules/@cio"', (ROOT / "Dockerfile").read_text())
        self.assertIn("node_modules/.bin/tsc -p tsconfig.json", (ROOT / "Dockerfile").read_text())
        self.assertIn("api/node_modules/zod /opt/classroomio/jobs/node_modules/zod", (ROOT / "Dockerfile").read_text())

    def test_required_services_are_supervised(self):
        script = (ROOT / "start.sh").read_text()

        wait_command = re.search(r"wait -n (?P<services>[^\n]+)", script)
        self.assertIsNotNone(wait_command)
        services = wait_command.group("services")
        for variable in (
            "PG_PID",
            "REDIS_PID",
            "MINIO_PID",
            "API_PID",
            "JOBS_PID",
            "DASHBOARD_PID",
            "SIDECAR_PID",
            "NGINX_PID",
        ):
            self.assertIn(variable, services)


if __name__ == "__main__":
    unittest.main()
