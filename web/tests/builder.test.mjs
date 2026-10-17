import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildCase, validateCase, messageToText, detectFormat, normaliseHl7, splitHl7Messages, hl7Label, parseLoadedFile, MAX_FILE_MESSAGES,
} from '../js/builder.js';

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

/* ---------- Load file ---------- */

const A = 'MSH|^~\&|LIS|LAB|EPR|HOSP|20261017||ORU^R01|MSG001|P|2.5';
const B = 'MSH|^~\&|PAS|HOSP|EPR|HOSP|20261017||ADT^A01|MSG002|P|2.5';

test('normaliseHl7 turns CR, CRLF and LF into one segment per line', () => {
  assert.equal(normaliseHl7(`${A}\rPID|1\r`), `${A}\nPID|1`);
  assert.equal(normaliseHl7(`${A}\r\nPID|1\r\n`), `${A}\nPID|1`);
  assert.equal(normaliseHl7(`${A}\nPID|1\n`), `${A}\nPID|1`);
  assert.equal(normaliseHl7(`${A}\r\rPID|1\n\n`), `${A}\nPID|1`, 'blank lines are dropped');
});

test('normaliseHl7 drops a BOM, MLLP framing and stray indentation', () => {
  assert.equal(normaliseHl7(`﻿\x0b${A}\rPID|1\r\x1c\r`), `${A}\nPID|1`);
  assert.equal(normaliseHl7(`  ${A}\n\tPID|1  `), `${A}\nPID|1`);
});

test('splitHl7Messages splits at each MSH and drops batch envelopes', () => {
  const file = `FHS|^~\&\rBHS|^~\&\r${A}\rPID|1\rOBX|1\r\r${B}\rPID|2\rBTS|2\rFTS|1\r`;
  assert.deepEqual(splitHl7Messages(file), [`${A}\nPID|1\nOBX|1`, `${B}\nPID|2`]);
});

test('splitHl7Messages: one message, and nothing before the first MSH', () => {
  assert.deepEqual(splitHl7Messages(`junk line\r\n${A}\r\nPID|1`), [`${A}\nPID|1`]);
  assert.deepEqual(splitHl7Messages('PID|1\nOBX|1'), []);
  assert.deepEqual(splitHl7Messages(''), []);
});

test('hl7Label reads MSH-9 and MSH-10, with any field separator', () => {
  assert.equal(hl7Label(A), 'ORU^R01 · MSG001');
  assert.equal(hl7Label('MSH#^~\&#LIS#LAB#EPR#HOSP#2026##ADT^A08#X9'), 'ADT^A08 · X9');
  assert.equal(hl7Label('MSH|^~\&'), 'HL7 message');
});

test('detectFormat recognises FHIR JSON and treats anything else as HL7', () => {
  assert.equal(detectFormat('﻿ {"resourceType":"Bundle"}\n'), 'fhir');
  assert.equal(detectFormat('[{"resourceType":"Patient"}]'), 'fhir');
  assert.equal(detectFormat(A), 'hl7v2');
  assert.equal(detectFormat('{not json'), 'hl7v2');
});

test('parseLoadedFile: FHIR is one message kept as written, named by resourceType', () => {
  const p = parseLoadedFile('{\n  "resourceType": "Observation"\n}\n');
  assert.equal(p.error, '');
  assert.equal(p.format, 'fhir');
  assert.deepEqual(p.messages, [{ label: 'FHIR Observation', text: '{\n  "resourceType": "Observation"\n}' }]);
});

test('parseLoadedFile: several HL7 messages, labelled in order', () => {
  const p = parseLoadedFile(`${A}\r\nPID|1\r\n${B}\r\nPID|2\r\n`);
  assert.equal(p.error, '');
  assert.equal(p.format, 'hl7v2');
  assert.deepEqual(p.messages.map((m) => m.label), ['1. ORU^R01 · MSG001', '2. ADT^A01 · MSG002']);
  assert.equal(p.messages[1].text, `${B}\nPID|2`);
});

test('parseLoadedFile explains files it cannot use', () => {
  assert.match(parseLoadedFile('  \n').error, /empty/);
  assert.match(parseLoadedFile('hello world').error, /MSH/);
  assert.match(parseLoadedFile('{"resourceType": ').error, /JSON/);
  assert.match(parseLoadedFile(`${A}\n`.repeat(MAX_FILE_MESSAGES + 1)).error, /at most/);
});

test('a loaded HL7 message builds a case with \r separators that validates', () => {
  const [m] = parseLoadedFile(`${A}\r\nPID|1\r\n`).messages;
  const c = buildCase(base, edits({ message: m.text }));
  assert.equal(c.raw_message, `${A}\rPID|1`);
  assert.deepEqual(validateCase(c), []);
});
