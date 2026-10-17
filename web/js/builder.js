// Build-your-own: turn the judge's edits into a case object and check it before it is sent.
// Pure functions, unit-tested in web/tests/builder.test.mjs. The panel itself lives in hub.js.

export const MAX_MESSAGE_CHARS = 100000;

/** Text for the textarea: HL7 segments (separated by \r on the wire) shown one per line. */
export function messageToText(raw, format) {
  const s = String(raw ?? '');
  return format === 'fhir' ? s : s.replace(/\r\n|\r/g, '\n');
}

/**
 * A new case from a starting scenario plus the panel's edits.
 * @param {object} base a case as served by /scenarios
 * @param {{format?:string, message:string, errorText:string, up:boolean, downMinutes:number|string}} edits
 */
export function buildCase(base, edits) {
  const format = edits.format ?? base.format;
  const text = String(edits.message ?? '');
  const raw = format === 'fhir' ? text : text.replace(/\r\n|\n/g, '\r');
  const c = structuredClone(base);
  delete c.clean_message;
  c.case_id = `custom-${Date.now()}`;
  c.corruption = 'custom';
  c.format = format;
  c.raw_message = raw;
  c.error_text = String(edits.errorText ?? '');
  c.context = c.context ?? {};
  c.context.endpoint = {
    ...(c.context.endpoint ?? {}),
    up: Boolean(edits.up),
    down_minutes: edits.downMinutes === '' ? 0 : Number(edits.downMinutes),
  };
  return c;
}

/* ---------- Load file: read in the browser, never uploaded until Run ---------- */

/** Largest file the panel will read (a batch of messages, each still held to MAX_MESSAGE_CHARS). */
export const MAX_FILE_BYTES = 5 * 1024 * 1024;
export const MAX_FILE_MESSAGES = 50;

/** 'fhir' when the text is a JSON object or array, else 'hl7v2'. */
export function detectFormat(text) {
  const s = String(text ?? '').replace(/^﻿/, '').trim();
  if (!s.startsWith('{') && !s.startsWith('[')) return 'hl7v2';
  try { JSON.parse(s); return 'fhir'; } catch { return 'hl7v2'; }
}

/**
 * HL7 text with one segment per line: drops a byte-order mark and MLLP framing (VT, FS),
 * turns CR, CRLF and LF into LF, and removes blank lines and stray leading whitespace.
 */
export function normaliseHl7(text) {
  return String(text ?? '')
    .replace(/^﻿/, '')
    .replace(/[\x0b\x1c]/g, '\n')
    .split(/\r\n|\r|\n/)
    .map((line) => line.trim())
    .filter((line) => line !== '')
    .join('\n');
}

/**
 * The HL7 messages in a file, each one segment per line. A message starts at an MSH segment; batch
 * envelope segments (FHS, BHS, BTS, FTS) and anything before the first MSH are dropped.
 */
export function splitHl7Messages(text) {
  const out = [];
  for (const line of normaliseHl7(text).split('\n')) {
    if (/^(FHS|BHS|BTS|FTS)(\W|$)/.test(line)) continue;
    if (line.startsWith('MSH')) out.push([line]);
    else if (out.length) out.at(-1).push(line);
  }
  return out.map((segs) => segs.join('\n'));
}

/** A short name for one HL7 message: "ADT^A01 · MSG00001" from MSH-9 and MSH-10. */
export function hl7Label(message) {
  const msh = String(message ?? '').split('\n')[0];
  const sep = msh.charAt(3) || '|';
  const f = msh.split(sep);
  // MSH-1 is the separator itself, so MSH-n sits at index n-1.
  return [f[8], f[9]].filter((x) => x && x.trim()).join(' · ') || 'HL7 message';
}

/**
 * What a loaded file holds: {format, messages: [{label, text}], error}. `error` is '' when it can be
 * used. FHIR JSON is one message, kept as written; HL7 is split at each MSH segment.
 */
export function parseLoadedFile(text) {
  const s = String(text ?? '').replace(/^﻿/, '');
  if (s.trim() === '') return { format: 'hl7v2', messages: [], error: 'The file is empty.' };
  if (detectFormat(s) === 'fhir') {
    let rt = '';
    try { rt = JSON.parse(s).resourceType ?? ''; } catch { /* detectFormat parsed it */ }
    return { format: 'fhir', messages: [{ label: rt ? `FHIR ${rt}` : 'FHIR resource', text: s.trim() }], error: '' };
  }
  const msgs = splitHl7Messages(s);
  if (!msgs.length) {
    const json = /^\s*[[{]/.test(s);
    return {
      format: 'hl7v2', messages: [],
      error: json ? 'The file looks like JSON but does not parse.' : 'No HL7 message found: the file has no MSH segment.',
    };
  }
  if (msgs.length > MAX_FILE_MESSAGES) {
    return { format: 'hl7v2', messages: [], error: `The file has ${msgs.length} messages; load at most ${MAX_FILE_MESSAGES}.` };
  }
  return { format: 'hl7v2', messages: msgs.map((m, i) => ({ label: `${i + 1}. ${hl7Label(m)}`, text: m })), error: '' };
}

/** Messages for everything wrong with a built case; [] when it can be sent. */
export function validateCase(c) {
  const out = [];
  const raw = String(c?.raw_message ?? '');
  if (raw.trim() === '') out.push('The message is empty: paste or type the failed message.');
  else if (raw.length > MAX_MESSAGE_CHARS) out.push('The message is over 100,000 characters: shorten it.');
  else if (c.format === 'fhir') {
    try { JSON.parse(raw); } catch { out.push('A FHIR message must be valid JSON.'); }
  }
  const mins = c?.context?.endpoint?.down_minutes;
  if (!Number.isFinite(mins) || mins < 0) out.push('Minutes down must be a number, zero or more.');
  return out;
}
