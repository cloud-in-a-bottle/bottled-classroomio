const crypto = require('node:crypto');
const http = require('node:http');

const appHost = process.env.APP_HOST;
const authSecret = process.env.BETTER_AUTH_SECRET;
const jobsPid = Number.parseInt(process.env.JOBS_PID || '', 10);
const listenPort = Number.parseInt(process.env.SIDECAR_PORT || '8090', 10);
const ownerEmail = process.env.OWNER_EMAIL;
const ownerUserId = process.env.OWNER_USER_ID;

if (!appHost || !authSecret || !ownerEmail || !ownerUserId || !Number.isInteger(jobsPid)) {
  throw new Error('APP_HOST, BETTER_AUTH_SECRET, OWNER_EMAIL, OWNER_USER_ID, and JOBS_PID are required');
}

if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(ownerUserId)) {
  throw new Error('OWNER_USER_ID must be a UUID');
}

function isOwner(request) {
  const value = request.headers['x-openhost-is-owner'];
  return value === 'true' || value === '1';
}

function getSessionCookie(request) {
  const cookies = request.headers.cookie || '';
  return /(?:^|;\s*)(?:__Secure-)?classroomio\.session_token=/.test(cookies) ? cookies : null;
}

async function hasOwnerSession(request) {
  const cookies = getSessionCookie(request);
  if (!cookies) {
    return false;
  }

  try {
    const sessionResponse = await fetch('http://127.0.0.1:3081/api/auth/get-session', {
      headers: {
        Cookie: cookies,
        'X-Forwarded-Host': appHost,
        'X-Forwarded-Proto': 'https'
      },
      signal: AbortSignal.timeout(3000)
    });
    if (!sessionResponse.ok) {
      return false;
    }

    const session = await sessionResponse.json();
    return session?.user?.id === ownerUserId;
  } catch {
    return false;
  }
}

function encodeJson(value) {
  return Buffer.from(JSON.stringify(value)).toString('base64url');
}

function mintLoginLinkToken() {
  const now = Math.floor(Date.now() / 1000);
  const header = encodeJson({ alg: 'HS256', typ: 'JWT' });
  const payload = encodeJson({
    sub: ownerUserId,
    email: ownerEmail,
    type: 'login-link',
    iat: now,
    exp: now + 60
  });
  const signature = crypto.createHmac('sha256', authSecret).update(`${header}.${payload}`).digest('base64url');
  return `${header}.${payload}.${signature}`;
}

function safeRedirectPath(value) {
  return value && value.startsWith('/') && !value.startsWith('//') ? value : '/';
}

async function handleSso(request, response) {
  const method = request.headers['x-original-method'];
  const accept = request.headers.accept || '';
  const fetchMode = request.headers['sec-fetch-mode'];
  const isNavigation = method === 'GET' && accept.includes('text/html') && (!fetchMode || fetchMode === 'navigate');

  if (!isOwner(request) || !isNavigation || (await hasOwnerSession(request))) {
    response.writeHead(204);
    response.end();
    return;
  }

  const redirect = safeRedirectPath(request.headers['x-original-uri']);
  const query = new URLSearchParams({ token: mintLoginLinkToken(), redirect });
  response.writeHead(401, {
    'Cache-Control': 'no-store',
    'X-SSO-Redirect': `/api/auth/login-link?${query}`
  });
  response.end();
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
  if (request.url === '/sso') {
    await handleSso(request, response);
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
