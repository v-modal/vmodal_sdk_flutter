/**
 * Developer-owned POST /vmodal/session reference.
 * Inject the host's real identity verifier, policy resolver and server-key loader.
 * No identity provider, user directory or signing secret belongs in the SDK.
 */
export class IdentityRejected extends Error {}
export class AccessDenied extends Error {}

const envelopeFields = new Set([
  'version', 'auth_mode', 'access_token', 'token_type', 'expires_in',
  'issued_at', 'expires_at', 'principal_id', 'tenant_id', 'project_id',
  'app_user_id', 'policy_revision', 'delegation_revision', 'grants',
]);
const grantFields = ['actions', 'collection_id', 'collection_wide', 'grant_id', 'mode', 'stream_name'];

function reply(res, status, code, extra = {}) {
  res.writeHead(status, {
    'content-type': 'application/json',
    'cache-control': 'no-store',
    pragma: 'no-cache',
    ...extra,
  });
  res.end(JSON.stringify({ detail: code, code }));
}

async function emptyBody(req) {
  let bytes = 0;
  const chunks = [];
  for await (const chunk of req) {
    bytes += chunk.length;
    if (bytes > 4096) throw new AccessDenied();
    chunks.push(chunk);
  }
  const text = Buffer.concat(chunks).toString('utf8');
  // This route deliberately accepts no mobile-selected user, project or grants.
  if (!/^\s*\{\s*\}\s*$/.test(text)) throw new AccessDenied();
}

