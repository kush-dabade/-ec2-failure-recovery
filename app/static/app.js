/* EC2 failure-recovery dashboard.
 *
 * Everything shown comes from two real sources:
 *   /api/state   AWS Auto Scaling, ELBv2 and EC2 state (read-only, via the instance role)
 *   /api/whoami  real HTTP requests through the ALB; the answering instance reports its
 *                own IMDSv2 identity
 * The page never changes infrastructure and never infers a failure without AWS confirming it.
 */
"use strict";

const STATE_POLL_MS = 2000;
const REQUEST_INTERVAL_MS = 700;
const REQUEST_TIMEOUT_MS = 3000;
const MAX_LOG_ROWS = 80;
const MAX_TIMELINE = 250;
const ID_SLOTS = 4; // --id-1..--id-4, assigned in fixed order, never cycled

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const fmtTime = (d) => d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
const fmtDur = (ms) => (ms < 60000 ? `${(ms / 1000).toFixed(1)} s` : `${Math.floor(ms / 60000)} min ${Math.round((ms % 60000) / 1000)} s`);
const isGone = (i) => i.ec2_state === "terminated" || i.ec2_state === "shutting-down" || (i.asg_lifecycle || "").startsWith("Terminat");

const store = {
  get(k) { try { return JSON.parse(localStorage.getItem(k)); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch { /* storage unavailable: fine */ } },
};

const S = {
  state: null,
  prevById: {},
  prevHealthy: null,
  prevOverall: null,
  stateOk: true,
  // identity bookkeeping (persisted per ASG so a reload keeps names)
  ident: null, // { labels: {id: {label, slot, kind}}, order: [], ignored: [], replacements: n, seenActs: {id: status} }
  timeline: [],
  traffic: { running: false, seq: 0, ok: 0, fail: 0, log: [], perInstance: {}, streakStart: null, streakCount: 0, longestGap: 0, last: null },
  run: null,
  runs: [],
};

/* ------------------------------------------------------------------ identity */
function identKey() { return `vmfail.ident.${S.state?.asg?.name || "unknown"}`; }
function saveIdent() { store.set(identKey(), S.ident); }

function baseline(state, reason) {
  const active = state.instances
    .filter((i) => i.in_asg && !isGone(i))
    .sort((a, b) => (a.availability_zone || "").localeCompare(b.availability_zone || "") || (a.launch_time || "").localeCompare(b.launch_time || ""));
  const ident = { labels: {}, order: [], ignored: [], replacements: 0, seenActs: {} };
  active.forEach((i, n) => {
    ident.labels[i.instance_id] = { label: `EC2-${n + 1}`, slot: n + 1, kind: "baseline" };
    ident.order.push(i.instance_id);
  });
  state.instances.forEach((i) => { if (!ident.labels[i.instance_id]) ident.ignored.push(i.instance_id); });
  state.activities.forEach((a) => { ident.seenActs[a.id] = a.status; });
  S.ident = ident;
  saveIdent();
  S.prevById = Object.fromEntries(state.instances.map((i) => [i.instance_id, i]));
  S.prevHealthy = state.target_group.healthy;
  S.prevOverall = state.overall;

  addEvent({ kind: "dash", level: "neutral", text: `${reason}. Baseline: ${active.map((i) => `${ident.labels[i.instance_id].label} = <code>${esc(i.instance_id)}</code> (${esc(i.availability_zone)})`).join(", ") || "no active instances"}` });
  const healthy = state.target_group.healthy;
  addEvent({
    kind: "aws", level: healthy >= state.asg.desired ? "good" : "serious",
    text: healthy >= state.asg.desired
      ? `All ${healthy} instances healthy in the target group (desired capacity ${state.asg.desired})`
      : `${healthy} of ${state.asg.desired} desired instances healthy in the target group`,
  });
}

function labelFor(id) { return S.ident?.labels[id]; }

function ensureLabel(inst) {
  const id = inst.instance_id;
  if (S.ident.labels[id] || S.ident.ignored.includes(id)) return S.ident.labels[id];
  S.ident.replacements += 1;
  const slot = S.ident.order.length + 1;
  S.ident.labels[id] = { label: `Replacement ${S.ident.replacements}`, slot: slot <= ID_SLOTS ? slot : 0, kind: "replacement" };
  S.ident.order.push(id);
  saveIdent();
  addEvent({
    kind: "aws", level: "warning",
    text: `Auto Scaling launched replacement instance <code>${esc(id)}</code> in ${esc(inst.availability_zone)} (EC2 state: ${esc(inst.ec2_state || "unknown")})`,
  });
  if (S.run && !S.run.replacements.includes(id)) S.run.replacements.push(id);
  return S.ident.labels[id];
}

const idColor = (id) => { const l = labelFor(id); return l && l.slot ? `var(--id-${l.slot})` : "var(--neutral)"; };
const nameOf = (id) => labelFor(id)?.label || "untracked";
const who = (id) => `${esc(nameOf(id))} <code>${esc(id)}</code>`;

/* ------------------------------------------------------------------ timeline */
function addEvent({ kind, level = "neutral", text, detail, at }) {
  const ev = { t: at ? new Date(at) : new Date(), kind, level, text, detail, key: Math.random().toString(36).slice(2), fresh: true };
  S.timeline.push(ev);
  S.timeline.sort((a, b) => b.t - a.t);
  if (S.timeline.length > MAX_TIMELINE) S.timeline.length = MAX_TIMELINE;
  renderTimeline();
}

const KIND_LABEL = { aws: ["AWS observed", "tag-aws"], activity: ["ASG activity", "tag-activity"], operator: ["Operator request", "tag-operator"], http: ["HTTP observed", "tag-http"], dash: ["Dashboard", "tag-dash"] };

function renderTimeline() {
  $("timeline").innerHTML = S.timeline.map((e) => {
    const [label, cls] = KIND_LABEL[e.kind];
    const html = `<li class="${e.level}${e.fresh ? " enter" : ""}"><div class="tl-meta"><span class="mono">${fmtTime(e.t)}</span><span class="tag ${cls}">${label}</span></div><div class="tl-text">${e.text}</div>${e.detail ? `<div class="tl-detail">${esc(e.detail)}</div>` : ""}</li>`;
    e.fresh = false;
    return html;
  }).join("");
}

/* ------------------------------------------------------------------ state diff */
function onState(state) {
  const first = !S.state;
  S.state = state;
  if (first) {
    const saved = store.get(identKey());
    const live = new Set(state.instances.map((i) => i.instance_id));
    if (saved && saved.order && saved.order.some((id) => live.has(id))) {
      S.ident = saved;
      S.prevById = Object.fromEntries(state.instances.map((i) => [i.instance_id, i]));
      S.prevHealthy = state.target_group.healthy;
      S.prevOverall = state.overall;
      addEvent({ kind: "dash", text: `Dashboard reconnected; kept instance names from this browser's earlier session` });
    } else {
      baseline(state, "Dashboard connected to AWS state");
    }
    render();
    return;
  }

  const desired = state.asg.desired;

  // New scaling activities, oldest first, stamped with AWS's own start time.
  [...state.activities].reverse().forEach((a) => {
    const seen = S.ident.seenActs[a.id];
    if (seen === undefined) {
      const byOperator = /user request/i.test(a.cause || "");
      addEvent({ kind: byOperator ? "operator" : "activity", level: /Terminating/i.test(a.description || "") ? "critical" : "warning", text: esc(a.description), detail: a.cause, at: a.start });
      const m = /Terminating EC2 instance: (i-[0-9a-f]+)/.exec(a.description || "");
      if (m) startRun(m[1], `AWS scaling activity: ${a.description}`, a.start);
    } else if (seen !== a.status && ["Successful", "Failed", "Cancelled"].includes(a.status)) {
      addEvent({ kind: "activity", level: a.status === "Successful" ? "good" : "critical", text: `${esc(a.status)}: ${esc(a.description)}`, at: a.end || undefined });
    }
    S.ident.seenActs[a.id] = a.status;
  });

  // Per-instance transitions.
  for (const inst of state.instances) {
    if (S.ident.ignored.includes(inst.instance_id)) continue;
    const label = ensureLabel(inst);
    const prev = S.prevById[inst.instance_id];
    if (!prev) continue;
    const L = who(inst.instance_id);
    if (prev.ec2_state !== inst.ec2_state) {
      const lvl = { running: "good", pending: "warning", "shutting-down": "critical", terminated: "critical", stopping: "critical", stopped: "critical" }[inst.ec2_state] || "neutral";
      addEvent({ kind: "aws", level: lvl, text: `${L} EC2 state: ${esc(prev.ec2_state)} → <strong>${esc(inst.ec2_state)}</strong>`, detail: inst.state_reason });
    }
    if (prev.asg_lifecycle !== inst.asg_lifecycle) {
      addEvent({ kind: "aws", level: inst.asg_lifecycle === "InService" ? "good" : inst.asg_lifecycle ? "warning" : "critical", text: `${L} ASG lifecycle: ${esc(prev.asg_lifecycle || "—")} → <strong>${esc(inst.asg_lifecycle || "removed from group")}</strong>` });
    }
    if (prev.target_state !== inst.target_state) {
      const ts = inst.target_state;
      const text = ts === "healthy" && label?.kind === "replacement"
        ? `${L} passed ALB health checks; it now receives traffic`
        : `${L} target health: ${esc(prev.target_state || "not registered")} → <strong>${esc(ts || "deregistered")}</strong>`;
      addEvent({ kind: "aws", level: ts === "healthy" ? "good" : ts === "initial" ? "warning" : "critical", text, detail: inst.target_description || inst.target_reason });
      if (ts === "healthy" && S.run && S.run.replacements.includes(inst.instance_id) && !S.run.replacementHealthyAt) S.run.replacementHealthyAt = new Date();
    }
    // AWS-confirmed loss of a serving instance opens a failure run.
    const lost = (prev.target_state === "healthy" && inst.target_state !== "healthy") || (!isGone(prev) && isGone(inst));
    if (lost) startRun(inst.instance_id, "AWS reported the instance leaving service");
  }

  const healthy = state.target_group.healthy;
  if (S.prevHealthy !== null && healthy !== S.prevHealthy) {
    const restored = healthy >= desired && S.prevHealthy < desired;
    addEvent({
      kind: "aws", level: restored ? "good" : healthy < S.prevHealthy ? "critical" : "warning",
      text: restored ? `<strong>${healthy} healthy targets restored</strong> (desired capacity ${desired})` : `Healthy targets: ${S.prevHealthy} → <strong>${healthy}</strong> (desired ${desired})`,
    });
  }
  if (S.prevOverall && state.overall !== S.prevOverall) {
    addEvent({ kind: "aws", level: { HEALTHY: "good", RECOVERING: "warning", DEGRADED: "serious", OUTAGE: "critical" }[state.overall], text: `Application status: ${esc(S.prevOverall)} → <strong>${esc(state.overall)}</strong>` });
  }

  maybeFinishRun(state);
  S.prevById = Object.fromEntries(state.instances.map((i) => [i.instance_id, i]));
  S.prevHealthy = healthy;
  S.prevOverall = state.overall;
  saveIdent();
  render();
}

/* ------------------------------------------------------------------ runs */
function startRun(instanceId, why, awsStart) {
  if (S.run) return;
  if (!labelFor(instanceId)) return; // only instances that belong to this session
  S.run = {
    failedId: instanceId, confirmedAt: new Date(), awsStart: awsStart ? new Date(awsStart) : null, why,
    ok: 0, fail: 0, servedAfter: {}, replacements: [], replacementHealthyAt: null, restoredAt: null,
    streakStart: null, longestGap: 0, trafficSeen: S.traffic.running,
  };
  addEvent({ kind: "aws", level: "critical", text: `<strong>Failure confirmed by AWS</strong>: ${who(instanceId)} is leaving service`, detail: why });
  $("summary-card").hidden = false;
}

function maybeFinishRun(state) {
  const r = S.run;
  if (!r) return;
  const failed = state.instances.find((i) => i.instance_id === r.failedId);
  const failedOut = !failed || !failed.in_asg;
  if (state.overall === "HEALTHY" && failedOut && state.target_group.healthy >= state.asg.desired) {
    r.restoredAt = new Date();
    if (r.streakStart) { r.longestGap = Math.max(r.longestGap, r.restoredAt - r.streakStart); }
    addEvent({ kind: "aws", level: "good", text: `<strong>Recovery complete</strong>: ${state.target_group.healthy} healthy targets, ${fmtDur(r.restoredAt - r.confirmedAt)} after the failure was confirmed` });
    S.runs.unshift(r);
    S.run = null;
  }
}

/* ------------------------------------------------------------------ traffic */
async function trafficLoop() {
  const T = S.traffic;
  while (T.running) {
    const t0 = performance.now();
    const seq = ++T.seq;
    const rec = { seq, at: new Date(), status: null, id: null, az: null, ms: null, error: null };
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), REQUEST_TIMEOUT_MS);
    try {
      const r = await fetch(`/api/whoami?seq=${seq}&t=${Date.now()}`, { cache: "no-store", signal: ctrl.signal });
      rec.status = r.status;
      if (r.ok) {
        const j = await r.json();
        rec.id = j.instance_id || r.headers.get("X-Instance-Id");
        rec.az = j.availability_zone || r.headers.get("X-Availability-Zone");
      }
    } catch (e) {
      rec.error = e.name === "AbortError" ? "timeout" : "network error";
    } finally {
      clearTimeout(timer);
      rec.ms = Math.round(performance.now() - t0);
    }
    onRequest(rec);
    await sleep(Math.max(0, REQUEST_INTERVAL_MS - (performance.now() - t0)));
  }
}

