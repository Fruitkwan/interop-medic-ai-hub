// The judge page: pick a failed message, watch the fast tier, the agent's tools and the policy decide,
// then approve or override as the person on duty. Data comes from source.js (live IRIS API, or a
// recorded replay plus the browser mock models). The exported helpers are pure and unit-tested.
import { detectSource } from './source.js';
import { SAMPLE_SCENARIOS } from './samples.js';
import { buildCase, validateCase, messageToText } from './builder.js';

/* ---------- Pure helpers (tested in web/tests/hub.test.mjs) ---------- */

/**
 * Trace steps as numbered display rows.
 * @param {Array<{stage,status,value,detail}>} trace
 * @returns {Array<{n:number, stage:string, status:string, value:string, detail:string}>}
 */
export function stepRows(trace) {
  return (trace ?? []).map((s, i) => ({
    n: i + 1, stage: s.stage, status: s.status, value: s.value ?? '', detail: s.detail ?? '',
  }));
}

/**
 * True when the fast tier's action (the first word of the first trace step's value) differs from
 * the decision's final action. Call it on the decision as triaged, before a person acts.
 * @param {{action:string, trace:Array}} decision
 */
export function overruled(decision) {
  const trace = decision?.trace ?? [];
  // A failed agent run ("unavailable") overruled nothing.
  if (trace.some((s) => s.stage === 'Agent' && s.value === 'unavailable')) return false;
  const first = trace[0];
  const word = String(first?.value ?? '').trim().split(/\s+/)[0];
  return Boolean(word) && word !== decision.action;
}

const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};

/**
 * Batch KPIs over rows of {expected:{action}, decision:{action, decidedBy, costUSD, latencyMs}}.
 * @returns {{correct:number, total:number, fastShare:number|null, costPerDecision:number|null, medianMs:number|null}}
 */
export function kpis(rows) {
  const total = rows.length;
  if (total === 0) return { correct: 0, total: 0, fastShare: null, costPerDecision: null, medianMs: null };
  const correct = rows.filter((r) => r.expected?.action === r.decision.action).length;
  const fast = rows.filter((r) => r.decision.decidedBy === 'fast').length;
  const cost = rows.reduce((sum, r) => sum + (Number(r.decision.costUSD) || 0), 0);
  return {
    correct,
    total,
    fastShare: fast / total,
    costPerDecision: cost / total,
    medianMs: median(rows.map((r) => Number(r.decision.latencyMs) || 0)),
  };
}

/* ---------- Formatting ---------- */

const FEATURED = ['endpoint_timeout', 'outage_critical_result', 'unknown_receiver', 'patient_mismatch'];
const HERO = 'outage_critical_result';
const BUILD = '__build';
const ACTIONS = ['resend', 'fix_and_resend', 'reroute', 'quarantine', 'escalate'];
const ACTION_LABEL = {
  resend: 'Resend', fix_and_resend: 'Fix & resend', reroute: 'Reroute', quarantine: 'Quarantine', escalate: 'Escalate',
};
const PILL = { resend: 'p-res', fix_and_resend: 'p-fix', reroute: 'p-rer', quarantine: 'p-q', escalate: 'p-esc' };
const STATUS_WORD = { ok: 'ok', warn: 'warning', bad: 'problem', hum: 'a person acted' };

const actionLabel = (a) => ACTION_LABEL[a] ?? String(a ?? '');
const secs = (ms) => (ms < 100 ? `${Math.round(ms)} ms` : `${(ms / 1000).toFixed(1)} s`);
const usd = (x) => `$${Number(x).toFixed(4)}`;
const pct = (x) => `${Math.round(x * 100)}%`;
/** "HH:MM:SS" from an audit timestamp ("YYYY-MM-DD HH:MM:SS.mmm") or a Date (UTC, like the API). */
const clock = (at) => (at instanceof Date ? at.toISOString().slice(11, 19) : String(at ?? '').slice(11, 19));

