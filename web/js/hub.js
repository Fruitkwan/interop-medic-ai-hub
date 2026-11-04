// The judge page: pick a failed message, watch the fast tier, the agent's tools and the policy decide,
// then approve or override as the person on duty. Data comes from source.js (live IRIS API, or a
// recorded replay plus the browser mock models). The exported helpers are pure and unit-tested.
import { detectSource } from './source.js';
import { SAMPLE_SCENARIOS } from './samples.js';
import { buildCase, validateCase, messageToText, parseLoadedFile, MAX_FILE_BYTES } from './builder.js';

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
 * KPIs over rows of {expected?:{action}, decision:{action, decidedBy, costUSD, latencyMs}}.
 * Only rows with an expected action are scored; a built message has none.
 * @returns {{correct:number, total:number, fastShare:number|null, costPerDecision:number|null, medianMs:number|null}}
 */
export function kpis(rows) {
  const total = rows.length;
  if (total === 0) return { correct: 0, scored: 0, total: 0, fastShare: null, costPerDecision: null, medianMs: null };
  const labelled = rows.filter((r) => r.expected?.action);
  const correct = labelled.filter((r) => r.expected.action === r.decision.action).length;
  const fast = rows.filter((r) => r.decision.decidedBy === 'fast').length;
  const cost = rows.reduce((sum, r) => sum + (Number(r.decision.costUSD) || 0), 0);
  return {
    correct,
    scored: labelled.length,
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
const secs = (ms) => (ms < 100 ? `${Math.round(ms)} ms`
  : ms < 60000 ? `${(ms / 1000).toFixed(1)} s` : `${Math.floor(ms / 60000)} min ${Math.round((ms % 60000) / 1000)} s`);
/** Dollars; a fraction of a cent keeps two significant digits instead of rounding to $0.0000. */
const usd = (x) => { const n = Number(x); return n > 0 && n < 0.01 ? `$${n.toPrecision(2)}` : `$${n.toFixed(4)}`; };
const pct = (x) => `${Math.round(x * 100)}%`;
/** "HH:MM:SS" from an audit timestamp ("YYYY-MM-DD HH:MM:SS.mmm") or a Date (UTC, like the API). */
const clock = (at) => (at instanceof Date ? at.toISOString().slice(11, 19) : String(at ?? '').slice(11, 19));

/* ---------- DOM helpers ---------- */

const $ = (id) => document.getElementById(id);

function selectView(name, focus = false) {
  const inside = name === 'inside';
  $('panel-demo').hidden = inside;
  $('panel-inside').hidden = !inside;
  for (const [tab, selected] of [[$('tab-demo'), !inside], [$('tab-inside'), inside]]) {
    tab.classList.toggle('on', selected);
    tab.setAttribute('aria-selected', String(selected));
    tab.tabIndex = selected ? 0 : -1;
  }
  if (inside) renderEvidence();
  if (!inside) requestAnimationFrame(drawWires);
  window.scrollTo(0, 0);
  if (focus) (inside ? $('tab-inside') : $('tab-demo')).focus();
}

function setupViews() {
  $('tab-demo').addEventListener('click', () => selectView('demo'));
  $('tab-inside').addEventListener('click', () => selectView('inside'));
  $('evidence-batch').addEventListener('click', runBatch);
  $('evidence-build').addEventListener('click', () => { selectView('demo'); openBuilder(); });
  $('evidence-fast').addEventListener('click', (e) => toggleModelMenu('fast', e.currentTarget));
  $('evidence-agent').addEventListener('click', (e) => toggleModelMenu('agent', e.currentTarget));
  $('evidence-rerun').addEventListener('click', () => {
    const scenario = state.scenarios.find((s) => s.id === state.activeChip);
    if (scenario) runScenario(scenario);
  });
  for (const tab of [$('tab-demo'), $('tab-inside')]) {
    tab.addEventListener('keydown', (event) => {
      if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
      event.preventDefault();
      selectView(tab === $('tab-demo') ? 'inside' : 'demo', true);
    });
  }
}

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
  runRows: [], // every decision made in this tab
  baseline: null, // the recorded run, shown until runRows has something
  openStep: null,
  builderOpen: false,
  builderFormat: 'hl7v2', // the format the built case is sent as: the base's, or a loaded file's
  loaded: null, // {name, format, messages: [{label, text}]} from Load file, held only in this page
};

const caseLabel = (s) => s?.case?.message_type || (s?.case?.format === 'fhir' ? 'FHIR resource' : 'HL7 message');
const errorLabel = (s) => s?.label || 'Failed message';
const queueTime = (i) => {
  const d = new Date(2026, 9, 17, 10, 21 - i * 3);
  return d.toLocaleTimeString('en', { hour: 'numeric', minute: '2-digit' });
};

function renderEvidence() {
  if (!$('evidence-list')) return;
  const scenarios = state.scenarios;
  const selected = scenarios.find((s) => s.id === state.activeChip);
  $('evidence-count').textContent = `(${scenarios.length})`;
  fill($('evidence-list'), ...scenarios.slice(0, 9).map((s, i) => h('button', {
    type: 'button', class: `queue-row${s === selected ? ' on' : ''}`, disabled: state.busy,
    'aria-pressed': String(s === selected), onclick: () => runScenario(s),
  }, h('span', { class: `queue-dot q${i % 3}` }),
  h('span', { class: 'queue-copy' }, h('b', {}, caseLabel(s)), h('small', {}, s.case?.format === 'fhir' ? 'FHIR R4' : 'HL7 v2')),
  h('span', { class: 'queue-side' }, h('time', {}, queueTime(i)), h('em', {}, errorLabel(s))))));

  const { k, note } = scoreboard();
  const metric = (value, label, width) => h('div', { class: 'e-kpi' }, h('b', {}, value), h('span', {}, label), h('div', { class: 'e-meter' }, h('i', { style: `width:${width}%` })));
  fill($('evidence-kpis'),
    metric(k.scored ? `${k.correct} / ${k.scored}` : '—', `Correct (${note})`, k.scored ? (k.correct / k.scored) * 100 : 0),
    metric(k.total ? pct(k.fastShare) : '—', 'Decided by fast tier', k.total ? k.fastShare * 100 : 0),
    metric(k.total ? usd(k.costPerDecision) : '—', 'Cost per decision', k.total ? 54 : 0),
    metric(k.total ? secs(k.medianMs) : '—', 'Median time per decision', k.total ? 72 : 0));

  const d = state.current?.decision;
  const c = state.current?.caseObj;
  $('evidence-title').textContent = c ? caseLabel({ case: c }) : 'Select a failed message';
  $('evidence-meta').textContent = c ? `${c.format === 'fhir' ? 'FHIR R4' : 'HL7 v2'}  |  Message ID: ${c.case_id || 'synthetic case'}` : 'Choose a case from the queue to see every decision step.';
  $('evidence-issue').hidden = !selected;
  $('evidence-issue').textContent = selected ? errorLabel(selected) : '';

  const trace = d?.trace ?? [];
  const fast = trace[0];
  const agent = trace.find((s) => s.stage === 'Agent');
  const policy = trace.find((s) => s.stage === 'Policy');
  const agentUnavailable = agent?.value === 'unavailable';
  const fastConfidence = Number(String(fast?.value ?? '').match(/\d+(?:\.\d+)?/)?.[0]) || 0;
  const stages = $('panel-inside').querySelectorAll('.stage-line li');
  const progress = [Boolean(selected), Boolean(fast), Boolean(d), Boolean(policy)];
  stages.forEach((stage, i) => {
    stage.classList.toggle('done', progress[i]);
    stage.classList.toggle('current', progress[i] && !progress[i + 1]);
  });
  $('fast-result').textContent = fast?.value || (state.thinking ? 'Analyzing…' : 'Waiting for a message');
  $('fast-reason').textContent = fast?.detail || (state.thinking ? 'The fast tier is reading the failure.' : 'Select a failed message to begin.');
  $('fast-time').textContent = fast ? secs(fast.ms || 0) : '—';
  $('fast-confidence').textContent = fast ? fastConfidence.toFixed(2) : '—';
  $('fast-meter').style.width = fast ? `${Math.round(fastConfidence * 100)}%` : '0';
  $('agent-result').textContent = agentUnavailable ? 'Unavailable — safely escalated' : agent?.value || (d?.decidedBy === 'fast' ? 'Fast decision accepted' : state.thinking ? 'Gathering evidence…' : 'Waiting for evidence');
  $('agent-conclusion').textContent = agentUnavailable ? 'The configured provider is temporarily unavailable. The fail-safe sent this case for human review.' : agent?.detail || d?.rationale || 'The agent’s tool-grounded conclusion appears here.';
  $('agent-time').textContent = agent ? secs(agent.ms || 0) : '—';
  const checks = trace.filter((s) => ![fast, agent, policy].includes(s) && s.stage !== 'Gate');
  fill($('agent-checks'), ...(checks.length ? checks : trace.filter((s) => s.stage === 'Gate')).map((s) => h('li', {}, `${s.stage}: ${s.value}`)),
    !trace.length ? h('li', {}, 'Select a message to inspect the agent trace.') : null);
  $('policy-result').textContent = policy?.value || 'No decision yet.';
  $('policy-detail').textContent = policy?.detail || 'The deterministic policy runs after model verification.';
  $('policy-badge').hidden = !d;
  $('policy-badge').textContent = d ? (d.autoApplied ? 'Auto-applied safely' : 'Human review required') : '';
  $('canvas-outcome').textContent = d ? (d.autoApplied ? `${actionLabel(d.action)} applied.` : `${actionLabel(d.action)} proposed.`) : 'Nothing to act on yet.';
  $('canvas-outcome-detail').textContent = d?.proposedFix || 'No downstream system has received a message.';
  fill($('evidence-events'), ...(trace.length ? trace : [{ stage: 'Ready', value: 'Select a failed message', detail: 'Every model, tool, policy, and human action will appear here.' }]).map((s) => {
    const detail = s.stage === 'Agent' && s.value === 'unavailable'
      ? 'Provider unavailable; fail-safe escalation recorded.' : s.detail || s.value;
    return h('li', {}, h('span', { class: 'audit-dot' }), h('time', {}, state.current ? clock(state.current.arrived) : '—'),
      h('div', {}, h('b', {}, s.stage), h('p', {}, detail)));
  }));
}

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
  // Aim at whichever panel is showing: the builder hides the screen, whose box is then empty.
  const scr = (state.builderOpen ? $('builder') : document.querySelector('.scr')).getBoundingClientRect();
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
    const glyphs = [
      'MSH.9  ADT^A01   MSG 7A3C-2E6D',
      'PID.3  HASH 91F0   ROUTE EHR-PROD',
      'ACK.1  WAIT 30S   RETRY 02/03',
      'IRIS.LOG  TRACE 6B8C  STATUS 200',
      'POLICY  TRIAGE-V3.1  SCORE 0.92',
    ];
    fill(steps, h('div', { class: 'thinking-shell', role: 'status', 'aria-label': 'Agent is processing the message' },
      h('div', { class: 'thinking' }, h('span', { class: 'pulse', 'aria-hidden': 'true' }),
        h('span', {}, 'Tracing the message'), h('b', { id: 'thinking-seconds' }, String(Math.floor((Date.now() - state.started) / 1000))), ' s'),
      h('div', { class: 'glyph-draw', 'aria-hidden': 'true' },
        ...glyphs.map((line, i) => h('span', { class: `glyph-line glyph-line-${i + 1}` }, line))),
      h('p', { class: 'thinking-note' }, 'Reading segments · checking IRIS · applying policy')));
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

function updateThinkingClock() {
  const d = state.current?.decision;
  const elapsed = state.busy && !d ? secs(Date.now() - state.started)
    : d ? secs(Number(d.latencyMs) || 0) : '';
  $('elapsed').textContent = elapsed ? ` · ${elapsed}` : '';
  const seconds = $('thinking-seconds');
  if (seconds) seconds.textContent = String(Math.floor((Date.now() - state.started) / 1000));
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
    // The Evidence Canvas has its own pair of buttons for the same menus.
    const twin = $(`evidence-${tier}`);
    twin.querySelector('.name').textContent = m?.[tier] ?? '…';
    twin.disabled = knob.disabled;
    twin.title = knob.title;
  }
  $('keys-open').hidden = !state.src?.setKeys;
  $('knob-note').textContent = state.src?.mode === 'live' ? ''
    : state.src?.noRecordings ? 'Mock models in your browser' : 'Models the run was recorded with';
}