function onRequest(rec) {
  const T = S.traffic;
  const ok = rec.status === 200 && !!rec.id;
  rec.ok = ok;
  T.last = rec;
  T.log.unshift(rec);
  if (T.log.length > 2000) T.log.length = 2000;
  if (ok) { T.ok++; T.perInstance[rec.id] = (T.perInstance[rec.id] || 0) + 1; } else T.fail++;

  if (!ok && !T.streakStart) {
    T.streakStart = rec.at; T.streakCount = 0;
    addEvent({ kind: "http", level: "critical", text: `Request #${rec.seq} failed: ${esc(rec.status ? `HTTP ${rec.status}` : rec.error)}` });
  }
  if (!ok) T.streakCount++;
  if (ok && T.streakStart) {
    const gap = rec.at - T.streakStart;
    T.longestGap = Math.max(T.longestGap, gap);
    addEvent({ kind: "http", level: "good", text: `Requests succeeding again after ${T.streakCount} failed request(s); gap ${fmtDur(gap)}` });
    T.streakStart = null;
  }

  const r = S.run;
  if (r) {
    r.trafficSeen = true;
    if (ok) {
      r.ok++;
      if (r.streakStart) { r.longestGap = Math.max(r.longestGap, rec.at - r.streakStart); r.streakStart = null; }
      if (!r.servedAfter[rec.id]) {
        r.servedAfter[rec.id] = 0;
        if (rec.id !== r.failedId) addEvent({ kind: "http", level: "good", text: `Request #${rec.seq} after the failure was served by ${who(rec.id)}` });
      }
      r.servedAfter[rec.id]++;
    } else {
      r.fail++;
      if (!r.streakStart) r.streakStart = rec.at;
    }
  }
  renderTraffic(rec);
  animatePacket(rec);
}

