import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { detectSource, modelsView, keysFor, tabStore } from '../js/source.js';

const bundle = JSON.parse(readFileSync(new URL('../data/bundle.json', import.meta.url), 'utf8'));
const down = () => Promise.reject(new Error('offline'));
const replay = () => detectSource(down, 2000, { bundle });

test('bundle has the documented schema', () => {
  assert.deepEqual(bundle.models, { fast: 'Jev', agent: 'Gemma' });
  assert.ok(bundle.recordedAt && bundle.build);
  assert.ok(bundle.scenarios.length >= 4);
  for (const s of bundle.scenarios) assert.ok(s.id && s.label && s.case && s.decision);
  assert.equal(bundle.batches.length, 3);
  for (const b of bundle.batches) {
    assert.equal(b.length, 5);
    for (const r of b) assert.ok(r.case && r.expected && r.decision);
  }
});

test('a rejecting fetch falls back to replay in under 2 s', async () => {
  const t0 = Date.now();
  const src = await replay();
  assert.equal(src.mode, 'replay');
  assert.ok(Date.now() - t0 < 2000);
});

test('a hanging fetch times out into replay', async () => {
  const t0 = Date.now();
  const src = await detectSource(() => new Promise(() => {}), 100, { bundle });
  assert.equal(src.mode, 'replay');
  assert.ok(Date.now() - t0 < 1000);
});

test('a live health response selects live mode and calls the base URL', async () => {
  const calls = [];
  const stub = async (url, init) => {
    calls.push([String(url), init]);
    return { ok: true, status: 200, json: async () => ({ mode: 'live', aihub: false, build: 'x' }) };
  };
  const src = await detectSource(stub, 2000, { base: 'http://h/medic/api' });
  assert.equal(src.mode, 'live');
  assert.equal(calls[0][0], 'http://h/medic/api/health');
  await src.triage({ case_id: 'a' });
  const post = calls.at(-1);
  assert.equal(post[0], 'http://h/medic/api/triage');
  assert.equal(post[1].method, 'POST');
  assert.equal(post[1].headers['Content-Type'], 'application/json');
  assert.equal(post[1].body, JSON.stringify({ case: { case_id: 'a' } }));
});

test('live errors surface the API error text and status', async () => {
  const stub = async (url) => (String(url).endsWith('/health')
    ? { ok: true, status: 200, json: async () => ({ mode: 'live' }) }
    : { ok: false, status: 409, json: async () => ({ error: 'already decided by a person' }) });
  const src = await detectSource(stub, 2000, { base: 'http://h/medic/api' });
  await assert.rejects(() => src.approve('5'), (e) => e.status === 409 && /already decided/.test(e.message));
});

test('replay triage of a recorded case is tagged replay, an edited copy mock', async () => {
  const src = await replay();
  const recorded = bundle.scenarios[0].case;
  const d1 = await src.triage(structuredClone(recorded));
  assert.equal(d1.source, 'replay');
  assert.equal(d1.id, bundle.scenarios[0].decision.id);
  const edited = { ...structuredClone(recorded), error_text: `${recorded.error_text} (edited)` };
  const d2 = await src.triage(edited);
  assert.equal(d2.source, 'mock');
  assert.equal(d2.provider, 'browser mock');
});

test('replay scenarios and randomCases expose cases without decisions', async () => {
  const src = await replay();
  const sc = await src.scenarios();
  assert.equal(sc.length, bundle.scenarios.length);
  assert.ok(!('decision' in sc[0]));
  const r = await src.randomCases(5);
  assert.equal(r.length, 5);
  assert.ok(r[0].case && r[0].expected && !('decision' in r[0]));
});

test('replay approve adds a hum step and a simulated audit row; a second approve rejects', async () => {
  const src = await replay();
  const s = bundle.scenarios.find((x) => !x.decision.autoApplied);
  const d = await src.triage(s.case);
  const res = await src.approve(d.id);
  assert.equal(res.ok, 1);
  assert.equal(res.precedent, 0);
  assert.equal(res.trace.at(-1).status, 'hum');
  assert.ok(res.audit.some((a) => a.detail.endsWith(' (simulated)')));
  await assert.rejects(() => src.approve(d.id), (e) => e.status === 409);
});

