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