/* ------------------------------------------------------------------ render */
const ICONS = {
  good: '<svg viewBox="0 0 12 12"><path d="M2.5 6.2l2.3 2.3 4.7-5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  warning: '<svg viewBox="0 0 12 12"><g class="spin"><path d="M6 1.5a4.5 4.5 0 1 1-4.5 4.5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></g></svg>',
  serious: '<svg viewBox="0 0 12 12"><path d="M3 6h6" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>',
  critical: '<svg viewBox="0 0 12 12"><path d="M3.2 3.2l5.6 5.6M8.8 3.2L3.2 8.8" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>',
  neutral: '<svg viewBox="0 0 12 12"><circle cx="6" cy="6" r="2.5" fill="currentColor"/></svg>',
};
const badge = (level, text) => `<span class="badge ${level}">${ICONS[level]}${esc(text)}</span>`;

function instStatus(i) {
  if (i.ec2_state === "terminated") return ["TERMINATED", "critical", "Out of service: terminated"];
  if (i.ec2_state === "shutting-down" || (i.asg_lifecycle || "").startsWith("Terminat")) return ["TERMINATING", "critical", "Being terminated: no longer serving"];
  if (i.target_state === "draining") return ["DRAINING", "serious", "Removed from rotation (connection draining)"];
  if (i.target_state === "unhealthy") return ["UNHEALTHY", "critical", "Failing ALB health checks: not serving"];
  if (i.ec2_state === "pending" || (i.asg_lifecycle || "").startsWith("Pending")) return ["PENDING", "warning", "Booting: not yet registered for traffic"];
  if (i.target_state === "initial") return ["HEALTH CHECK", "warning", "Registered; waiting to pass ALB health checks"];
  if (i.target_state === "healthy") return ["HEALTHY", "good", "Serving traffic"];
  if (i.ec2_state === "running") return ["NOT IN SERVICE", "serious", "Running but not a healthy target"];
  return ["UNKNOWN", "neutral", "State unknown"];
}

