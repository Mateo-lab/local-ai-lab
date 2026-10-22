"use strict";
const E = (id) => document.getElementById(id);
let actions = {}, occupe = false, suivi = null, depuis = 0;

async function api(chemin, corps) {
  const opts = { headers: { "X-Panel": "1" }, credentials: "same-origin" };
  if (corps) { opts.method = "POST"; opts.headers["Content-Type"] = "application/json"; opts.body = JSON.stringify(corps); }
  const r = await fetch(chemin, opts);
  let data = {};
  try { data = await r.json(); } catch (e) { /* pas de JSON */ }
  if (!r.ok) throw new Error(data.erreur || ("erreur " + r.status));
  return data;
}

function statut(texte, classe) { const s = E("statut"); s.textContent = texte; s.className = classe || ""; }

async function etat() {
  try {
    const d = await api("/api/etat");
    actions = d.actions; occupe = d.occupe;
    statut("Mode actuel : " + d.mode + (d.occupe ? " — action en cours…" : ""), d.occupe ? "warn" : "");
    majBoutons();
  } catch (e) { statut("Panneau injoignable : " + e.message, "ko"); }
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
      E("job").textContent = "— " + j.titre + (j.fini ? (j.code === 0 ? " : terminé" : " : code " + j.code) : " : en cours (" + Math.round(j.duree) + " s)");
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
    if (!d.branches.length) { const p = document.createElement("p"); p.textContent = "Aucune branche d'agent à relire."; zone.appendChild(p); return; }
    d.branches.forEach((b) => {
      const l = document.createElement("div"); l.className = "ligne";
      const n = document.createElement("span"); n.className = "nom"; n.textContent = b.projet + " — " + b.branche + " (" + b.commits + " commit(s))";
      l.appendChild(n);
      const mk = (txt, action, conf, cls) => {
        const bt = document.createElement("button"); bt.textContent = txt; if (cls) bt.className = cls; bt.disabled = occupe;
        bt.addEventListener("click", () => lancer({ action, projet: b.projet, branche: b.branche, confirme: conf ? true : undefined }, conf));
        l.appendChild(bt);
      };
      mk("Relire", "hermes-revue");
      mk("Diff complet", "hermes-diff");
      mk("Fusionner", "hermes-fusion", "Fusionner " + b.branche + " dans main ?\nTu as relu le diff ? Les tests sont relancés d'abord ; s'ils échouent, rien n'est fusionné.", "danger");
      zone.appendChild(l);
    });
  } catch (e) { zone.textContent = "Liste indisponible : " + e.message; }
}

document.querySelectorAll("button[data-action]").forEach((b) => {
  b.addEventListener("click", () => {
    const a = b.dataset.action; const info = actions[a] || {};
    lancer({ action: a }, info.confirmer ? ("Lancer « " + (info.titre || a) + " » ? Cela peut prendre plusieurs minutes.") : null);
  });
});

etat().then(hermes).then(() => { if (occupe) suivre(); });