/* ---------- DOM helpers ---------- */

const $ = (id) => document.getElementById(id);

/** Build an element: h('div', {class: 'x', onclick: fn}, 'text', childNode, ...). Text is never parsed as HTML. */
function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === undefined || v === null || v === false) continue;
    if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'class') el.className = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const c of children.flat()) if (c !== null && c !== undefined && c !== false) el.append(c);
  return el;
}

/* Keyboard focus survives re-renders: rebuilt buttons carry a stable data-key. The focused key is
   remembered before a zone is rebuilt (or a button disabled) and focus goes back to the button
   with that key once it exists and is enabled again. */
let pendingFocus = null;

function rememberFocus(scope) {
  const a = document.activeElement;
  if (a && a !== document.body && scope.contains(a) && a.dataset.key) pendingFocus = a.dataset.key;
}

/** Focus the remembered button; if it is gone, focus the first enabled button in `scope` (or scope). */
function restoreFocus(scope) {
  if (!pendingFocus) return;
  const target = document.querySelector(`[data-key="${CSS.escape(pendingFocus)}"]`);
  if (target && !target.disabled) {
    if (document.activeElement !== target) target.focus();
    pendingFocus = null;
  } else if (!target && scope && scope !== document.body && !scope.contains(document.activeElement)) {
    const next = [...scope.querySelectorAll('button')].find((b) => !b.disabled);
    (next ?? scope).focus();
    pendingFocus = null;
  }
}

/** Replace an element's children, skipping null/undefined/false (replaceChildren would print "null"). */
function fill(el, ...children) {
  rememberFocus(el);
  el.replaceChildren(...children.flat().filter((c) => c !== null && c !== undefined && c !== false));
  restoreFocus(el);
}

const SVG = 'http://www.w3.org/2000/svg';

/* ---------- State ---------- */

const state = {
  src: null,
  scenarios: [],
  showAll: false,
  activeChip: null, // scenario id, or null during a batch
  current: null, // {caseObj, decision, badge, arrived: Date}
  outcomeView: 'default', // default | override | reroute
  outcomeError: '',
  acting: false,
  precedent: false,
  busy: false,
  started: 0,
  ticker: null,
  models: null,
  batchRows: [],
  openStep: null,
  builderOpen: false,
};

/* ---------- Mode label ---------- */

function modeLabel() {
  if (state.src.mode === 'live') return 'Live';
  const d = state.current?.decision;
  const label = replayLabel(state.models);
  if (d) return d.source === 'replay' ? label : 'Mock';
  return state.src.noRecordings ? 'Mock' : label;
}

/** "Replay (mock models)" when the bundle was recorded on the mocks, else "Replay of a real run". */
export function replayLabel(models) {
  const mock = (m) => String(m ?? '').toLowerCase() === 'mock';
  return models && mock(models.fast) && mock(models.agent) ? 'Replay (mock models)' : 'Replay of a real run';
}

/* ---------- Zone: chips + wires ---------- */

function renderChips() {
  const box = $('chips');
  const featured = FEATURED.map((id) => state.scenarios.find((s) => s.id === id)).filter(Boolean);
  const head = featured.length ? featured : state.scenarios.slice(0, 4);
  const rest = state.scenarios.filter((s) => !head.includes(s));
  const shown = state.showAll ? [...head, ...rest] : head;
  fill(box,
    ...shown.map((s) => h('button', {
      class: `chip${state.activeChip === s.id ? ' on' : ''}`,
      type: 'button',
      'data-id': s.id,
      'data-key': `chip-${s.id}`,
      'aria-pressed': String(state.activeChip === s.id),
      disabled: state.busy,
      onclick: () => runScenario(s),
    }, h('span', { class: 'dot', 'aria-hidden': 'true' }), s.label)),
    state.scenarios.length ? h('button', {
      class: `chip more build${state.activeChip === BUILD ? ' on' : ''}`, type: 'button', 'data-key': 'chip-build', disabled: state.busy,
      'aria-expanded': String(state.builderOpen),
      onclick: () => (state.builderOpen ? closeBuilder() : openBuilder()),
    }, '+ Build your own') : null,
    rest.length ? h('button', {
      class: 'chip more', type: 'button', 'data-key': 'chip-more', 'aria-expanded': String(state.showAll),
      onclick: () => { state.showAll = !state.showAll; renderChips(); },
    }, state.showAll ? 'Fewer' : `More (${rest.length})`) : null,
  );
  $('batch-btn').disabled = state.busy;
  requestAnimationFrame(drawWires);
}