function visibleInstances() {
  if (!S.state || !S.ident) return [];
  const byId = Object.fromEntries(S.state.instances.map((i) => [i.instance_id, i]));
  const keepTerminated = new Set([S.run?.failedId, S.runs[0]?.failedId].filter(Boolean));
  return S.ident.order.map((id) => byId[id]).filter((i) => i && (!isGone(i) || i.in_asg || keepTerminated.has(i.instance_id)));
}

const renderedCards = new Set();
function renderInstances() {
  const list = visibleInstances();
  const total = Object.values(S.traffic.perInstance).reduce((a, b) => a + b, 0);
  const box = $("instances");
  if (!list.length) { box.innerHTML = `<p class="hint">No experiment instances found in AWS.</p>`; return; }
  box.innerHTML = list.map((i) => {
    const l = labelFor(i.instance_id);
    const [st, lvl, role] = instStatus(i);
    const served = S.traffic.perInstance[i.instance_id] || 0;
    const pct = total ? Math.round((served / total) * 100) : 0;
    const enter = !renderedCards.has(i.instance_id) ? " enter" : "";
    return `<article class="inst${enter}" data-id="${esc(i.instance_id)}" data-status="${st}" style="--idc:${idColor(i.instance_id)}">
      <div class="inst-head"><span class="inst-name"><i class="swatch"></i>${esc(l.label)}</span>${badge(lvl, st)}</div>
      <div class="inst-id">${esc(i.instance_id)}</div>
      <div class="inst-role">${esc(l.kind === "replacement" && st !== "HEALTHY" && lvl === "warning" ? `Replacement launched by Auto Scaling: ${role.toLowerCase()}` : role)}</div>
      <dl>
        <dt>Availability Zone</dt><dd>${esc(i.availability_zone || "—")}</dd>
        <dt>EC2 state</dt><dd>${esc(i.ec2_state || "—")}</dd>
        <dt>ASG lifecycle</dt><dd>${esc(i.asg_lifecycle || (i.in_asg ? "—" : "not in group"))}</dd>
        <dt>Target health</dt><dd>${esc(i.target_state || "not registered")}${i.target_reason ? ` <span title="${esc(i.target_description)}">(${esc(i.target_reason.replace(/^(Target|Elb)\./, ""))})</span>` : ""}</dd>
        <dt>Launched</dt><dd>${i.launch_time ? fmtTime(new Date(i.launch_time)) : "—"}</dd>
        <dt>Private IP</dt><dd>${esc(i.private_ip || "—")}</dd>
      </dl>
      <div class="share"><div class="share-bar"><i style="width:${pct}%"></i></div>
        <div class="share-label"><span>Requests served this run</span><span class="mono">${served} · ${pct}%</span></div></div>
    </article>`;
  }).join("");
  list.forEach((i) => renderedCards.add(i.instance_id));
}

