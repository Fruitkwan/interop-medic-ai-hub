// Data layer for the judge page. detectSource() picks "live" (the IRIS REST API at /medic/api)
// when it answers, else "replay" (a recorded bundle plus the browser mock models in mock.js).
// Both modes expose the same methods and return the API's decision JSON.
import { mockDecide } from './mock.js';

const ACTIONS = ['resend', 'fix_and_resend', 'reroute', 'quarantine', 'escalate'];
const DEMO_USER = 'demo-user';

/** Error carrying an HTTP-like status (400, 404, 409, ...). */
function httpError(status, message) {
  return Object.assign(new Error(message), { status });
}

const clone = (x) => JSON.parse(JSON.stringify(x));

/** JSON.stringify with sorted keys, so equal cases compare equal whatever their key order. */
function canonical(x) {
  if (Array.isArray(x)) return `[${x.map(canonical).join(',')}]`;
  if (x && typeof x === 'object') {
    return `{${Object.keys(x).sort().map((k) => `${JSON.stringify(k)}:${canonical(x[k])}`).join(',')}}`;
  }
  return JSON.stringify(x);
}

/** "YYYY-MM-DD HH:MM:SS.mmm" (UTC), the format of the audit rows the API returns. */
function stamp() {
  return new Date().toISOString().replace('T', ' ').replace('Z', '');
}

/** API base URL for a page served at /medic/index.html: the relative path ../medic/api. */
function defaultBase() {
  const loc = globalThis.location;
  return loc ? new URL('../medic/api', loc.href).href : '/medic/api';
}

async function loadBundle(fetchImpl, opts) {
  if (opts.bundle) return opts.bundle;
  const url = opts.bundleUrl ?? new URL('../data/bundle.json', import.meta.url).href;
  try {
    const res = await fetchImpl(url);
    if (res.ok) return await res.json();
  } catch { /* fall through to a mock-only replay */ }
  return { recordedAt: '', build: '', models: { fast: 'Mock', agent: 'Mock' }, scenarios: [], batches: [] };
}

function liveSource(fetchImpl, base) {
  async function call(method, path, body) {
    const init = { method };
    if (body !== undefined) {
      init.headers = { 'Content-Type': 'application/json' };
      init.body = JSON.stringify(body);
    }
    const res = await fetchImpl(`${base}${path}`, init);
    let data = null;
    try { data = await res.json(); } catch { /* non-JSON error body */ }
    if (!res.ok) throw httpError(res.status, data?.error ?? `HTTP ${res.status}`);
    return data;
  }
  return {
    mode: 'live',
    scenarios: () => call('GET', '/scenarios'),
    triage: (caseObj) => call('POST', '/triage', { case: caseObj }),
    randomCases: (n = 5) => call('GET', `/cases/random?n=${encodeURIComponent(n)}`),
    approve: (id) => call('POST', `/decisions/${encodeURIComponent(id)}/approve`, {}),
    override: (id, action, target, reason) => call('POST', `/decisions/${encodeURIComponent(id)}/override`,
      { action, rerouteTarget: target, reason }),
    models: () => call('GET', '/models'),
    setModels: (fast, agent) => call('POST', '/models', { fast, agent }),
  };
}

