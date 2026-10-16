// Browser port of the offline mock models, so the page can triage any case without IRIS.
// Source of truth (keep in step): src/Medic/Provider/JevMock.cls, src/Medic/Provider/AgentMock.cls,
// the gate in src/Medic/Operation/Agent.cls, src/Medic/Policy/AutoApply.cls and
// Medic.Tools.ClosestRoute. There is no precedent store here, so no SearchPrecedents step.

const FAST_CONFIDENCE = 0.85; // Agent gate: minimum fast confidence to trust it
const FAST_SEVERITY_CEILING = 0.6; // Agent gate: at or above this the agent always runs
const AUTO_APPLY_THRESHOLD = 0.9; // AutoApply: dry run is off in the page
const GE = '≥';

let counter = 0;

/** Number to text the way ObjectScript concatenates it: 0.85 becomes ".85". */
const num = (x) => String(x).replace(/^(-?)0\./, '$1.');
/** $fnumber(x, "", 2). */
const f2 = (x) => x.toFixed(2);
const now = () => (globalThis.performance ? globalThis.performance.now() : Date.now());

/** Letters of the text in alphabetical order (Medic.Tools.SortedLetters). */
function sortedLetters(text) {
  return [...text].sort().join('');
}

/**
 * Best known route for a misspelt receiver: exact, prefix, or same letters after normalising
 * (EPRR, EP R -> EPR; LAB_TEST, LBA -> LAB; PAC -> PACS). Port of Medic.Tools.ClosestRoute.
 * @param {string} receiver
 * @param {Object<string,string>} table receiver -> config name
 * @returns {string} the target, or "" when nothing matches
 */
export function closestRoute(receiver, table) {
  const norm = String(receiver ?? '').toUpperCase().replace(/[^\p{L}]/gu, '');
  if (norm === '') return '';
  let best = '';
  for (const [key, target] of Object.entries(table ?? {})) {
    if (norm === key) return target;
    const prefix = norm.startsWith(key) || (norm.length >= 3 && key.startsWith(norm));
    if (prefix || sortedLetters(norm) === sortedLetters(key)) best = target;
  }
  return best;
}

const isTransport = (err) => err.includes('timed out') || err.includes('refused') || /^http 5\d\d/.test(err);
const isRouting = (err) => err.includes('no routing rule') || err.includes('no target');
const isDate = (err) => err.includes('invalid ts') || err.includes('pid field 7');

/** Port of Medic.Provider.JevMock.Decide: keyword rules over the error text. */
function jevDecide(errorText, raw) {
  const err = errorText.toLowerCase();
  const critical = raw.includes('|HH|') || raw.includes('|LL|');
  const r = (action, confidence, severity, rationale) => ({ action, confidence, severity, rationale, proposedFix: '' });

  if (err.includes('duplicate')) return r('quarantine', 0.95, 0.1, 'Message control ID already processed');
  if (err.includes('mpi mismatch')) return r('escalate', 0.6, 0.9, 'Patient identity conflict');
  if (isTransport(err)) {
    return r('resend', 0.88, critical ? 0.9 : 0.3, 'Transport failure; message itself looks valid');
  }
  if (isRouting(err)) return r('reroute', 0.7, 0.4, 'Receiving application not in routing table');
  if (isDate(err)) {
    return r('fix_and_resend', err.includes('/') ? 0.75 : 0.86, 0.2, 'Birth date in wrong format');
  }
  if (err.includes('table 0004')) return r('fix_and_resend', 0.87, 0.25, 'Non-standard patient class code');
  if (err.includes('unexpectedsegment')) return r('fix_and_resend', 0.85, 0.2, 'Segments out of order');
  if (err.includes('pid:3') || err.includes('pid-3')) return r('escalate', 0.9, 0.7, 'No patient identifier');
  if (err.includes('unexpected end') || err.includes('malformed')) {
    return r('quarantine', 0.8, 0.5, 'Message is truncated or malformed');
  }
  if (err.includes('unknown resourcetype')) return r('fix_and_resend', 0.9, 0.15, 'Wrong resourceType casing');
  if (err.includes('birthdate')) return r('fix_and_resend', 0.88, 0.2, 'FHIR date not in YYYY-MM-DD');
  if (err.includes('subject is required')) return r('escalate', 0.85, 0.8, 'Result has no patient reference');
  return r('escalate', 0.3, 0.5, 'Unrecognised failure');
}

/**
 * Port of Medic.Provider.AgentMock.Decide (minus precedents). Appends its tool steps to
 * `trace` and returns the decision fields, including rerouteTarget.
 */