function renderFailRows() {
  const box = $("fail-rows");
  const list = visibleInstances().filter((i) => i.in_asg && !isGone(i));
  if (!list.length) { box.innerHTML = `<p class="hint">No running instances in the group.</p>`; return; }
  const key = list.map((i) => i.instance_id).join(",");
  if (box.dataset.key === key) return;
  box.dataset.key = key;
  box.innerHTML = list.map((i) => {
    const cmd = `./scripts/fail-instance.sh ${i.instance_id}`;
    return `<div class="fail-row" style="--idc:${idColor(i.instance_id)}"><span class="who"><i class="swatch"></i>Fail ${esc(labelFor(i.instance_id).label)}</span><code>${esc(cmd)}</code><button class="btn small" data-copy="${esc(cmd)}" type="button">Copy</button></div>`;
  }).join("");
}

function renderKpis() {
  const st = S.state;
  const T = S.traffic;
  const n = T.ok + T.fail;
  $("kpi-avail").textContent = n ? `${((T.ok / n) * 100).toFixed(n >= 1000 ? 2 : 1)}%` : "—";
  $("kpi-avail-foot").textContent = n ? `${T.ok} ok · ${T.fail} failed of ${n} requests` : "no requests yet";
  if (st && !st.error) {
    $("kpi-healthy").textContent = st.target_group.healthy;
    $("kpi-desired").textContent = st.asg.desired;
    $("kpi-inservice").textContent = `${st.asg.in_service} / ${st.asg.desired}`;
    $("kpi-asg-foot").textContent = `min ${st.asg.min} · max ${st.asg.max} · health check: ${st.asg.health_check_type}`;
    const slots = Math.max(st.asg.desired, st.instances.filter((i) => i.in_asg).length);
    const initial = st.instances.filter((i) => i.target_state === "initial").length;
    $("kpi-slots").innerHTML = Array.from({ length: slots }, (_, k) => `<span class="slot${k < st.target_group.healthy ? " on" : k < st.target_group.healthy + initial ? " warn" : ""}"></span>`).join("");
  }
  const cutoff = Date.now() - 10000;
  const recent = new Set(T.log.filter((r) => r.ok && r.at.getTime() >= cutoff).map((r) => r.id));
  $("kpi-serving").textContent = T.running || recent.size ? recent.size : "—";
  $("kpi-serving-foot").textContent = recent.size ? [...recent].map(nameOf).join(", ") : T.running ? "no successful responses in 10 s" : "start traffic to measure";
}

function renderHeader() {
  const st = S.state;
  let overall = "UNKNOWN";
  if (!S.stateOk) overall = "UNREACHABLE";
  else if (st && !st.error) overall = st.overall;
  $("overall").dataset.status = overall;
  $("overall-text").textContent = overall === "UNKNOWN" ? (st?.error ? "AWS ERROR" : "CONNECTING") : overall;
  if (st) {
    $("asg-name").textContent = st.asg?.name || "—";
    $("region").textContent = st.region || "ap-south-1";
    $("endpoint").textContent = st.alb_dns ? `http://${st.alb_dns}` : location.origin;
    $("state-served-by").innerHTML = st.served_by?.instance_id ? `${esc(nameOf(st.served_by.instance_id))} ${esc(st.served_by.instance_id)}` : `${esc(st.served_by?.hostname || "—")} (not EC2)`;
    if (st.error) $("state-age").textContent = `AWS error: ${st.error}`;
  }
}

