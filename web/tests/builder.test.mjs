import test from 'node:test';
import assert from 'node:assert/strict';
import { buildCase, validateCase, messageToText } from '../js/builder.js';

const base = {
  case_id: 'endpoint_timeout-7-0000', corruption: 'endpoint_timeout', format: 'hl7v2',
  raw_message: 'MSH|^~\&|LIS\rPID|1||1\rOBX|1|NM|718-7||16.9|g/dL|12-17|N|||F\r',
  clean_message: 'MSH|x\r',
  error_text: 'ERROR #5023: timed out',
  context: { routing_table: { EPR: 'Medic.To.EPR' }, endpoint: { name: 'Medic.To.EPR', up: true, down_minutes: 12, last_error: 'old' } },
};
const edits = (o = {}) => ({ format: 'hl7v2', message: 'MSH|a\nPID|1', errorText: 'boom', up: false, downMinutes: 600, ...o });

test('messageToText shows HL7 segments on separate lines', () => {
  assert.equal(messageToText('MSH|a\rPID|1\r', 'hl7v2'), 'MSH|a\nPID|1\n');
  assert.equal(messageToText('{"a":1}', 'fhir'), '{"a":1}');
});

test('buildCase restores \r segment separators for HL7, including from CRLF', () => {
  assert.equal(buildCase(base, edits()).raw_message, 'MSH|a\rPID|1');
  assert.equal(buildCase(base, edits({ message: 'MSH|a\r\nPID|1\r\n' })).raw_message, 'MSH|a\rPID|1\r');
});

test('buildCase keeps FHIR text as typed and applies the edits', () => {
  const c = buildCase(base, edits({ format: 'fhir', message: '{"a":\n1}' }));
  assert.equal(c.format, 'fhir');
  assert.equal(c.raw_message, '{"a":\n1}');
  assert.equal(c.error_text, 'boom');
  assert.equal(c.context.endpoint.up, false);
  assert.equal(c.context.endpoint.down_minutes, 600);
  assert.equal(c.context.endpoint.name, 'Medic.To.EPR');
  assert.deepEqual(c.context.routing_table, base.context.routing_table);
});

test('buildCase gives a custom id, leaves the base untouched and drops the clean copy', () => {
  const c = buildCase(base, edits());
  assert.match(c.case_id, /^custom-\d+$/);
  assert.equal(base.context.endpoint.down_minutes, 12);
  assert.equal(base.raw_message.includes('\r'), true);
  assert.equal('clean_message' in c, false);
});

test('validateCase accepts a valid case', () => {
  assert.deepEqual(validateCase(buildCase(base, edits())), []);
  assert.deepEqual(validateCase(buildCase(base, edits({ format: 'fhir', message: '{"resourceType":"Bundle"}' }))), []);
});

test('validateCase: one message per problem', () => {
  const empty = validateCase(buildCase(base, edits({ message: '   ' })));
  assert.equal(empty.length, 1);
  assert.match(empty[0], /empty|message/i);
  const notJson = validateCase(buildCase(base, edits({ format: 'fhir', message: 'MSH|a' })));
  assert.equal(notJson.length, 1);
  assert.match(notJson[0], /JSON/);
  const big = validateCase(buildCase(base, edits({ message: 'x'.repeat(100001) })));
  assert.equal(big.length, 1);
  assert.match(big[0], /100/);
  const neg = validateCase(buildCase(base, edits({ downMinutes: -5 })));
  assert.equal(neg.length, 1);
  assert.match(neg[0], /minutes/i);
});

test('validateCase reports several problems together', () => {
  assert.equal(validateCase(buildCase(base, edits({ message: '', downMinutes: -1 }))).length, 2);
});