/** Curves from each scenario chip to the device, the active one animated. */
function drawWires() {
  const svg = $('wire-in');
  if (getComputedStyle(svg).display === 'none') return;
  const box = svg.getBoundingClientRect();
  const scr = document.querySelector('.scr').getBoundingClientRect();
  const ty = Math.min(Math.max(scr.top + scr.height / 2 - box.top, 0), box.height);
  svg.setAttribute('viewBox', `0 0 44 ${Math.max(box.height, 1)}`);
  const paths = [...document.querySelectorAll('#chips .chip:not(.more)')].map((chip) => {
    const r = chip.getBoundingClientRect();
    const y = r.top + r.height / 2 - box.top;
    const p = document.createElementNS(SVG, 'path');
    p.setAttribute('d', `M0 ${y} C 26 ${y},18 ${ty},44 ${ty}`);
    if (chip.dataset.id === state.activeChip) p.setAttribute('class', 'live');
    return p;
  });
  fill(svg, ...paths);
  $('wire-out').classList.toggle('on', Boolean(state.current));
}

/* ---------- Zone: device (screen, steps, drawer, knobs) ---------- */

function renderScreen() {
  const d = state.current?.decision;
  $('mode').textContent = modeLabel();
  const elapsed = state.busy && !d ? secs(Date.now() - state.started)
    : d ? secs(Number(d.latencyMs) || 0) : '';
  $('elapsed').textContent = elapsed ? ` · ${elapsed}` : '';
  const badge = $('badge');
  badge.hidden = !state.current?.badge;
  badge.textContent = state.current?.badge ? `Agent overruled ${d.trace[0].stage}` : '';

  const steps = $('steps');
  if (state.thinking) {
    fill(steps, h('div', { class: 'thinking', role: 'status' },
      h('span', { class: 'pulse', 'aria-hidden': 'true' }),
      'Agent thinking… ', h('b', {}, String(Math.floor((Date.now() - state.started) / 1000))), ' s'));
  } else if (state.triageError) {
    fill(steps, h('div', { class: 'step-error' }, `Triage failed: ${state.triageError}`));
  } else if (!d) {
    fill(steps, h('p', { class: 'idle' }, 'Pick a failed message to triage it.'));
  } else {
    fill(steps, ...stepRows(d.trace).map((r) => h('button', {
      class: `step${state.openStep === r.n ? ' open' : ''}`,
      type: 'button',
      'data-key': `step-${r.n}`,
      'aria-expanded': String(state.openStep === r.n),
      'aria-label': `Step ${r.n}, ${r.stage}: ${r.value} (${STATUS_WORD[r.status] ?? r.status}). Show details`,
      onclick: () => { state.openStep = state.openStep === r.n ? null : r.n; renderScreen(); },
    }, h('span', { class: `s ${r.status}`, 'aria-hidden': 'true' }, String(r.n)),
    h('span', { class: 'stage' }, r.stage),
    h('span', { class: 'v' }, r.value))));
  }

  const drawer = $('drawer');
  const open = d && state.openStep ? d.trace[state.openStep - 1] : null;
  drawer.hidden = !open;
  if (open) {
    fill(drawer, h('b', {}, `${open.stage}: `), open.detail || '(no detail)',
      open.ms > 0 ? h('span', { class: 'ms' }, ` · ${secs(open.ms)}`) : null);
  }
}

