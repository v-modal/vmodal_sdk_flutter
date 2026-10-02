import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { test } from 'node:test';
import { AccessDenied, IdentityRejected, createVmodalSessionHandler } from './session.mjs';

const grant = {
  grant_id: 'my_library', collection_id: 'library_a7f9', stream_name: 'street_study',
  mode: 'vid_file', actions: ['discover', 'search', 'media'], collection_wide: false,
};
function envelope() {
  const now = Math.floor(Date.now() / 1000) * 1000;
  return {
    version: 1, auth_mode: 'developer_backend', access_token: 'header.payload.signature',
    token_type: 'Bearer', expires_in: 300, issued_at: new Date(now).toISOString(),
    expires_at: new Date(now + 300000).toISOString(), principal_id: 'owner', tenant_id: 'tenant',
    project_id: 'demo', app_user_id: 'verified_user', policy_revision: 'policy_1',
    delegation_revision: 1, grants: [grant],
  };
}

async function request(overrides = {}, { body = '{}', method = 'POST' } = {}) {
  let call;
  const handler = createVmodalSessionHandler({
    projectId: 'demo', vmodalOrigin: 'https://users.example.com', timeoutMs: 1000,
    verifyIdentity: async req => {
      assert.equal(req.headers.authorization, 'Bearer host_session');
      return { subject: 'verified_user' };
    },
    resolvePolicy: async () => ({ enabled: true, revision: 'policy_1', grants: [grant] }),
    loadServerKey: async () => 'ak_registered_server_fixture',
    fetchImpl: async (url, init) => {
      call = { url: String(url), ...init, body: JSON.parse(init.body) };
      return Response.json(envelope());
    },
    ...overrides,
  });
  const server = createServer(handler);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    const response = await fetch(`http://127.0.0.1:${server.address().port}/vmodal/session`, {
      method, headers: { authorization: 'Bearer host_session' }, body,
    });
    return { status: response.status, headers: response.headers, data: await response.json(), call };
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
}

test('verified host subject and server policy issue unchanged scoped envelope', async () => {
  const result = await request();
  assert.equal(result.status, 200);
  assert.equal(result.data.app_user_id, 'verified_user');
  assert.deepEqual(result.data.grants, [grant]);
  assert.equal(result.headers.get('cache-control'), 'no-store');
  assert.equal(result.call.headers.authorization, 'Bearer ak_registered_server_fixture');
  assert.equal(result.call.url, 'https://users.example.com/api/v1/auth/scoped-token');
  assert.equal(result.call.redirect, 'error');
  assert.equal(result.call.body.app_user_id, 'verified_user');
  assert.ok(!JSON.stringify(result.call.body).includes('host_session'));
  assert.ok(!JSON.stringify(result.data).includes('ak_registered_server_fixture'));
});

test('identity rejection and access denial stop before server issuance', async () => {
  for (const [field, error, status] of [
    ['verifyIdentity', new IdentityRejected('secret host diagnostic'), 401],
    ['resolvePolicy', new AccessDenied('secret policy diagnostic'), 403],
  ]) {
    const result = await request({ [field]: async () => { throw error; } });
    assert.equal(result.status, status);
    assert.equal(result.call, undefined);
    assert.ok(!JSON.stringify(result.data).includes('secret'));
  }
});

test('mobile cannot choose identity, project or grants and method is fixed', async () => {
  const result = await request({}, { body: '{"app_user_id":"other"}' });
  assert.equal(result.status, 403);
  assert.equal(result.call, undefined);
  assert.equal((await request({}, { method: 'PUT' })).status, 405);
});

test('issuer errors are classified and never expose issuer secrets', async () => {
  for (const [upstream, status] of [[401, 502], [403, 502], [422, 502], [500, 503], [429, 429]]) {
    const result = await request({ fetchImpl: async () => new Response('secret issuer diagnostics', {
      status: upstream, headers: { 'retry-after': '19' },
    }) });
    assert.equal(result.status, status);
    assert.ok(!JSON.stringify(result.data).includes('secret'));
    if (status === 429) assert.equal(result.headers.get('retry-after'), '19');
  }
});

test('incorrect identity, grants, token family or extra secret fails contract', async () => {
  for (const change of [
    { app_user_id: 'other' }, { access_token: 'ak_master_key' },
    { grants: [{ ...grant, collection_id: 'other' }] }, { secret: 'unexpected' },
    { grants: [{ ...grant, server_secret: 'secret' }] },
    { expires_at: '2020-01-01T00:00:00Z' },
  ]) {
    const result = await request({ fetchImpl: async () => Response.json({ ...envelope(), ...change }) });
    assert.equal(result.status, 502);
    assert.equal(result.data.code, 'issuer_contract_rejected');
  }
});

test('each renewal re-verifies host identity and resolves policy', async () => {
  let identities = 0;
  let policies = 0;
  const adapters = {
    verifyIdentity: async () => { identities++; return { subject: 'verified_user' }; },
    resolvePolicy: async () => { policies++; return { enabled: true, revision: 'policy_1', grants: [grant] }; },
  };
  assert.equal((await request(adapters)).status, 200);
  assert.equal((await request(adapters)).status, 200);
  assert.equal(identities, 2);
  assert.equal(policies, 2);
});

test('malformed successful issuer output is a contract failure', async () => {
  const result = await request({ fetchImpl: async () => new Response('invalid JSON') });
  assert.equal(result.status, 502);
  assert.equal(result.data.code, 'issuer_contract_rejected');
});

test('issuer response decoding is covered by the acquisition timeout', async () => {
  const result = await request({
    timeoutMs: 20,
    fetchImpl: async () => new Response(new ReadableStream({ start() {} })),
  });
  assert.equal(result.status, 503);
  assert.equal(result.data.code, 'issuer_unavailable');
});

test('unresponsive host adapter reaches bounded timeout without issuance', async () => {
  const result = await request({ timeoutMs: 20, verifyIdentity: () => new Promise(() => {}) });
  assert.equal(result.status, 503);
  assert.equal(result.call, undefined);
});
