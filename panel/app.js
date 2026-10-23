"use strict";
const E = (id) => document.getElementById(id);
let actions = {}, occupe = false, suivi = null, depuis = 0;

async function api(chemin, corps) {
  const opts = { headers: { "X-Panel": "1" }, credentials: "same-origin" };
  if (corps) { opts.method = "POST"; opts.headers["Content-Type"] = "application/json"; opts.body = JSON.stringify(corps); }
  const r = await fetch(chemin, opts);
  let data = {};
  try { data = await r.json(); } catch (e) { /* no JSON */ }
  if (!r.ok) throw new Error(data.erreur || ("error " + r.status));
  return data;
}

function statut(texte, classe) { const s = E("statut"); s.textContent = texte; s.className = classe || ""; }

async function etat() {
  try {
    const d = await api("/api/etat");
    actions = d.actions; occupe = d.occupe;
    statut("Current mode: " + d.mode + (d.occupe ? " — action running…" : ""), d.occupe ? "warn" : "");
    majBoutons();
  } catch (e) { statut("Panel unreachable: " + e.message, "ko"); }
}

function majBoutons() {
  document.querySelectorAll("button").forEach((b) => { b.disabled = occupe; });
}

async function lancer(corps, confirmation) {
  if (confirmation && !window.confirm(confirmation)) return;
  try {
    await api("/api/run", corps);
    depuis = 0; E("sortie").textContent = ""; occupe = true; majBoutons();
    suivre();
  } catch (e) { statut(e.message, "ko"); }
}

function suivre() {
  if (suivi) clearTimeout(suivi);
  const tour = async () => {
    try {
      const j = await api("/api/job?depuis=" + depuis);
      if (j.aucun) return;
      if (j.sortie) { E("sortie").textContent += j.sortie; E("sortie").scrollTop = E("sortie").scrollHeight; }
      depuis = j.taille;
      E("job").textContent = "— " + j.titre + (j.fini ? (j.code === 0 ? ": done" : ": code " + j.code) : ": running (" + Math.round(j.duree) + " s)");
      if (!j.fini) { suivi = setTimeout(tour, 1000); return; }
    } catch (e) { statut(e.message, "ko"); }
    await etat(); await hermes();
  };
  tour();
}

async function hermes() {
  const zone = E("hermes");
  try {
    const d = await api("/api/hermes");
    zone.textContent = "";
    if (!d.branches.length) { const p = document.createElement("p"); p.textContent = "No agent branch to review."; zone.appendChild(p); return; }
    d.branches.forEach((b) => {
      const l = document.createElement("div"); l.className = "ligne";
      const n = document.createElement("span"); n.className = "nom"; n.textContent = b.projet + " — " + b.branche + " (" + b.commits + " commit(s))";
      l.appendChild(n);
      const mk = (txt, action, conf, cls) => {
        const bt = document.createElement("button"); bt.textContent = txt; if (cls) bt.className = cls; bt.disabled = occupe;
        bt.addEventListener("click", () => lancer({ action, projet: b.projet, branche: b.branche, confirme: conf ? true : undefined }, conf));
        l.appendChild(bt);
      };
      mk("Review", "hermes-revue");
      mk("Full diff", "hermes-diff");
      mk("Merge", "hermes-fusion", "Merge " + b.branche + " into main?\nHave you reviewed the diff? The tests run again first; if they fail, nothing is merged.", "danger");
      zone.appendChild(l);
    });
  } catch (e) { zone.textContent = "List unavailable: " + e.message; }
}

document.querySelectorAll("button[data-action]").forEach((b) => {
  b.addEventListener("click", () => {
    const a = b.dataset.action; const info = actions[a] || {};
    lancer({ action: a }, info.confirmer ? ("Run \"" + (info.titre || a) + "\"? This can take several minutes.") : null);
  });
});

etat().then(hermes).then(() => { if (occupe) suivre(); });