function renderKnobs() {
  const m = state.models;
  for (const tier of ['fast', 'agent']) {
    const knob = $(`knob-${tier}`);
    const list = m?.available?.[tier] ?? [];
    knob.querySelector('.name').textContent = m?.[tier] ?? '…';
    knob.disabled = state.busy || list.length < 2;
    knob.title = list.length < 2
      ? (state.src?.mode === 'live' ? `Only ${m?.[tier] ?? 'the mock'} is configured` : 'A replay cannot switch models')
      : `Switch the ${tier === 'fast' ? 'fast tier' : 'agent'} model (${list.join(', ')})`;
  }
  $('knob-note').textContent = state.src?.mode === 'live' ? ''
    : state.src?.noRecordings ? 'Mock models in your browser' : 'Models the run was recorded with';
}

async function cycleModel(tier) {
  const m = state.models;
  const list = m?.available?.[tier] ?? [];
  if (list.length < 2 || state.busy) return;
  const next = list[(list.indexOf(m[tier]) + 1) % list.length];
  const want = { fast: m.fast, agent: m.agent, [tier]: next };
  try {
    state.models = await state.src.setModels(want.fast, want.agent);
    $('knob-note').textContent = '';
  } catch (e) {
    $('knob-note').textContent = `Could not switch: ${e.message}`;
  }
  renderKnobs();
}

/* ---------- Zone: decision card ---------- */

function bar(value, cls) {
  const v = Math.max(0, Math.min(1, Number(value) || 0));
  return h('div', { class: 'bar' }, h('i', { class: cls, style: `width:${(v * 100).toFixed(0)}%` }));
}

function renderDecision() {
  const card = $('decision-card');
  const d = state.current?.decision;
  if (!d) {
    fill(card, h('h3', {}, 'Decision'), h('p', { class: 'muted' }, state.thinking ? 'Waiting for the agent…' : 'No message triaged yet.'));
    return;
  }
  const sev = Number(d.severity) || 0;
  fill(card,
    h('h3', {}, 'Decision'),
    h('div', { class: 'pill-row' },
      h('span', { class: `pill ${PILL[d.action] ?? ''}` }, actionLabel(d.action).toUpperCase()),
      d.action === 'reroute' && d.rerouteTarget ? h('span', { class: 'target' }, `→ ${d.rerouteTarget}`) : null),
    h('div', { class: 'row' }, h('span', {}, 'Severity'), h('span', {}, sev.toFixed(2))),
    bar(sev, sev > 0.6 ? 'sev-high' : sev > 0.35 ? 'sev-mid' : 'sev-low'),
    h('div', { class: 'row' }, h('span', {}, 'Confidence'), h('span', {}, (Number(d.confidence) || 0).toFixed(2))),
    bar(d.confidence, 'conf'),
    h('div', { class: 'row by' }, h('span', {}, 'Decided by'), h('span', {}, d.decidedBy === 'human' ? 'a person' : d.decidedBy === 'fast' ? 'the fast tier' : 'the agent')),
  );
}

/* ---------- Zone: outcome card (approve / override) ---------- */

const personActed = (d) => d.trace.some((s) => s.status === 'hum');

