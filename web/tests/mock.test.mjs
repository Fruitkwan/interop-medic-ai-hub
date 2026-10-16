import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { mockDecide, closestRoute } from '../js/mock.js';

const cases = readFileSync(new URL('../../dataset/cases.jsonl', import.meta.url), 'utf8')
  .split('\n').filter(Boolean).map((l) => JSON.parse(l));

// First case of each corruption type.
const firstOfType = new Map();
for (const c of cases) if (!firstOfType.has(c.corruption)) firstOfType.set(c.corruption, c);

test('dataset has 16 corruption types', () => {
  assert.equal(firstOfType.size, 16);
});

test('mockDecide agrees with the labelled action for at least 15 of 16 types', () => {
  let agree = 0;
  const misses = [];
  for (const [type, c] of firstOfType) {
    const d = mockDecide(c);
    if (d.action === c.expected.action) agree++;
    else misses.push(`${type}: ${d.action} vs ${c.expected.action}`);
  }
  assert.ok(agree >= 15, `only ${agree}/16 agree: ${misses.join('; ')}`);
});

test('every trace ends with a Policy step and the decision has the API shape', () => {
  for (const c of firstOfType.values()) {
    const d = mockDecide(c);
    assert.equal(d.trace.at(-1).stage, 'Policy');
    assert.equal(d.trace[0].stage, 'Mock');
    assert.equal(d.caseId, c.case_id);
    assert.equal(d.provider, 'browser mock');
    assert.equal(d.costUSD, 0);
    assert.deepEqual(d.audit, []);
    for (const k of ['id', 'action', 'confidence', 'severity', 'rationale', 'proposedFix',
      'rerouteTarget', 'decidedBy', 'autoApplied', 'latencyMs']) assert.ok(k in d, k);
  }
});

test('gate trusts a confident low-severity fast verdict', () => {
  const d = mockDecide(firstOfType.get('endpoint_timeout'));
  assert.deepEqual(d.trace.map((s) => s.stage), ['Mock', 'Gate', 'Policy']);
  assert.equal(d.trace[1].status, 'ok');
  assert.equal(d.trace[1].value, 'trusted');
  assert.equal(d.decidedBy, 'fast');
  assert.equal(d.autoApplied, 0); // 0.88 < 0.9
});

test('critical result stuck behind an outage goes to the agent and escalates', () => {
  const d = mockDecide(firstOfType.get('outage_critical_result'));
  assert.equal(d.action, 'escalate');
  assert.equal(d.decidedBy, 'agent');
  const gate = d.trace.find((s) => s.stage === 'Gate');
  assert.equal(gate.status, 'warn');
  assert.equal(gate.value, 'to agent');
  assert.equal(gate.detail, 'severity 0.90 ≥ .6');
  assert.ok(d.trace.some((s) => s.stage === 'Agent'));
  assert.ok(!d.trace.some((s) => s.stage === 'SearchPrecedents'));
});

test('reroute always goes to the agent, which resolves the target with ClosestRoute', () => {
  const d = mockDecide(firstOfType.get('unknown_receiver'));
  assert.equal(d.action, 'reroute');
  assert.ok(d.rerouteTarget);
  const gate = d.trace.find((s) => s.stage === 'Gate');
  assert.equal(gate.detail, 'reroute needs a target');
  assert.ok(d.trace.some((s) => s.stage === 'ClosestRoute'));
});

test('a high-confidence agent decision is auto-applied (dry run off)', () => {
  const d = mockDecide(firstOfType.get('unknown_receiver'));
  assert.equal(d.autoApplied, 1);
  assert.equal(d.trace.at(-1).value, 'auto-apply');
  assert.equal(d.trace.at(-1).status, 'ok');
});

test('closestRoute mirrors Medic.Tools.ClosestRoute', () => {
  const t = { EPR: 'Medic.To.EPR', LAB: 'Medic.To.LIS', PACS: 'Medic.To.PACS' };
  assert.equal(closestRoute('EPRR', t), 'Medic.To.EPR');
  assert.equal(closestRoute('EP R', t), 'Medic.To.EPR');
  assert.equal(closestRoute('LAB_TEST', t), 'Medic.To.LIS');
  assert.equal(closestRoute('LBA', t), 'Medic.To.LIS');
  assert.equal(closestRoute('PAC', t), 'Medic.To.PACS');
  assert.equal(closestRoute('XYZ', t), '');
  assert.equal(closestRoute('', t), '');
});
