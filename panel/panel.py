#!/usr/bin/env python3
"""Panneau de contrôle d'AiBeast : quelques boutons qui lancent des commandes `lab` prédéfinies.

Sécurité (voir docs/web-panel.md) :
  - écoute sur 127.0.0.1 uniquement (tu y accèdes par ton tunnel SSH) ;
  - jeton secret (cookie HttpOnly SameSite=Strict) + en-tête X-Panel + contrôle de Host et d'Origin ;
  - AUCUNE commande libre : seules les actions de ACTIONS existent ; projet et branche doivent être dans la liste réelle de `lab dev pending` ;
  - une seule action à la fois ; sortie nettoyée (séquences d'échappement retirées) et affichée comme du texte.
Bibliothèque standard seulement.
"""
import hmac
import http.server
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import threading
import time
from http import HTTPStatus
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
LAB = os.environ.get("PANEL_LAB", str(ROOT / "lab"))
DEV = os.environ.get("PANEL_DEV", str(ROOT / "scripts" / "dev.sh"))
STATE = Path(os.environ.get("PANEL_STATE", str(ROOT / ".lab")))
TOKEN_FILE = Path(os.environ.get("PANEL_TOKEN_FILE", str(Path.home() / ".config" / "aibeast-panel" / "token")))
PORT = int(os.environ.get("PANEL_PORT", "3011"))
HOST = "127.0.0.1"
COOKIE = "aibeast_panel"
MAX_OUT = 200_000

RE_PROJET = re.compile(r"^[a-z0-9][a-z0-9_-]{0,40}$")
RE_BRANCHE = re.compile(r"^agent/[A-Za-z0-9._-]+$")
RE_ESC = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b.")
RE_CTRL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")

# nom -> (titre, arguments de `lab`, délai maximal en secondes, confirmation demandée par la page)
ACTIONS = {
    "mode-images": ("Mode images", ["mode", "images"], 300, False),
    "mode-normal": ("Mode normal", ["mode", "normal"], 120, False),
    "mode-agents": ("Mode agents", ["mode", "agents"], 120, False),
    "etat": ("État", ["mode", "status"], 60, False),
    "doctor": ("Santé", ["doctor"], 180, False),
    "update": ("Mise à jour", ["update"], 3600, True),
    "backup": ("Sauvegarde", ["backup", "run"], 3600, True),
}


def egal(a: str, b: str) -> bool:
    return hmac.compare_digest(a.encode("utf-8", "replace"), b.encode("utf-8", "replace"))


def nettoyer(texte: str) -> str:
    return RE_CTRL.sub("", RE_ESC.sub("", texte.replace("\r\n", "\n").replace("\r", "\n")))


class Job:
    def __init__(self, nom, titre, argv, delai):
        self.nom, self.titre, self.argv, self.delai = nom, titre, argv, delai
        self.sortie, self.fini, self.code, self.debut = "", False, None, time.time()
        self.lock = threading.Lock()
        self.proc = None

    def etat(self, depuis=0):
        with self.lock:
            return {"nom": self.nom, "titre": self.titre, "fini": self.fini, "code": self.code,
                    "duree": round(time.time() - self.debut, 1), "sortie": self.sortie[depuis:], "taille": len(self.sortie)}

    def ajouter(self, morceau):
        with self.lock:
            if len(self.sortie) < MAX_OUT:
                self.sortie += morceau
                if len(self.sortie) >= MAX_OUT:
                    self.sortie = self.sortie[:MAX_OUT] + "\n[… sortie tronquée]\n"

    def lancer(self):
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        try:
            self.proc = subprocess.Popen(self.argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                         start_new_session=True, cwd=str(ROOT), env={**os.environ, "NO_COLOR": "1", "TERM": "dumb"})
            timer = threading.Timer(self.delai, self._tuer)
            timer.start()
            tampon = b""
            while True:
                bloc = os.read(self.proc.stdout.fileno(), 4096)
                if not bloc:
                    break
                tampon += bloc
                try:
                    texte, tampon = tampon.decode("utf-8"), b""
                except UnicodeDecodeError:
                    if len(tampon) < 8:      # caractère coupé au milieu : on attend la suite
                        continue
                    texte, tampon = tampon.decode("utf-8", "replace"), b""
                self.ajouter(nettoyer(texte))
            self.proc.wait()
            timer.cancel()
            code = self.proc.returncode
        except Exception as e:  # jamais bloquant pour le serveur
            self.ajouter(f"\n[erreur du panneau : {e}]\n")
            code = -1
        with self.lock:
            self.code, self.fini = code, True

    def _tuer(self):
        self.ajouter("\n[délai dépassé : commande arrêtée]\n")
        try:
            os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
        except Exception:
            pass