function renderOutcome() {
  const card = $('outcome-card');
  const d = state.current?.decision;
  const err = state.outcomeError ? h('p', { class: 'err', role: 'alert' }, state.outcomeError) : null;
  if (!d) {
    fill(card, h('h3', {}, 'Outcome'), h('p', { class: 'muted' }, 'Nothing to act on yet.'));
    return;
  }
  const fix = d.proposedFix || d.rationale || '';
  if (personActed(d)) {
    const last = [...d.trace].reverse().find((s) => s.status === 'hum');
    const effect = [...(d.audit ?? [])].reverse().find((a) => a.actor === 'Production');
    const correction = (d.audit ?? []).some((a) => a.actor === 'Eval');
    fill(card, h('h3', {}, 'Done'),
      h('p', { class: 'msg good' }, `✓ You ${last.value}${d.action === 'reroute' && d.rerouteTarget ? ` (${d.rerouteTarget})` : ''}`),
      effect ? h('p', { class: 'msg sub' }, `Production: ${effect.detail}`) : null,
      correction ? h('p', { class: 'msg sub' }, 'Recorded as a correction for the eval') : null, err);
    return;
  }
  if (d.autoApplied) {
    fill(card, h('h3', {}, 'Outcome'),
      h('p', { class: 'msg good' }, `✓ Applied automatically: ${actionLabel(d.action).toLowerCase()} (simulated)`),
      fix ? h('p', { class: 'msg sub' }, fix) : null, err);
    return;
  }
  const busy = state.acting;
  if (state.outcomeView === 'override') {
    fill(card, h('h3', {}, 'Override: what should happen?'),
      h('div', { class: 'ovr' }, ...ACTIONS.filter((a) => a !== d.action).map((a) => h('button', {
        type: 'button', disabled: busy, 'data-key': `ovr-${a}`,
        onclick: () => (a === 'reroute' ? setOutcomeView('reroute') : doOverride(a, '')),
      }, actionLabel(a)))),
      h('button', { type: 'button', class: 'link', disabled: busy, 'data-key': 'ovr-cancel', onclick: () => setOutcomeView('default') }, 'Cancel'), err);
    return;
  }
  if (state.outcomeView === 'reroute') {
    const targets = [...new Set(Object.values(state.current.caseObj?.context?.routing_table ?? {}))];
    fill(card, h('h3', {}, 'Reroute to which route?'),
      targets.length
        ? h('div', { class: 'ovr' }, ...targets.map((t) => h('button', { type: 'button', disabled: busy, 'data-key': `to-${t}`, onclick: () => doOverride('reroute', t) }, t)))
        : h('p', { class: 'msg sub' }, 'This message has no routing table, so there is nothing to reroute to.'),
      h('button', { type: 'button', class: 'link', disabled: busy, 'data-key': 'to-back', onclick: () => setOutcomeView('override') }, 'Back'), err);
    return;
  }
  fill(card, h('h3', {}, 'Awaiting a person'),
    h('p', { class: 'msg' }, h('b', { class: 'alert', 'aria-hidden': 'true' }, '● '), fix || 'The policy held this decision for a person.'),
    h('div', { class: 'act' },
      h('button', { type: 'button', class: 'pri', disabled: busy, 'data-key': 'act-approve', onclick: doApprove }, 'Approve'),
      h('button', { type: 'button', disabled: busy, 'data-key': 'act-override', onclick: () => setOutcomeView('override') }, 'Override')),
    err);
}

function setOutcomeView(view) {
  state.outcomeView = view;
  state.outcomeError = '';
  renderOutcome();
}

async function act(call) {
  const target = state.current;
  state.acting = true;
  state.outcomeError = '';
  renderOutcome();
  try {
    const res = await call(target.decision.id);
    if (state.current !== target) return; // the user moved on to another message
    target.decision = { ...res.decision, source: target.decision.source };
    state.precedent = res.precedent === 1;
    state.outcomeView = 'default';
    state.openStep = null;
  } catch (e) {
    if (state.current === target) state.outcomeError = e.message;
  } finally {
    state.acting = false;
    if (state.current === target) renderAll();
  }
}

const doApprove = () => act((id) => state.src.approve(id));
const doOverride = (action, target) => act((id) => state.src.override(id, action, target, ''));

/* ---------- Zone: audit trail ---------- */