function renderStateAge() {
  const st = S.state;
  if (!st || st.error) return;
  const age = Math.max(0, (Date.now() - new Date(st.fetched_at).getTime()) / 1000);
  $("state-age").textContent = S.stateOk ? `${age.toFixed(0)} s ago` : "state API unreachable";
}

function renderTraffic(rec) {
  const body = $("log-body");
  if (body.querySelector("tr.empty")) body.innerHTML = "";
  const tr = document.createElement("tr");
  tr.className = `new${rec.ok ? "" : " fail"}`;
  tr.innerHTML = `<td>${fmtTime(rec.at)}</td><td>${rec.seq}</td><td>${rec.ok ? badge("good", String(rec.status)) : badge("critical", rec.status ? String(rec.status) : rec.error)}</td>
    <td>${rec.id ? `<span class="who-chip" style="--idc:${idColor(rec.id)}"><i class="swatch"></i>${esc(nameOf(rec.id))} · ${esc(rec.id)}</span>` : "—"}</td>
    <td>${esc(rec.az || "—")}</td><td class="num">${rec.ms} ms</td>`;
  body.prepend(tr);
  while (body.rows.length > MAX_LOG_ROWS) body.deleteRow(body.rows.length - 1);
  $("last-http").innerHTML = rec.ok ? `${rec.status} OK · ${esc(nameOf(rec.id))}` : `<span style="color:var(--critical-ink)">${esc(rec.status ? `HTTP ${rec.status}` : rec.error)}</span>`;
  const card = document.querySelector(`.inst[data-id="${CSS.escape(rec.id || "")}"]`);
  if (card) { card.classList.remove("flash", "enter"); void card.offsetWidth; card.classList.add("flash"); }
  renderKpis();
  if (rec.seq % 3 === 0) renderInstances();
  renderSummary();
}

/* ------------------------------------------------------------------ routing svg */
const NS = "http://www.w3.org/2000/svg";
let routeGeom = { key: "", targets: {} };

function renderRouting() {
  const svg = $("routing");
  const list = visibleInstances();
  const key = list.map((i) => `${i.instance_id}:${instStatus(i)[0]}:${i.target_state}`).join("|") + `|${S.state?.alb_dns}`;
  if (key === routeGeom.key) return;
  routeGeom = { key, targets: {} };
  let stat = svg.querySelector("#r-static");
  if (!stat) {
    stat = document.createElementNS(NS, "g"); stat.id = "r-static"; svg.appendChild(stat);
    const p = document.createElementNS(NS, "g"); p.id = "r-pkts"; svg.appendChild(p);
  }
  const H = 260, nodeH = 52;
  const n = Math.max(list.length, 1);
  const gap = Math.min(18, (H - n * nodeH) / (n + 1));
  const totalH = n * nodeH + (n - 1) * gap;
  const y0 = (H - totalH) / 2;
  const alb = { x: 280, y: H / 2 - 32, w: 170, h: 64 };
  let html = `
    <path class="link base" d="M150 ${H / 2} L${alb.x} ${H / 2}"/>
    <g class="node"><rect x="10" y="${H / 2 - 26}" width="140" height="52" rx="8"/><text x="24" y="${H / 2 - 3}">Browser</text><text class="meta" x="24" y="${H / 2 + 14}">this page</text></g>`;
  list.forEach((i, k) => {
    const y = y0 + k * (nodeH + gap);
    const cy = y + nodeH / 2;
    const [st] = instStatus(i);
    const cls = i.target_state === "healthy" ? "healthy" : ["initial", "draining"].includes(i.target_state) || st === "PENDING" ? "warn" : "down";
    const x1 = alb.x + alb.w, x2 = 530;
    html += `<path class="link ${cls}" d="M${x1} ${H / 2} C${x1 + 60} ${H / 2}, ${x2 - 60} ${cy}, ${x2} ${cy}"/>
      <g class="node${cls === "down" ? " down" : ""}"><rect x="${x2}" y="${y}" width="220" height="${nodeH}" rx="8" style="stroke:${idColor(i.instance_id)}"/>
      <text x="${x2 + 14}" y="${y + 21}">${esc(nameOf(i.instance_id))} · ${esc(st)}</text>
      <text class="meta" x="${x2 + 14}" y="${y + 39}">${esc(i.instance_id)} · ${esc((i.availability_zone || "").slice(-2))}</text></g>`;
    routeGeom.targets[i.instance_id] = { x1, x2, cy };
  });
  html += `<g class="node"><rect x="${alb.x}" y="${alb.y}" width="${alb.w}" height="${alb.h}" rx="8" style="stroke:var(--accent)"/>
    <text x="${alb.x + 14}" y="${alb.y + 27}">Load balancer</text><text class="meta" x="${alb.x + 14}" y="${alb.y + 45}">ALB · round robin</text></g>`;
  stat.innerHTML = html;
  routeGeom.H = H; routeGeom.alb = alb;
}