function agentDecide(errorText, raw, ctx, hint, trace) {
  const err = errorText.toLowerCase();
  const critical = raw.includes('|HH|') || raw.includes('|LL|');
  const downMin = +(ctx?.endpoint?.down_minutes ?? 0) || 0;
  const r = (action, confidence, severity, rationale, proposedFix = '', rerouteTarget = '') => (
    { action, confidence, severity, rationale, proposedFix, rerouteTarget });

  if (isTransport(err)) {
    if (critical && downMin >= 120) {
      return r('escalate', 0.92, 0.95,
        `Critical result undelivered for ${downMin} minutes; a clinician must be told now`,
        `Phone the ward with the result; resend when ${ctx?.endpoint?.name ?? ''} recovers`);
    }
    return r('resend', 0.9, critical ? 0.6 : 0.3,
      `Transient transport failure (${downMin} min); message is valid`, 'Resend unchanged');
  }
  if (isRouting(err)) {
    const bad = errorText.split("'")[1] ?? '';
    const target = closestRoute(bad, ctx?.routing_table);
    trace.push({
      stage: 'ClosestRoute', status: target === '' ? 'warn' : 'ok',
      value: target === '' ? 'no match' : target, detail: `receiver '${bad}'`, ms: 0,
    });
    if (target === '') return r('escalate', 0.6, 0.4, `Receiver '${bad}' matches no known route`);
    return r('reroute', 0.9, 0.4, `Receiver '${bad}' is a variant of a known route`, `Send to ${target}`, target);
  }
  if (isDate(err)) {
    const v = errorText.split("'")[1] ?? '';
    const a = parseInt(v.slice(0, 2), 10) || 0;
    const b = parseInt(v.slice(3, 5), 10) || 0;
    if (/^\d\d\/\d\d\/\d{4}$/.test(v) && a <= 12 && b <= 12 && a !== b) {
      return r('escalate', 0.85, 0.5,
        `Birth date '${v}' is ambiguous (day/month order); guessing risks a wrong-patient match`,
        'Confirm DOB with the source system');
    }
    return r('fix_and_resend', 0.9, 0.2, 'Birth date in a non-HL7 format', `Set PID-7 to ${v.replace(/[/-]/g, '')}`);
  }
  if (hint) {
    return r(hint.action, hint.confidence, hint.severity, `Agent concurs with fast pass: ${hint.rationale}`);
  }
  return r('escalate', 0.3, 0.5, 'No rule applies; needs a person');
}

/**
 * Triage a case with the browser mock models: fast tier, gate, agent when needed, policy.
 * Returns the same decision JSON as POST /medic/api/triage (provider "browser mock", cost 0).
 * @param {object} caseObj a case as served by /scenarios (case_id, raw_message, error_text, context)
 * @returns {object} decision JSON
 */
export function mockDecide(caseObj) {
  const start = now();
  const errorText = String(caseObj?.error_text ?? '');
  const raw = String(caseObj?.raw_message ?? '');
  const ctx = caseObj?.context ?? {};
  const elapsed = () => Math.floor(now() - start);

  const fast = jevDecide(errorText, raw);
  const trace = [{
    stage: 'Mock', status: 'ok', value: `${fast.action} ${f2(fast.confidence)}`,
    detail: fast.rationale, ms: elapsed(),
  }];

  let reason = '';
  if (fast.action === 'reroute') reason = 'reroute needs a target';
  else if (fast.confidence < FAST_CONFIDENCE) {
    reason = `confidence ${f2(fast.confidence)} < ${num(FAST_CONFIDENCE)}`;
  } else if (fast.severity >= FAST_SEVERITY_CEILING) {
    reason = `severity ${f2(fast.severity)} ${GE} ${num(FAST_SEVERITY_CEILING)}`;
  }

  let final;
  let decidedBy;
  if (reason === '') {
    trace.push({
      stage: 'Gate', status: 'ok', value: 'trusted', ms: 0,
      detail: `confidence ${f2(fast.confidence)} ${GE} ${num(FAST_CONFIDENCE)}, `
        + `severity ${f2(fast.severity)} < ${num(FAST_SEVERITY_CEILING)}`,
    });
    final = { ...fast, rerouteTarget: '' };
    decidedBy = 'fast';
  } else {
    trace.push({ stage: 'Gate', status: 'warn', value: 'to agent', detail: reason, ms: 0 });
    final = agentDecide(errorText, raw, ctx, fast, trace);
    trace.push({
      stage: 'Agent', status: 'ok', value: `${final.action} ${f2(final.confidence)}`,
      detail: final.rationale, ms: 0,
    });
    decidedBy = 'agent';
  }

  // Medic.Policy.AutoApply with the dry run off.
  const autoApplied = final.action !== 'escalate' && final.confidence >= AUTO_APPLY_THRESHOLD;
  trace.push({
    stage: 'Policy', status: autoApplied ? 'ok' : 'warn',
    value: autoApplied ? 'auto-apply' : 'held for a person',
    detail: `threshold ${num(AUTO_APPLY_THRESHOLD)}`, ms: 0,
  });

  counter += 1;
  return {
    id: `mock-${counter}`,
    caseId: caseObj?.case_id ?? '',
    action: final.action,
    confidence: final.confidence,
    severity: final.severity,
    rationale: final.rationale,
    proposedFix: final.proposedFix,
    rerouteTarget: final.rerouteTarget,
    decidedBy,
    provider: 'browser mock',
    autoApplied: autoApplied ? 1 : 0,
    latencyMs: elapsed(),
    costUSD: 0,
    trace,
    audit: [],
  };
}