function renderAudit() {
  const list = $('events');
  const cur = state.current;
  $('mem').hidden = !state.precedent;
  if (!cur) {
    fill(list, h('li', { class: 'ev empty' }, 'Every step and every action on the message is listed here.'));
    return;
  }
  const t = cur.decision.trace;
  const fromTrace = [t[0], t.find((s) => s.stage === 'Agent'), t.find((s) => s.stage === 'Policy')]
    .filter(Boolean).map((s) => ({ at: clock(cur.arrived), who: s.stage, what: s.value }));
  const rows = [...fromTrace, ...(cur.decision.audit ?? []).map((a) => ({
    at: clock(a.at), who: a.actor, what: a.detail ? `${a.event}: ${a.detail}` : a.event,
  }))];
  fill(list, ...rows.map((r) => h('li', { class: 'ev' },
    h('span', { class: 'tm' }, r.at), h('span', {}, h('span', { class: 'who' }, r.who), ` · ${r.what}`))));
}

/* ---------- Zone: KPI strip and batch list ---------- */

function renderKpis() {
  const k = kpis(state.batchRows);
  const none = k.total === 0;
  const tile = (n, l) => h('div', { class: 'kpi' }, h('div', { class: 'n' }, n), h('div', { class: 'l' }, l));
  fill($('kpis'),
    tile(none ? '—' : pct(k.correct / k.total), none ? 'Correct · run a batch' : `Correct (${k.correct} of ${k.total} batch cases)`),
    tile(none ? '—' : pct(k.fastShare), 'Decided by the fast tier'),
    tile(none ? '—' : usd(k.costPerDecision), 'Cost per decision'),
    tile(none ? '—' : secs(k.medianMs), 'Median time per decision'),
  );
}

function appendBatchRow(row) {
  state.batchRows.push(row);
  const { expected, decision: d, caseObj } = row;
  const ok = expected?.action === d.action;
  $('batch').hidden = false;
  $('batch-rows').append(h('tr', {},
    h('td', { class: 'case' }, caseObj.case_id ?? d.caseId ?? ''),
    h('td', {}, actionLabel(expected?.action)),
    h('td', {}, actionLabel(d.action)),
    h('td', { class: ok ? 'yes' : 'no' }, ok ? '✓' : '✗', h('span', { class: 'sr' }, ok ? ' correct' : ' wrong')),
    h('td', { class: 'num' }, secs(Number(d.latencyMs) || 0)),
    h('td', { class: 'num' }, usd(d.costUSD || 0))));
  renderKpis();
}

/* ---------- Runs ---------- */

function renderAll() {
  renderChips();
  renderScreen();
  renderKnobs();
  renderDecision();
  renderOutcome();
  renderAudit();
}

function setBusy(busy) {
  // Disabling the focused chip, knob or batch button drops its focus: keep its key pending until
  // the button is enabled again. Set after the renders, which may already have cleared it.
  const a = document.activeElement;
  const key = a && a !== document.body ? a.dataset.key : undefined;
  state.busy = busy;
  renderChips();
  renderKnobs();
  if (key) pendingFocus = key;
  restoreFocus(document.body);
}

/** Triage one case, showing the thinking row until the answer arrives. Returns the decision or null. */
async function triage(caseObj) {
  state.current = null;
  state.thinking = true;
  state.triageError = '';
  state.precedent = false;
  state.outcomeView = 'default';
  state.outcomeError = '';
  state.openStep = null;
  state.started = Date.now();
  renderAll();
  clearInterval(state.ticker);
  state.ticker = setInterval(renderScreen, 250);
  try {
    const decision = await state.src.triage(caseObj);
    state.current = { caseObj, decision, badge: overruled(decision), arrived: new Date() };
    return decision;
  } catch (e) {
    state.triageError = e.message;
    return null;
  } finally {
    clearInterval(state.ticker);
    state.thinking = false;
    renderAll();
  }
}

async function runScenario(s) {
  if (state.busy) return;
  if (state.builderOpen) closeBuilder(false);
  state.activeChip = s.id;
  setBusy(true);
  try {
    await triage(s.case);
  } finally {
    setBusy(false);
  }
}