/** Open (or close) the model menu under a knob, or under its twin on the Evidence Canvas. */
function toggleModelMenu(tier, anchor = $(`knob-${tier}`)) {
  const was = $('model-menu')?.dataset.anchor;
  closeModelMenu();
  if (was === anchor.id) return;
  const m = state.models;
  const list = m?.available?.[tier] ?? [];
  if (list.length < 2 || state.busy) return;
  const knob = anchor;
  const items = list.map((name) => h('button', {
    type: 'button', role: 'menuitemradio', class: `opt${name === m[tier] ? ' on' : ''}`,
    'aria-checked': String(name === m[tier]),
    onclick: () => { closeModelMenu(); if (name !== m[tier]) setModel(tier, name); },
  }, name));
  // Configured models without a key: listed, greyed out. A judge can bring their own key for
  // most of them (API keys button); the rest need a variable on the server.
  for (const { label, need, provider, keyable } of m?.unavailable?.[tier] ?? []) {
    const hint = keyable && state.src?.setKeys ? `Add your ${provider} key under API keys` : `Needs ${need} on the server`;
    items.push(h('button', { type: 'button', role: 'menuitemradio', class: 'opt', disabled: '',
      'aria-disabled': 'true', title: hint }, label, h('small', {}, 'no key')));
  }
  const menu = h('div', { class: 'model-menu', id: 'model-menu', role: 'menu', 'data-tier': tier, 'data-anchor': anchor.id,
    'aria-label': tier === 'fast' ? 'Fast tier model' : 'Agent model' }, ...items);
  knob.parentElement.append(menu);
  menu.style.left = `${knob.offsetLeft}px`;
  menu.style.top = `${knob.offsetTop + knob.offsetHeight + 6}px`;
  menu.style.minWidth = `${knob.offsetWidth}px`;
  knob.setAttribute('aria-expanded', 'true');
  (menu.querySelector('.on') ?? items[0]).focus();
}

