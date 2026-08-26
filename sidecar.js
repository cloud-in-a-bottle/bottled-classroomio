const fs = require('node:fs');
const http = require('node:http');

const bootstrapMarker = process.env.BOOTSTRAP_MARKER;
const jobsPid = Number.parseInt(process.env.JOBS_PID || '', 10);
const listenPort = Number.parseInt(process.env.SIDECAR_PORT || '8090', 10);

if (!bootstrapMarker || !Number.isInteger(jobsPid)) {
  throw new Error('BOOTSTRAP_MARKER and JOBS_PID are required');
}

function isOwner(request) {
  const value = request.headers['x-openhost-is-owner'];
  return value === 'true' || value === '1';
}

function jobsAreRunning() {
  try {
    process.kill(jobsPid, 0);
    return true;
  } catch {
    return false;
  }
}

async function serviceIsHealthy(url) {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(3000) });
    return response.ok;
  } catch {
    return false;
  }
}

async function handleHealth(response) {
  const [api, dashboard, minio] = await Promise.all([
    serviceIsHealthy('http://127.0.0.1:3081/'),
    serviceIsHealthy('http://127.0.0.1:3082/login'),
    serviceIsHealthy('http://127.0.0.1:9000/minio/health/ready')
  ]);
  const jobs = jobsAreRunning();
  const healthy = api && dashboard && minio && jobs;
  const body = JSON.stringify({ healthy, api, dashboard, minio, jobs });

  response.writeHead(healthy ? 200 : 503, { 'Content-Type': 'application/json' });
  response.end(`${body}\n`);
}

const server = http.createServer(async (request, response) => {
  if (request.url === '/bootstrap') {
    if (fs.existsSync(bootstrapMarker) || isOwner(request)) {
      response.writeHead(204);
      response.end();
      return;
    }

    response.writeHead(403, { 'Content-Type': 'text/plain' });
    response.end('The Cloud in a Bottle owner must create the first account.\n');
    return;
  }

  if (request.url === '/health') {
    await handleHealth(response);
    return;
  }

  response.writeHead(404);
  response.end();
});

server.listen(listenPort, '127.0.0.1');