async function issuerJson(response) {
  if (!response.body) throw new Error('invalid issuer response');
  const chunks = [];
  let bytes = 0;
  for await (const chunk of response.body) {
    bytes += chunk.length;
    if (bytes > 65536) throw new Error('issuer response too large');
    chunks.push(Buffer.from(chunk));
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

function checkEnvelope(data, identity, policy, projectId, serverKey) {
  if (!data || typeof data !== 'object' || Array.isArray(data) ||
      Object.keys(data).some(key => !envelopeFields.has(key)) ||
      Object.keys(data).length !== envelopeFields.size ||
      data.version !== 1 || data.auth_mode !== 'developer_backend' ||
      data.token_type !== 'Bearer' || data.project_id !== projectId ||
      data.app_user_id !== identity.subject ||
      data.policy_revision !== policy.revision ||
      typeof data.access_token !== 'string' ||
      data.access_token.length > 8192 ||
      !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(data.access_token) ||
      data.access_token === serverKey ||
      !Array.isArray(data.grants) || data.grants.length === 0 || data.grants.length > 16 ||
      !Number.isInteger(data.expires_in) || data.expires_in < 60 || data.expires_in > 900 ||
      !Number.isInteger(data.delegation_revision) || data.delegation_revision < 1 ||
      typeof data.issued_at !== 'string' || typeof data.expires_at !== 'string' ||
      !data.issued_at.endsWith('Z') || !data.expires_at.endsWith('Z') ||
      !Number.isFinite(Date.parse(data.issued_at)) ||
      Date.parse(data.expires_at) - Date.parse(data.issued_at) !== data.expires_in * 1000 ||
      Date.parse(data.expires_at) <= Date.now() ||
      ['principal_id', 'tenant_id'].some(key => typeof data[key] !== 'string' || !data[key]) ||
      data.grants.some(grant => !grant ||
        Object.keys(grant).sort().join(',') !== grantFields.join(',') ||
        typeof grant.grant_id !== 'string' || !grant.grant_id ||
        typeof grant.collection_wide !== 'boolean' ||
        ['collection_id', 'stream_name', 'mode'].some(key =>
          typeof grant[key] !== 'string' || !/^[A-Za-z0-9_]{1,80}$/.test(grant[key])) ||
        !Array.isArray(grant.actions) || !grant.actions.length ||
        new Set(grant.actions).size !== grant.actions.length ||
        grant.actions.some(action => !['discover', 'search', 'media'].includes(action)))) {
    throw new Error('invalid issuer contract');
  }
  const byId = grants => grants.map(grant => JSON.stringify([
    grant.grant_id, grant.collection_id, grant.stream_name, grant.mode,
    [...grant.actions].sort(), grant.collection_wide,
  ])).sort();
  if (JSON.stringify(byId(data.grants)) !== JSON.stringify(byId(policy.grants))) {
    throw new Error('invalid issuer grants');
  }
}

/**
 * Returns a node:http handler to mount in an existing authenticated backend.
 * verifyIdentity(req, {signal}) must verify the CURRENT host credential and
 * return {subject}; resolvePolicy(subject, {signal}) returns server-owned
 * {enabled, revision, grants}. Adapters throw IdentityRejected/AccessDenied.
 * loadServerKey({signal}) retrieves a registered ak_ credential server-side.
 */
export function createVmodalSessionHandler({
  verifyIdentity, resolvePolicy, loadServerKey, projectId, vmodalOrigin,
  fetchImpl = fetch, timeoutMs = 10000, expiresIn = 300,
}) {
  for (const fn of [verifyIdentity, resolvePolicy, loadServerKey, fetchImpl]) {
    if (typeof fn !== 'function') throw new TypeError('adapter required');
  }
  const origin = new URL(vmodalOrigin);
  if (!['http:', 'https:'].includes(origin.protocol) || origin.username ||
      origin.password || origin.search || origin.hash || origin.pathname !== '/' ||
      typeof projectId !== 'string' || !projectId ||
      !Number.isInteger(timeoutMs) || timeoutMs < 1 ||
      !Number.isInteger(expiresIn) || expiresIn < 60 || expiresIn > 900) {
    throw new TypeError('invalid backend configuration');
  }
  const issuer = new URL('/api/v1/auth/scoped-token', origin);
  return async (req, res) => {
    if (req.url !== '/vmodal/session') return reply(res, 404, 'not_found');
    if (req.method !== 'POST') return reply(res, 405, 'method_not_allowed', { allow: 'POST' });
    const signal = AbortSignal.timeout(timeoutMs);
    let status = 503;
    let code = 'issuer_unavailable';
    let retryAfter;
    const work = async () => {
      await emptyBody(req);
      const identity = await verifyIdentity(req, { signal });
      if (!identity || typeof identity.subject !== 'string' || !identity.subject) {
        throw new IdentityRejected();
      }
      const policy = await resolvePolicy(identity.subject, { signal });
      if (!policy?.enabled || typeof policy.revision !== 'string' ||
          !policy.revision || !Array.isArray(policy.grants) || !policy.grants.length) {
        throw new AccessDenied();
      }
      signal.throwIfAborted();
      const serverKey = await loadServerKey({ signal });
      if (typeof serverKey !== 'string' || !serverKey.startsWith('ak_')) {
        throw new Error('server credential unavailable');
      }
      signal.throwIfAborted();
      const response = await fetchImpl(issuer, {
        method: 'POST', redirect: 'error', signal,
        headers: { authorization: `Bearer ${serverKey}`, 'content-type': 'application/json' },
        body: JSON.stringify({
          version: 1, project_id: projectId, app_user_id: identity.subject,
          policy_revision: policy.revision, expires_in: expiresIn, grants: policy.grants,
        }),
      });
      if (!response.ok) {
        if (response.status === 429) {
          status = 429;
          code = 'rate_limited';
          const value = response.headers.get('retry-after');
          if (/^\d{1,4}$/.test(value ?? '')) retryAfter = String(Math.min(900, Number(value)));
        } else if (response.status >= 400 && response.status < 500) {
          status = 502;
          code = 'issuer_contract_rejected';
        }
        // Issuer failure details may contain operational data: never relay them.
        throw new Error('issuer rejected');
      }
      status = 502;
      code = 'issuer_contract_rejected';
      const data = await issuerJson(response);
      checkEnvelope(data, identity, policy, projectId, serverKey);
      signal.throwIfAborted();
      return data;
    };
    let cancel;
    const aborted = new Promise((_, reject) => {
      cancel = () => reject(signal.reason);
      signal.addEventListener('abort', cancel, { once: true });
    });
    try {
      const data = await Promise.race([work(), aborted]);
      res.writeHead(200, {
        'content-type': 'application/json', 'cache-control': 'no-store', pragma: 'no-cache',
      });
      res.end(JSON.stringify(data));
    } catch (error) {
      if (signal.aborted) { status = 503; code = 'issuer_unavailable'; }
      if (error instanceof IdentityRejected) { status = 401; code = 'identity_rejected'; }
      if (error instanceof AccessDenied) { status = 403; code = 'access_denied'; }
      reply(res, status, code, retryAfter ? { 'retry-after': retryAfter } : {});
    } finally {
      signal.removeEventListener('abort', cancel);
    }
  };
}