function bezier(p0, p1, p2, p3, t) {
  const u = 1 - t;
  return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3;
}

function animatePacket(rec) {
  const pk = $("r-pkts");
  if (!pk || !routeGeom.alb || matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  const H = routeGeom.H, alb = routeGeom.alb;
  const tgt = rec.ok ? routeGeom.targets[rec.id] : null;
  const c = document.createElementNS(NS, "circle");
  c.setAttribute("r", "6");
  c.setAttribute("class", rec.ok ? "pkt" : "pkt pkt-fail");
  if (rec.ok) c.style.fill = idColor(rec.id);
  pk.appendChild(c);
  const dur = 900, start = performance.now();
  const step = (now) => {
    const t = Math.min(1, (now - start) / dur);
    let x, y;
    if (t < 0.45) { x = 150 + (alb.x + alb.w / 2 - 150) * (t / 0.45); y = H / 2; }
    else if (!tgt) { x = alb.x + alb.w / 2; y = H / 2; c.style.opacity = String(1 - (t - 0.45) / 0.55); }
    else {
      const s = (t - 0.45) / 0.55;
      x = bezier(alb.x + alb.w / 2, tgt.x1 + 60, tgt.x2 - 60, tgt.x2, s);
      y = bezier(H / 2, H / 2, tgt.cy, tgt.cy, s);
    }
    c.setAttribute("cx", x.toFixed(1)); c.setAttribute("cy", y.toFixed(1));
    if (t < 1) requestAnimationFrame(step); else c.remove();
  };
  requestAnimationFrame(step);
}

/* ------------------------------------------------------------------ summary */
function renderSummary() {
  const r = S.run || S.runs[0];
  const card = $("summary-card");
  if (!r) { card.hidden = true; return; }
  card.hidden = false;
  const live = r === S.run;
  $("summary-state").textContent = live ? "failure in progress" : "complete";
  const n = r.ok + r.fail;
  let verdict;
  if (!r.trafficSeen || n === 0) {
    verdict = `<div class="verdict">Traffic was not running during this failure, so HTTP availability was not measured. Press “Start normal operation” before the next failure.</div>`;
  } else if (r.fail === 0) {
    verdict = `<div class="verdict good"><strong>Application remained accessible.</strong> All ${n} requests sent during the failure window returned HTTP 200. No downtime was observed at a ${REQUEST_INTERVAL_MS} ms sampling interval; a gap shorter than that would not show up.</div>`;
  } else if (r.ok > 0) {
    verdict = `<div class="verdict serious"><strong>Application was mostly accessible, with an observed interruption.</strong> ${r.fail} of ${n} requests failed; the longest observed gap was ${fmtDur(r.longestGap || (r.streakStart ? Date.now() - r.streakStart : 0))}.</div>`;
  } else {
    verdict = `<div class="verdict critical"><strong>Application was not accessible</strong> during the failure window (${r.fail} failed requests).</div>`;
  }
  const after = Object.keys(r.servedAfter).filter((id) => id !== r.failedId);
  const repl = r.replacements.map((id) => { const i = S.state?.instances.find((x) => x.instance_id === id); return `${esc(id)} (${esc(i?.availability_zone || "?")})`; });
  const end = r.restoredAt || new Date();
  const gap = r.longestGap || (r.streakStart ? Date.now() - r.streakStart : 0);
  const rows = [
    ["Failed instance", `${esc(nameOf(r.failedId))} ${esc(r.failedId)}`],
    ["Failure confirmed (AWS)", fmtTime(r.confirmedAt) + (r.awsStart ? ` · ASG activity ${fmtTime(r.awsStart)}` : "")],
    ["Served traffic after failure", after.length ? after.map((id) => `${esc(nameOf(id))} ${esc(id)} (${r.servedAfter[id]})`).join("<br>") : "—"],
    ["Replacement instance", repl.length ? repl.join("<br>") : live ? "waiting for Auto Scaling…" : "—"],
    ["Replacement healthy at", r.replacementHealthyAt ? fmtTime(r.replacementHealthyAt) : "—"],
    [live ? "Elapsed since failure" : "Time to 2 healthy targets", fmtDur(end - r.confirmedAt)],
    ["Requests during failure", n ? `${r.ok} ok · ${r.fail} failed` : "not measured"],
    ["Observed downtime", !n ? "not measured" : r.fail === 0 ? "none observed" : `${fmtDur(gap)} (${r.fail} failed requests)`],
  ];
  $("summary").innerHTML = `${verdict}<dl class="summary-grid">${rows.map(([k, v]) => `<div><dt>${k}</dt><dd>${v}</dd></div>`).join("")}</dl>
    <p class="summary-note">Durations are measured with this browser's clock, from when the dashboard saw each AWS state change (polled every ${STATE_POLL_MS / 1000} s), so they are accurate to about ±${STATE_POLL_MS / 1000} s.</p>
    ${S.runs.length > (live ? 0 : 1) ? `<div class="prev-runs">Earlier runs this session: ${S.runs.slice(live ? 0 : 1).map((p) => `${esc(nameOf(p.failedId))} → restored in ${fmtDur(p.restoredAt - p.confirmedAt)}, ${p.fail} failed requests`).join("; ")}</div>` : ""}`;
}

function render() {
  renderHeader();
  renderKpis();
  renderInstances();
  renderFailRows();
  renderRouting();
  renderSummary();
  renderStateAge();
}

/* ------------------------------------------------------------------ polling */
async function pollState() {
  for (;;) {
    try {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 5000);
      const r = await fetch(`/api/state?t=${Date.now()}`, { cache: "no-store", signal: ctrl.signal });
      clearTimeout(timer);
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const st = await r.json();
      if (!S.stateOk) addEvent({ kind: "dash", level: "good", text: "State API reachable again" });
      S.stateOk = true;
      if (st.error) { S.state = S.state ? { ...S.state, error: st.error } : st; renderHeader(); }
      else onState(st);
    } catch (e) {
      if (S.stateOk) addEvent({ kind: "dash", level: "critical", text: `State API unreachable through the ALB (${esc(e.name === "AbortError" ? "timeout" : e.message)})` });
      S.stateOk = false;
      renderHeader();
    }
    renderStateAge();
    await sleep(STATE_POLL_MS);
  }
}