async function runBatch() {
  if (state.busy) return;
  if (state.builderOpen) closeBuilder(false);
  state.activeChip = null;
  setBusy(true);
  $('batch-note').textContent = '';
  try {
    const cases = await state.src.randomCases(5);
    if (!cases.length) {
      $('batch-note').textContent = state.src.noRecordings
        ? 'Batches need a recording; pick a message above instead.' : 'No batch cases in this recording.';
      return;
    }
    for (const [i, { case: caseObj, expected }] of cases.entries()) {
      $('batch-note').textContent = `Case ${i + 1} of ${cases.length}…`;
      const decision = await triage(caseObj);
      if (decision) appendBatchRow({ caseObj, expected, decision });
    }
    $('batch-note').textContent = '';
  } catch (e) {
    $('batch-note').textContent = `Batch failed: ${e.message}`;
  } finally {
    setBusy(false);
  }
}

/* ---------- Build your own ---------- */

const field = (label, control, key) => h('label', { class: 'bf', for: key }, h('span', {}, label), control);

/** The starting scenario for the panel: the one on screen, else the timeout, else the first. */
function builderBase() {
  const id = state.activeChip && state.activeChip !== BUILD ? state.activeChip : 'endpoint_timeout';
  return state.scenarios.find((s) => s.id === id) ?? state.scenarios[0];
}

/** Fill the form's fields from a scenario's case (the dropdown picks one). */
function loadBase(id) {
  const c = (state.scenarios.find((s) => s.id === id) ?? state.scenarios[0]).case;
  const ep = c.context?.endpoint ?? {};
  $('b-fmt').textContent = c.format === 'fhir' ? 'FHIR (JSON)' : 'HL7 v2';
  $('b-msg').value = messageToText(c.raw_message, c.format);
  $('b-err').value = c.error_text ?? '';
  $('b-down').checked = ep.up === false;
  $('b-min').value = String(Number(ep.down_minutes) || 0);
}

function openBuilder() {
  if (state.busy || !state.scenarios.length) return;
  const base = builderBase();
  const form = $('builder');
  state.builderOpen = true;
  form.replaceChildren(
    h('h3', {}, 'Build your own failed message'),
    field('Start from', h('select', { id: 'b-base', 'data-key': 'b-base', onchange: (e) => loadBase(e.target.value) },
      ...state.scenarios.map((s) => h('option', { value: s.id, selected: s.id === base.id }, s.label))), 'b-base'),
    h('p', { class: 'bf-fmt' }, 'Format: ', h('b', { id: 'b-fmt' })),
    field('Message (one HL7 segment per line)', h('textarea', { id: 'b-msg', 'data-key': 'b-msg', rows: '7', spellcheck: 'false' }), 'b-msg'),
    field('Error text', h('input', { id: 'b-err', 'data-key': 'b-err', type: 'text' }), 'b-err'),
    h('div', { class: 'bf-ep' },
      h('label', { class: 'bf-check', for: 'b-down' }, h('input', { id: 'b-down', 'data-key': 'b-down', type: 'checkbox' }), 'Endpoint is down'),
      h('label', { class: 'bf-min', for: 'b-min' }, 'for ', h('input', { id: 'b-min', 'data-key': 'b-min', type: 'number', min: '0', step: '1' }), ' minutes')),
    h('p', { class: 'err', id: 'b-errors', role: 'alert' }),
    h('div', { class: 'act' },
      h('button', { type: 'submit', class: 'pri', 'data-key': 'b-run' }, 'Run'),
      h('button', { type: 'button', 'data-key': 'b-cancel', onclick: closeBuilder }, 'Cancel')));
  loadBase(base.id);
  form.hidden = false;
  document.querySelector('.scr').hidden = true;
  renderChips();
  $('b-base').focus();
}

function closeBuilder(refocus = true) {
  state.builderOpen = false;
  $('builder').hidden = true;
  document.querySelector('.scr').hidden = false;
  renderChips();
  if (refocus) $('chips').querySelector('[data-key="chip-build"]')?.focus();
  requestAnimationFrame(drawWires);
}