class Etat:
    courant = None
    verrou = threading.Lock()


def demarrer(nom, titre, argv, delai):
    with Etat.verrou:
        if Etat.courant and not Etat.courant.fini:
            return None
        Etat.courant = Job(nom, titre, argv, delai)
        Etat.courant.lancer()
        return Etat.courant


def sortie_courte(argv, delai=30):
    try:
        r = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=delai, cwd=str(ROOT))
        return nettoyer(r.stdout)
    except Exception:
        return ""


def branches_a_relire():
    sortie = sortie_courte([DEV, "pending"])
    res = []
    for ligne in sortie.splitlines():
        p = ligne.split("\t")
        if len(p) == 3 and RE_PROJET.match(p[0]) and RE_BRANCHE.match(p[1]) and p[2].isdigit():
            res.append({"projet": p[0], "branche": p[1], "commits": int(p[2])})
    return res


def lire_jeton():
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not TOKEN_FILE.exists():
        TOKEN_FILE.write_text(secrets.token_urlsafe(32) + "\n")
        TOKEN_FILE.chmod(0o600)
    return TOKEN_FILE.read_text().strip()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "AiBeastPanel"
    sys_version = ""
    jeton = ""

    def log_message(self, *a):
        pass

    # --- contrôles ---
    def hote_ok(self):
        h = (self.headers.get("Host") or "").lower()
        return h in (f"127.0.0.1:{PORT}", f"localhost:{PORT}")

    def origine_ok(self):
        o = self.headers.get("Origin")
        return o is None or o in (f"http://127.0.0.1:{PORT}", f"http://localhost:{PORT}")

    def cookie_ok(self):
        for part in (self.headers.get("Cookie") or "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == COOKIE and egal(v, self.jeton):
                return True
        return False

    def repondre(self, code, corps, type_="application/json; charset=utf-8", extra=None):
        data = corps if isinstance(corps, bytes) else (json.dumps(corps, ensure_ascii=False).encode() if type_.startswith("application/json") else corps.encode())
        self.send_response(code)
        self.send_header("Content-Type", type_)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; frame-ancestors 'none'")
        self.send_header("Referrer-Policy", "no-referrer")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def refuser(self, code=HTTPStatus.FORBIDDEN, msg="refusé"):
        self.repondre(code, {"erreur": msg})

    def api_ok(self):
        return self.hote_ok() and self.origine_ok() and self.cookie_ok() and self.headers.get("X-Panel") == "1"

    # --- routes ---
    def do_GET(self):
        u = urlparse(self.path)
        if not self.hote_ok():
            return self.refuser(msg="hôte non autorisé")
        if u.path == "/login":
            t = (parse_qs(u.query).get("t") or [""])[0]
            if not egal(t, self.jeton):
                return self.refuser(msg="jeton invalide")
            return self.repondre(HTTPStatus.FOUND, b"", "text/plain", {
                "Location": "/", "Set-Cookie": f"{COOKIE}={self.jeton}; HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000"})
        if u.path in ("/", "/index.html", "/app.js", "/style.css"):
            if not self.cookie_ok():
                return self.repondre(HTTPStatus.UNAUTHORIZED, "Ouvre l'adresse avec le jeton : lab panel token", "text/plain; charset=utf-8")
            nom, type_ = {"/": ("index.html", "text/html; charset=utf-8"), "/index.html": ("index.html", "text/html; charset=utf-8"),
                          "/app.js": ("app.js", "text/javascript; charset=utf-8"), "/style.css": ("style.css", "text/css; charset=utf-8")}[u.path]
            return self.repondre(HTTPStatus.OK, (HERE / nom).read_bytes(), type_)
        if not self.api_ok():
            return self.refuser()
        if u.path == "/api/etat":
            mode = (STATE / "mode").read_text().strip() if (STATE / "mode").exists() else "normal"
            j = Etat.courant
            return self.repondre(HTTPStatus.OK, {"mode": mode, "occupe": bool(j and not j.fini), "job": j.nom if j else None,
                                                 "actions": {k: {"titre": v[0], "confirmer": v[3]} for k, v in ACTIONS.items()}})
        if u.path == "/api/job":
            j = Etat.courant
            if not j:
                return self.repondre(HTTPStatus.OK, {"aucun": True})
            try:
                depuis = max(0, int((parse_qs(u.query).get("depuis") or ["0"])[0]))
            except ValueError:
                depuis = 0
            return self.repondre(HTTPStatus.OK, j.etat(depuis))
        if u.path == "/api/hermes":
            return self.repondre(HTTPStatus.OK, {"branches": branches_a_relire()})
        return self.refuser(HTTPStatus.NOT_FOUND, "inconnu")

    def do_POST(self):
        u = urlparse(self.path)
        if not self.api_ok():
            return self.refuser()
        if u.path != "/api/run":
            return self.refuser(HTTPStatus.NOT_FOUND, "inconnu")
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n > 4096:
                return self.refuser(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "trop gros")
            corps = json.loads(self.rfile.read(n) or b"{}")
            action = corps.get("action")
        except Exception:
            return self.refuser(HTTPStatus.BAD_REQUEST, "requête invalide")
        if action in ACTIONS:
            titre, args, delai, _ = ACTIONS[action]
            argv, dl = [LAB, *args], delai
        elif action in ("hermes-revue", "hermes-diff", "hermes-fusion"):
            projet, branche = corps.get("projet"), corps.get("branche")
            if not (isinstance(projet, str) and isinstance(branche, str) and RE_PROJET.match(projet) and RE_BRANCHE.match(branche)):
                return self.refuser(HTTPStatus.BAD_REQUEST, "projet ou branche invalide")
            if not any(b["projet"] == projet and b["branche"] == branche for b in branches_a_relire()):
                return self.refuser(HTTPStatus.BAD_REQUEST, "cette branche n'est pas dans la liste à relire")
            if action == "hermes-revue":
                titre, argv, dl = f"Revue {projet} {branche}", [DEV, "review", projet, branche], 120
            elif action == "hermes-diff":
                titre, argv, dl = f"Diff {projet} {branche}", [DEV, "review", projet, branche, "--diff"], 120
            else:
                if corps.get("confirme") is not True:
                    return self.refuser(HTTPStatus.BAD_REQUEST, "confirmation requise")
                titre, argv, dl = f"Fusion {projet} {branche}", [DEV, "merge", projet, branche, "--yes"], 1200
        else:
            return self.refuser(HTTPStatus.BAD_REQUEST, "action inconnue")
        job = demarrer(action, titre, argv, dl)
        if job is None:
            return self.repondre(HTTPStatus.CONFLICT, {"erreur": "une action est déjà en cours"})
        return self.repondre(HTTPStatus.ACCEPTED, {"ok": True, "titre": titre})


def main():
    Handler.jeton = lire_jeton()
    srv = http.server.ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Panneau AiBeast sur http://{HOST}:{PORT}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