/* ------------------------------------------------------------------ controls */
function startTraffic() {
  if (S.traffic.running) return;
  S.traffic.running = true;
  $("btn-start").disabled = true;
  $("btn-stop").disabled = false;
  $("traffic-hint").textContent = `Sending one request every ${REQUEST_INTERVAL_MS} ms to ${$("endpoint").textContent}/api/whoami`;
  addEvent({ kind: "dash", text: "Normal operation started: sending real requests through the load balancer" });
  trafficLoop();
}

function stopTraffic() {
  if (!S.traffic.running) return;
  S.traffic.running = false;
  $("btn-start").disabled = false;
  $("btn-stop").disabled = true;
  addEvent({ kind: "dash", text: `Traffic stopped (${S.traffic.ok} ok, ${S.traffic.fail} failed)` });
}

async function refreshAndNewRun() {
  const r = await fetch(`/api/state?t=${Date.now()}`, { cache: "no-store" }).catch(() => null);
  const st = r && r.ok ? await r.json() : null;
  if (!st || st.error) { addEvent({ kind: "dash", level: "critical", text: "Could not refresh AWS state" }); return; }
  S.state = st;
  S.traffic = { ...S.traffic, ok: 0, fail: 0, log: [], perInstance: {}, streakStart: null, streakCount: 0, longestGap: 0 };
  S.run = null; S.runs = [];
  renderedCards.clear();
  $("log-body").innerHTML = `<tr class="empty"><td colspan="6">${S.traffic.running ? "Waiting for responses…" : "Press “Start normal operation” to send requests."}</td></tr>`;
  $("fail-rows").dataset.key = "";
  routeGeom.key = "";
  baseline(st, "Infrastructure state refreshed from AWS; new run started. Terminated instances do not return; the current instances are the baseline");
  render();
}

document.addEventListener("click", (e) => {
  const b = e.target.closest("[data-copy]");
  if (!b) return;
  const text = b.dataset.copy;
  const done = () => { b.textContent = "Copied"; setTimeout(() => (b.textContent = "Copy"), 1200); };
  if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(text).then(done, () => {});
  else {
    const ta = Object.assign(document.createElement("textarea"), { value: text });
    document.body.appendChild(ta); ta.select();
    try { document.execCommand("copy"); done(); } catch { /* ignore */ }
    ta.remove();
  }
});

document.addEventListener("DOMContentLoaded", () => {
  $("btn-start").addEventListener("click", startTraffic);
  $("btn-stop").addEventListener("click", stopTraffic);
  $("btn-refresh").addEventListener("click", refreshAndNewRun);
  setInterval(() => { renderStateAge(); renderKpis(); if (S.run) renderSummary(); }, 1000);
  pollState();
});