test('replay override validates and records the correction', async () => {
  const src = await replay();
  const s = bundle.scenarios.find((x) => !x.decision.autoApplied);
  const d = await src.triage(s.case);
  await assert.rejects(() => src.override(d.id, 'bogus'), (e) => e.status === 400);
  await assert.rejects(() => src.override(d.id, 'reroute', ''), (e) => e.status === 400);
  await assert.rejects(() => src.override(d.id, 'reroute', 'Nowhere'), (e) => e.status === 400);
  const res = await src.override(d.id, 'quarantine', '', 'looks odd');
  assert.equal(res.decision.action, 'quarantine');
  assert.equal(res.decision.decidedBy, 'human');
  assert.equal(res.trace.at(-1).status, 'hum');
  assert.equal(res.precedent, 0);
  await assert.rejects(() => src.override(d.id, 'resend'), (e) => e.status === 409);
});

test('replay reroute override accepts a target from the routing table', async () => {
  const src = await replay();
  const s = bundle.scenarios.find((x) => !x.decision.autoApplied);
  const d = await src.triage(s.case);
  const target = Object.values(s.case.context.routing_table)[0];
  const res = await src.override(d.id, 'reroute', target, 'wrong receiver');
  assert.equal(res.decision.action, 'reroute');
  assert.equal(res.decision.rerouteTarget, target);
});

test('replay approve rejects an auto-applied mock decision and unknown ids', async () => {
  const src = await replay();
  const s = bundle.scenarios.find((x) => x.id === 'unknown_receiver');
  const edited = { ...structuredClone(s.case), case_id: 'edited-1' };
  const d = await src.triage(edited);
  assert.equal(d.source, 'mock');
  assert.equal(d.autoApplied, 1);
  await assert.rejects(() => src.approve(d.id), (e) => e.status === 409);
  await assert.rejects(() => src.approve('nope'), (e) => e.status === 404);
});

test('replay models are fixed to the recorded ones', async () => {
  const src = await replay();
  const m = await src.models();
  assert.equal(m.fast, bundle.models.fast);
  assert.equal(m.agent, bundle.models.agent);
  const after = await src.setModels('Mock', 'Mock');
  assert.equal(after.fast, bundle.models.fast);
});

const server = {
  fast: 'Mock', agent: 'Mock',
  available: { fast: ['Mock', 'Jev'], agent: ['Mock', 'Gemini'] },
  unavailable: { fast: [], agent: [{ label: 'Claude', need: 'ANTHROPIC_API_KEY', provider: 'anthropic', keyable: true }] },
  providers: { fast: {}, agent: { Gemini: 'gemini', Claude: 'anthropic' } },
};

test('a judge key turns a greyed-out model on, only in that view', () => {
  const v = modelsView(server, { fast: 'Mock', agent: 'Claude' }, { anthropic: 'sk-x' });
  assert.deepEqual(v.available.agent, ['Mock', 'Gemini', 'Claude']);
  assert.deepEqual(v.unavailable.agent, []);
  assert.equal(v.agent, 'Claude');
  const without = modelsView(server, { fast: 'Mock', agent: 'Claude' }, {});
  assert.equal(without.agent, 'Mock', 'an unusable choice falls back to the server default');
  assert.deepEqual(server.available.agent, ['Mock', 'Gemini'], 'the server object is not modified');
});

test('a triage sends only the keys its chosen models need', () => {
  const keys = { anthropic: 'sk-a', gemini: 'g-1', xai: 'x-1' };
  assert.deepEqual(keysFor(server, { fast: 'Mock', agent: 'Claude' }, keys), { anthropic: 'sk-a' });
  assert.deepEqual(keysFor(server, { fast: 'Mock', agent: 'Mock' }, keys), {});
});

test('live triage carries the tab models and keys; setModels never posts', async () => {
  const calls = [];
  const stub = async (url, init) => {
    calls.push([String(url), init]);
    const body = String(url).endsWith('/health') ? { mode: 'live' } : String(url).endsWith('/models') ? server : { ok: 1 };
    return { ok: true, status: 200, json: async () => body };
  };
  const store = tabStore(null);
  const src = await detectSource(stub, 2000, { base: 'http://h/medic/api', store });
  await src.models();
  src.setKeys({ anthropic: ' sk-a ', gemini: '' });
  const v = await src.setModels('Mock', 'Claude');
  assert.equal(v.agent, 'Claude');
  assert.ok(!calls.some(([u, i]) => u.endsWith('/models') && i?.method === 'POST'), 'no server-wide switch');
  await src.triage({ case_id: 'a' });
  assert.deepEqual(JSON.parse(calls.at(-1)[1].body),
    { case: { case_id: 'a' }, models: { fast: 'Mock', agent: 'Claude' }, keys: { anthropic: 'sk-a' } });
  assert.deepEqual(store.get('medic.keys'), { anthropic: 'sk-a' }, 'blank keys are dropped, others trimmed');
});