function replaySource(bundle) {
  const recorded = new Map(bundle.scenarios.map((s) => [canonical(s.case), s.decision]));
  for (const batch of bundle.batches) {
    for (const r of batch) recorded.set(canonical(r.case), r.decision);
  }
  /** id -> {decision, routingTable}; decisions live here so approve/override can change them. */
  const store = new Map();
  let nextBatch = 0;

  const remember = (decision, caseObj) => {
    store.set(String(decision.id), { decision, routingTable: caseObj?.context?.routing_table ?? {} });
    return decision;
  };

  function open(id) {
    const entry = store.get(String(id));
    if (!entry) throw httpError(404, `decision ${id} not found`);
    const { decision } = entry;
    const decided = decision.trace.some((s) => s.status === 'hum');
    if (decision.autoApplied || decided) throw httpError(409, 'already decided by a person (or auto-applied)');
    return entry;
  }

  function finish(decision) {
    return { ok: 1, decision, trace: decision.trace, audit: decision.audit, precedent: 0 };
  }

  const audit = (decision, actor, event, detail) => decision.audit.push({ at: stamp(), actor, event, detail });
  const simulated = (action) => (action === 'escalate' ? 'on-call ward paged (simulated)' : `${action} applied (simulated)`);

  return {
    mode: 'replay',
    recordedAt: bundle.recordedAt,
    build: bundle.build,
    async scenarios() {
      return bundle.scenarios.map(({ id, label, case: c }) => ({ id, label, case: clone(c) }));
    },
    async triage(caseObj) {
      const hit = recorded.get(canonical(caseObj));
      if (hit) return remember({ ...clone(hit), source: 'replay' }, caseObj);
      return remember({ ...mockDecide(caseObj), source: 'mock' }, caseObj);
    },
    async randomCases(n = 5) {
      if (bundle.batches.length === 0) return [];
      const batch = bundle.batches[nextBatch % bundle.batches.length];
      nextBatch += 1;
      return batch.slice(0, n).map(({ case: c, expected }) => ({ case: clone(c), expected: clone(expected) }));
    },
    async approve(id) {
      const { decision } = open(id);
      decision.trace.push({
        stage: 'Person', status: 'hum', value: `approved ${decision.action}`,
        detail: `confirmed by ${DEMO_USER}`, ms: 0,
      });
      audit(decision, 'You', `approved ${decision.action}`, `confirmed by ${DEMO_USER}`);
      audit(decision, 'Production', 'action executed', simulated(decision.action));
      return finish(decision);
    },
    async override(id, action, target = '', reason = '') {
      const { decision, routingTable } = open(id);
      if (!ACTIONS.includes(action)) throw httpError(400, `unknown action '${action}'`);
      if (action === 'reroute') {
        if (!target) throw httpError(400, 'reroute needs a target');
        if (!Object.values(routingTable).includes(target)) {
          throw httpError(400, `reroute needs a target from the MedicRouting table, not '${target}'`);
        }
      }
      const was = decision.action;
      decision.action = action;
      decision.rerouteTarget = action === 'reroute' ? target : '';
      decision.decidedBy = 'human';
      decision.trace.push({
        stage: 'Person', status: 'hum', value: `overrode → ${action}`,
        detail: `${reason || `changed by ${DEMO_USER}`} (was ${was})`, ms: 0,
      });
      audit(decision, 'You', `overrode → ${action}`, reason);
      audit(decision, 'Eval', 'correction recorded', `was ${was}, now ${action}`);
      return finish(decision);
    },
    async models() {
      return {
        fast: bundle.models.fast,
        agent: bundle.models.agent,
        available: { fast: [bundle.models.fast], agent: [bundle.models.agent] },
      };
    },
    /** Replay cannot switch models; it reports the ones the bundle was recorded with. */
    async setModels() {
      return this.models();
    },
  };
}

/**
 * Choose the data source. Probes GET {base}/health; a reply with mode "live" within `timeoutMs`
 * selects live mode, anything else (network error, timeout, non-live reply) selects replay.
 * @param {typeof fetch} [fetchImpl] fetch implementation (injectable for tests)
 * @param {number} [timeoutMs] health-check timeout
 * @param {{base?: string, bundle?: object, bundleUrl?: string}} [opts] base API URL (default:
 *   ../medic/api resolved against location), and the replay bundle (default: ../data/bundle.json)
 * @returns {Promise<object>} source with mode, scenarios(), triage(case), randomCases(n),
 *   approve(id), override(id, action, target, reason), models(), setModels(fast, agent)
 */
export async function detectSource(fetchImpl = globalThis.fetch, timeoutMs = 2000, opts = {}) {
  const base = (opts.base ?? defaultBase()).replace(/\/+$/, '');
  const controller = new AbortController();
  let timer;
  try {
    const timeout = new Promise((_, reject) => {
      timer = setTimeout(() => { controller.abort(); reject(new Error('health check timed out')); }, timeoutMs);
    });
    const probe = (async () => {
      const res = await fetchImpl(`${base}/health`, { signal: controller.signal });
      if (!res.ok) throw new Error(`health ${res.status}`);
      return res.json();
    })();
    probe.catch(() => {}); // a late failure after the timeout must not be unhandled
    const health = await Promise.race([probe, timeout]);
    if (health?.mode === 'live') {
      const src = liveSource(fetchImpl, base);
      src.aihub = !!health.aihub;
      src.build = health.build;
      return src;
    }
  } catch { /* fall through to replay */ } finally {
    clearTimeout(timer);
  }
  return replaySource(await loadBundle(fetchImpl, opts));
}
