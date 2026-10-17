import test from 'node:test';
import assert from 'node:assert/strict';
import { stepRows, overruled, kpis, replayLabel } from '../js/hub.js';

const trace = [
  { stage: 'Jev', status: 'warn', value: 'resend 0.42', detail: 'Jev sees a timeout', ms: 300 },
  { stage: 'Gate', status: 'warn', value: 'to agent', detail: '0.42 < 0.85', ms: 0 },
  { stage: 'Agent', status: 'bad', value: 'escalate 0.95', detail: 'Hb undelivered', ms: 18000 },
];

test('stepRows numbers the steps from 1 and keeps their fields', () => {
  const rows = stepRows(trace);
  assert.deepEqual(rows.map((r) => r.n), [1, 2, 3]);
  assert.deepEqual(rows[0], { n: 1, stage: 'Jev', status: 'warn', value: 'resend 0.42', detail: 'Jev sees a timeout' });
  assert.deepEqual(stepRows(undefined), []);
});

test('overruled: Jev resend then final escalate is an overrule', () => {
  assert.equal(overruled({ action: 'escalate', trace }), true);
});

test('overruled: false when the fast tier and the final action match', () => {
  assert.equal(overruled({ action: 'resend', trace }), false);
  assert.equal(overruled({ action: 'resend', trace: [] }), false);
});

const row = (expected, action, latencyMs, costUSD, decidedBy = 'agent') =>
  ({ expected: { action: expected }, decision: { action, latencyMs, costUSD, decidedBy } });

test('kpis counts correct rows, the fast share, the mean cost and the median time', () => {
  const k = kpis([
    row('resend', 'resend', 500, 0.001, 'fast'),
    row('escalate', 'escalate', 20000, 0.003),
    row('reroute', 'escalate', 9000, 0.002),
  ]);
  assert.equal(k.correct, 2);
  assert.equal(k.total, 3);
  assert.equal(k.medianMs, 9000);
  assert.ok(Math.abs(k.fastShare - 1 / 3) < 1e-9);
  assert.ok(Math.abs(k.costPerDecision - 0.002) < 1e-12);
});

test('kpis of no rows has total 0 and no averages', () => {
  const k = kpis([]);
  assert.equal(k.total, 0);
  assert.equal(k.correct, 0);
  assert.equal(k.medianMs, null);
  assert.equal(k.costPerDecision, null);
  assert.equal(k.fastShare, null);
});

test('overruled: false when the agent was unavailable', () => {
  const failed = [trace[0], { stage: 'Agent', status: 'bad', value: 'unavailable', detail: 'AI Hub agent unavailable: x' }];
  assert.equal(overruled({ action: 'escalate', trace: failed }), false);
});

test('replayLabel: mock recordings are not called real', () => {
  assert.equal(replayLabel({ fast: 'Mock', agent: 'Mock' }), 'Replay (mock models)');
  assert.equal(replayLabel({ fast: 'Jev', agent: 'Gemini' }), 'Replay of a real run');
  assert.equal(replayLabel({ fast: 'Mock', agent: 'Gemini' }), 'Replay of a real run');
  assert.equal(replayLabel(null), 'Replay of a real run');
});