function closeModelMenu() {
  $('model-menu')?.remove();
  for (const tier of ['fast', 'agent']) {
    for (const id of [`knob-${tier}`, `evidence-${tier}`]) $(id)?.setAttribute('aria-expanded', 'false');
  }
}

async function setModel(tier, name) {
  const m = state.models;
  if (state.busy) return;
  const want = { fast: m.fast, agent: m.agent, [tier]: name };
  try {
    state.models = await state.src.setModels(want.fast, want.agent);
    $('knob-note').textContent = '';
  } catch (e) {
    $('knob-note').textContent = `Could not switch: ${e.message}`;
  }
  renderKnobs();
}

/* ---------- API keys (this browser tab only) ---------- */

/** Open the API keys dialog: one password field per provider a judge can bring a key for. */
function openKeys() {
  const src = state.src;
  if (!src?.setKeys) return;
  const dialog = $('keys-dialog');
  const keys = src.keys();
  const providers = Object.entries(src.keyProviders()).sort(([a], [b]) => a.localeCompare(b));
  const rows = providers.map(([provider, labels]) => h('label', { class: 'key-row' },
    h('span', { class: 'key-name' }, h('b', {}, provider), h('small', {}, labels.join(', '))),
    h('input', { type: 'password', name: provider, value: keys[provider] ?? '', autocomplete: 'off',
      spellcheck: 'false', placeholder: src.serverHasKey(provider) ? 'server key in use (optional)' : 'paste your key' })));
  const save = (next) => {
    state.models = src.setKeys(next);
    dialog.close();
    renderKnobs();
  };
  const form = h('form', { method: 'dialog', class: 'keys-form', onsubmit: (e) => {
    e.preventDefault();
    save(Object.fromEntries(new FormData(e.currentTarget)));
  } },
  h('h3', {}, 'Your API keys'),
  h('p', { class: 'muted' }, 'Kept in this browser tab only and sent with each triage for the models you pick. '
    + 'The server uses a key for that one message and never stores it. Closing the tab forgets them.'),
  providers.length ? rows : h('p', {}, 'No hosted models are configured on this server.'),
  h('div', { class: 'keys-actions' },
    h('button', { type: 'button', class: 'ghost', onclick: () => save({}) }, 'Forget all'),
    h('button', { type: 'button', class: 'ghost', onclick: () => dialog.close() }, 'Cancel'),
    h('button', { type: 'submit', class: 'primary' }, 'Save')));
  fill(dialog, form);
  dialog.showModal();
  dialog.querySelector('input')?.focus();
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

/** The numbers to show: this tab's own runs, else the recorded run, and which of the two it is. */
function scoreboard() {
  const own = state.runRows.length > 0;
  const b = state.baseline;
  const k = kpis(own ? state.runRows : b?.rows ?? []);
  return { k, note: own ? 'this session' : b ? `recorded run, ${b.models.fast} + ${b.models.agent}` : 'run a message' };
}

function renderKpis() {
  const { k, note } = scoreboard();
  const none = k.total === 0;
  const tile = (n, l) => h('div', { class: 'kpi' }, h('div', { class: 'n' }, n), h('div', { class: 'l' }, l));
  fill($('kpis'),
    tile(k.scored ? pct(k.correct / k.scored) : '—', k.scored ? `Correct (${k.correct} of ${k.scored}, ${note})` : `Correct · ${note}`),
    tile(none ? '—' : pct(k.fastShare), 'Decided by the fast tier'),
    tile(none ? '—' : usd(k.costPerDecision), 'Cost per decision'),
    tile(none ? '—' : secs(k.medianMs), 'Median time per decision'),
  );
  renderEvidence();
}

function appendBatchRow(row) {
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
}

/* ---------- Runs ---------- */

function renderAll() {
  renderChips();
  renderScreen();
  renderKnobs();
  renderDecision();
  renderOutcome();
  renderAudit();
  renderEvidence();
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
async function triage(caseObj, expected) {
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
  state.ticker = setInterval(updateThinkingClock, 250);
  try {
    const decision = await state.src.triage(caseObj);
    state.current = { caseObj, decision, badge: overruled(decision), arrived: new Date() };
    // A replayed decision is already in the recorded totals.
    if (decision.source !== 'replay') state.runRows.push({ caseObj, expected, decision });
    renderKpis();
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
  $('batch-note').textContent = '';
  setBusy(true);
  try {
    await triage(s.case, s.expected);
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
      const decision = await triage(caseObj, expected);
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

function setFormat(format) {
  state.builderFormat = format;
  $('b-fmt').textContent = format === 'fhir' ? 'FHIR (JSON)' : 'HL7 v2';
}

/** Fill the form's fields from a scenario's case (the dropdown picks one). A loaded file keeps its message. */
function loadBase(id) {
  const c = (state.scenarios.find((s) => s.id === id) ?? state.scenarios[0]).case;
  const ep = c.context?.endpoint ?? {};
  if (!state.loaded) {
    setFormat(c.format);
    $('b-msg').value = messageToText(c.raw_message, c.format);
  }
  $('b-err').value = c.error_text ?? '';
  $('b-down').checked = ep.up === false;
  $('b-min').value = String(Number(ep.down_minutes) || 0);
}

function openBuilder() {
  if (state.busy || !state.scenarios.length) return;
  const base = builderBase();
  const form = $('builder');
  state.builderOpen = true;
  state.loaded = null;
  form.replaceChildren(
    h('h3', {}, 'Build your own failed message'),
    field('Start from', h('select', { id: 'b-base', 'data-key': 'b-base', onchange: (e) => loadBase(e.target.value) },
      ...state.scenarios.map((s) => h('option', { value: s.id, selected: s.id === base.id }, s.label))), 'b-base'),
    field('Or load a file (.hl7, .txt, .json): read in your browser, sent only when you run it',
      h('input', { id: 'b-file', 'data-key': 'b-file', type: 'file', accept: '.hl7,.hl7v2,.txt,.json,.fhir,text/plain,application/json', onchange: loadFile }), 'b-file'),
    h('p', { class: 'bf-note', id: 'b-file-note', 'aria-live': 'polite' }),
    h('div', { class: 'bf-pick', id: 'b-pick-row', hidden: true },
      field('Message in the file', h('select', { id: 'b-pick', 'data-key': 'b-pick', onchange: (e) => pickLoaded(Number(e.target.value)) }), 'b-pick')),
    h('p', { class: 'bf-fmt' }, 'Format: ', h('b', { id: 'b-fmt' })),
    field('Message (one HL7 segment per line)', h('textarea', { id: 'b-msg', 'data-key': 'b-msg', rows: '7', spellcheck: 'false' }), 'b-msg'),
    field('Error text', h('input', { id: 'b-err', 'data-key': 'b-err', type: 'text' }), 'b-err'),
    h('div', { class: 'bf-ep' },
      h('label', { class: 'bf-check', for: 'b-down' }, h('input', { id: 'b-down', 'data-key': 'b-down', type: 'checkbox' }), 'Endpoint is down'),
      h('label', { class: 'bf-min', for: 'b-min' }, 'for ', h('input', { id: 'b-min', 'data-key': 'b-min', type: 'number', min: '0', step: '1' }), ' minutes')),
    h('p', { class: 'err', id: 'b-errors', role: 'alert' }),
    h('div', { class: 'act' },
      h('button', { type: 'submit', class: 'pri', 'data-key': 'b-run' }, 'Run'),
      h('button', { type: 'button', id: 'b-run-all', 'data-key': 'b-run-all', hidden: true, onclick: runLoaded }, 'Run all'),
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

/** Read a file in the browser (nothing is uploaded) and put its message, or its first one, in the form. */
async function loadFile(ev) {
  const input = ev.target;
  const file = input.files?.[0];
  const note = (text) => { $('b-file-note').textContent = text; };
  $('b-errors').textContent = '';
  state.loaded = null;
  showLoaded();
  if (!file) return note('');
  if (file.size > MAX_FILE_BYTES) {
    input.value = '';
    return note(`${file.name} is over ${MAX_FILE_BYTES / 1024 / 1024} MB: load a smaller file.`);
  }
  let text;
  try {
    text = await new Promise((resolve, reject) => {
      const r = new FileReader();
      r.onload = () => resolve(String(r.result));
      r.onerror = () => reject(r.error);
      r.readAsText(file);
    });
  } catch {
    return note(`Could not read ${file.name}.`);
  }
  if ($('b-file') !== input) return; // the panel was closed or rebuilt while reading
  const parsed = parseLoadedFile(text);
  if (parsed.error) {
    input.value = '';
    return note(`${file.name}: ${parsed.error}`);
  }
  state.loaded = { name: file.name, format: parsed.format, messages: parsed.messages };
  setFormat(parsed.format);
  showLoaded();
  pickLoaded(0);
  const n = parsed.messages.length;
  note(n > 1 ? `${file.name}: ${n} messages. Pick one to run, or run them all one after another.` : `Loaded ${file.name}.`);
}

/** Show the message picker and Run all only when the loaded file holds several messages. */
function showLoaded() {
  const msgs = state.loaded?.messages ?? [];
  $('b-pick-row').hidden = msgs.length < 2;
  $('b-run-all').hidden = msgs.length < 2;
  $('b-run-all').textContent = `Run all ${msgs.length}`;
  $('b-pick').replaceChildren(...msgs.map((m, i) => h('option', { value: String(i) }, m.label)));
}

function pickLoaded(i) {
  $('b-pick').value = String(i);
  $('b-msg').value = state.loaded.messages[i].text;
}

/** A case from the panel's edits, with the message given (the textarea's by default). */
function builtFrom(message = $('b-msg').value) {
  const base = state.scenarios.find((s) => s.id === $('b-base').value) ?? state.scenarios[0];
  const c = buildCase(base.case, {
    format: state.builderFormat,
    message,
    errorText: $('b-err').value,
    up: !$('b-down').checked,
    downMinutes: $('b-min').value,
  });
  return { base, c };
}

/** Triage every message of the loaded file, one after another, with the panel's error text and endpoint. */
async function runLoaded() {
  if (state.busy || !state.loaded) return;
  const { name, messages } = state.loaded;
  const cases = messages.map((m, i) => {
    const { c } = builtFrom(m.text);
    c.case_id = `${c.case_id}-${i + 1}`; // built in the same millisecond: keep the ids apart
    return c;
  });
  const problems = cases.flatMap((c, i) => validateCase(c).map((p) => `Message ${i + 1}: ${p}`));
  $('b-errors').textContent = problems.join(' ');
  if (problems.length) return; // nothing is sent
  closeBuilder();
  state.activeChip = BUILD;
  setBusy(true);
  const counts = new Map();
  let failed = 0;
  let lastError = '';
  try {
    for (const [i, c] of cases.entries()) {
      $('batch-note').textContent = `${name}: message ${i + 1} of ${cases.length}…`;
      const decision = await triage(c);
      if (decision) counts.set(decision.action, (counts.get(decision.action) ?? 0) + 1);
      else { failed += 1; lastError = state.triageError; }
    }
    const done = [...counts].map(([a, n]) => `${n} ${actionLabel(a)}`).join(', ');
    $('batch-note').textContent = `${name}: ${cases.length - failed} of ${cases.length} triaged${done ? ` (${done})` : ''}.`
      + `${failed ? ` ${failed} failed: ${lastError}` : ''} The last one is on screen.`;
  } finally {
    setBusy(false);
  }
}

async function runBuilt(ev) {
  ev.preventDefault();
  if (state.busy) return;
  const { base, c } = builtFrom();
  const problems = validateCase(c);
  $('b-errors').textContent = problems.join(' ');
  if (problems.length) return; // nothing is sent
  const typed = { base: base.id, fmt: state.builderFormat, msg: $('b-msg').value, err: $('b-err').value, down: $('b-down').checked, min: $('b-min').value };
  closeBuilder(); // focus moves to the build chip and stays there across the busy re-render
  state.activeChip = BUILD;
  $('batch-note').textContent = '';
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
    setFormat(typed.fmt);
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
  setupViews();
  $('header-time').textContent = new Intl.DateTimeFormat('en', {
    weekday: 'short', month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit',
  }).format(new Date());
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
  $('knob-fast').addEventListener('click', () => toggleModelMenu('fast'));
  $('knob-agent').addEventListener('click', () => toggleModelMenu('agent'));
  $('keys-open').addEventListener('click', openKeys);
  // The model menu closes on Escape or a click anywhere outside it and its knob.
  document.addEventListener('click', (e) => {
    if ($('model-menu') && !e.target.closest('#model-menu, .knob, .canvas-controls .model')) closeModelMenu();
  });
  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape' || !$('model-menu')) return;
    const anchor = $('model-menu').dataset.anchor;
    closeModelMenu();
    $(anchor)?.focus();
  });
  window.addEventListener('resize', () => requestAnimationFrame(drawWires));
  // The device changes height when the builder opens or its message box is resized.
  if (window.ResizeObserver) new ResizeObserver(() => requestAnimationFrame(drawWires)).observe(document.querySelector('.device'));
  // A pending focus restore is dropped as soon as the person moves focus or clicks elsewhere.
  document.addEventListener('pointerdown', () => { pendingFocus = null; });
  document.addEventListener('focusin', (e) => { if (e.target.dataset?.key !== pendingFocus) pendingFocus = null; });
  try { state.baseline = await src.baseline(); } catch { state.baseline = null; }
  renderAll();
  renderKpis();
  const hero = state.scenarios.find((s) => s.id === HERO);
  if (src.mode === 'replay' && hero) runScenario(hero); // free in a replay; live waits for a click
}

if (typeof document !== 'undefined') boot();