async function runBuilt(ev) {
  ev.preventDefault();
  if (state.busy) return;
  const base = state.scenarios.find((s) => s.id === $('b-base').value) ?? state.scenarios[0];
  const c = buildCase(base.case, {
    format: base.case.format,
    message: $('b-msg').value,
    errorText: $('b-err').value,
    up: !$('b-down').checked,
    downMinutes: $('b-min').value,
  });
  const problems = validateCase(c);
  $('b-errors').textContent = problems.join(' ');
  if (problems.length) return; // nothing is sent
  const typed = { base: base.id, msg: $('b-msg').value, err: $('b-err').value, down: $('b-down').checked, min: $('b-min').value };
  closeBuilder(); // focus moves to the build chip and stays there across the busy re-render
  state.activeChip = BUILD;
  setBusy(true);
  let refused = '';
  try {
    if (!(await triage(c))) refused = state.triageError || 'The triage failed.';
  } finally {
    setBusy(false);
  }
  if (refused) {
    // The API refused it (a 400 for instance): put the form back with the API's text so it can be fixed.
    state.triageError = '';
    state.activeChip = null;
    renderAll();
    openBuilder();
    $('b-base').value = typed.base;
    loadBase(typed.base);
    $('b-msg').value = typed.msg;
    $('b-err').value = typed.err;
    $('b-down').checked = typed.down;
    $('b-min').value = typed.min;
    $('b-errors').textContent = refused;
  }
}

/* ---------- Boot ---------- */

function describeSource(src) {
  if (src.mode === 'live') return `Live: connected to the IRIS production${src.build ? ` (build ${src.build})` : ''}.`;
  if (src.noRecordings) return '';
  const day = String(src.recordedAt ?? '').slice(0, 10);
  const m = state.models;
  return `Replay of a run recorded${day ? ` on ${day}` : ''}${src.build ? ` on IRIS ${src.build}` : ''}`
    + `${m ? ` (fast tier ${m.fast}, agent ${m.agent})` : ''}. Messages not in the recording are decided by mock models in your browser.`;
}

async function boot() {
  const src = await detectSource();
  state.src = src;
  try {
    state.scenarios = await src.scenarios();
  } catch (e) {
    state.scenarios = [];
    $('notice').textContent = `Could not load the scenarios: ${e.message}`;
    $('notice').hidden = false;
  }
  if (src.mode === 'replay' && state.scenarios.length === 0) {
    src.noRecordings = true;
    state.scenarios = SAMPLE_SCENARIOS.map((s) => ({ ...s, case: structuredClone(s.case) }));
    $('notice').textContent = 'No recordings available — showing mock decisions.';
    $('notice').hidden = false;
  }
  try { state.models = await src.models(); } catch { state.models = null; }
  $('about').textContent = describeSource(src);
  $('batch-btn').addEventListener('click', runBatch);
  $('builder').addEventListener('submit', runBuilt);
  $('builder').addEventListener('keydown', (e) => { if (e.key === 'Escape') closeBuilder(); });
  $('knob-fast').addEventListener('click', () => cycleModel('fast'));
  $('knob-agent').addEventListener('click', () => cycleModel('agent'));
  window.addEventListener('resize', () => requestAnimationFrame(drawWires));
  // A pending focus restore is dropped as soon as the person moves focus or clicks elsewhere.
  document.addEventListener('pointerdown', () => { pendingFocus = null; });
  document.addEventListener('focusin', (e) => { if (e.target.dataset?.key !== pendingFocus) pendingFocus = null; });
  renderAll();
  renderKpis();
  const hero = state.scenarios.find((s) => s.id === HERO);
  if (src.mode === 'replay' && hero) runScenario(hero); // free in a replay; live waits for a click
}

if (typeof document !== 'undefined') boot();
