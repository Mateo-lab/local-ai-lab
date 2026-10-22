#!/usr/bin/env bash
# ÉTAPE 6 (optionnelle) : installe et démarre Langfuse (suivi des appels de tes agents).
#
#     ./6-langfuse.sh
#
# - clone le dépôt officiel langfuse/langfuse dans langfuse/app (docker-compose.yml officiel)
# - génère tous les secrets dans langfuse/app/.env (fichier caché, jamais écrasé)
# - crée d'avance l'organisation, le projet, ton compte et les clés d'API (variables LANGFUSE_INIT_*)
# - démarre Langfuse : http://127.0.0.1:3002
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/langfuse"

for c in docker git openssl curl; do
  command -v "$c" >/dev/null 2>&1 || { echo "Il manque '$c' (sudo apt install $c)." >&2; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "Docker ne répond pas (voir ./1-prerequis.sh)." >&2; exit 1; }
docker network inspect obs-net >/dev/null 2>&1 || {
  echo "Le réseau obs-net n'existe pas : mets à jour ai-stack puis relance 'docker compose up -d' dedans." >&2; exit 1; }

if [ ! -d app/.git ]; then
  echo "→ Téléchargement du dépôt officiel Langfuse..."
  git clone --depth 1 https://github.com/langfuse/langfuse.git app
fi
cp docker-compose.override.yml app/docker-compose.override.yml

if [ ! -f app/.env ]; then
  echo "→ Génération des secrets (app/.env)..."
  r() { openssl rand -hex "$1"; }
  PG="$(r 24)"; MINIO="$(r 24)"
  umask 077
  cat > app/.env <<ENV
# Généré par 6-langfuse.sh. Ne pas partager. À sauvegarder.
POSTGRES_PASSWORD=${PG}
DATABASE_URL=postgresql://postgres:${PG}@postgres:5432/postgres
SALT=$(r 24)
ENCRYPTION_KEY=$(r 32)
CLICKHOUSE_PASSWORD=$(r 24)
REDIS_AUTH=$(r 24)
NEXTAUTH_SECRET=$(r 32)
NEXTAUTH_URL=http://localhost:3002
MINIO_ROOT_PASSWORD=${MINIO}
LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY=${MINIO}
LANGFUSE_S3_MEDIA_UPLOAD_SECRET_ACCESS_KEY=${MINIO}
LANGFUSE_S3_BATCH_EXPORT_SECRET_ACCESS_KEY=${MINIO}
LANGFUSE_S3_MEDIA_UPLOAD_ENDPOINT=http://localhost:9092

# Création automatique de l'organisation, du projet, du compte et des clés d'API
LANGFUSE_INIT_ORG_ID=labo
LANGFUSE_INIT_ORG_NAME=Labo
LANGFUSE_INIT_PROJECT_ID=labo-ia
LANGFUSE_INIT_PROJECT_NAME=Labo IA
LANGFUSE_INIT_PROJECT_PUBLIC_KEY=pk-lf-$(r 16)
LANGFUSE_INIT_PROJECT_SECRET_KEY=sk-lf-$(r 16)
LANGFUSE_INIT_USER_EMAIL=admin@labo.local
LANGFUSE_INIT_USER_NAME=admin
LANGFUSE_INIT_USER_PASSWORD=$(r 12)
ENV
  chmod 600 app/.env
else
  echo "• app/.env existe déjà : je n'y touche pas."
fi

echo "→ Démarrage de Langfuse (premier lancement : plusieurs minutes)..."
(cd app && docker compose up -d)

echo -n "→ Attente que Langfuse réponde"
for _ in $(seq 1 90); do
  if curl -fsS http://127.0.0.1:3002/api/public/health >/dev/null 2>&1; then ok=1; break; fi
  echo -n "."; sleep 5
done
echo
[ "${ok:-0}" = 1 ] || { echo "Langfuse ne répond pas encore. Regarde : cd langfuse/app && docker compose logs --tail 50 langfuse-web" >&2; exit 1; }

get() { grep -E "^$1=" app/.env | cut -d= -f2-; }
cat <<MSG

Langfuse est prêt : http://127.0.0.1:3002
  Email        : $(get LANGFUSE_INIT_USER_EMAIL)
  Mot de passe : $(get LANGFUSE_INIT_USER_PASSWORD)
  (tout est dans le fichier caché langfuse/app/.env)

Clés d'API du projet « Labo IA » (pour Open WebUI et Hermes) :
  Clé publique : $(get LANGFUSE_INIT_PROJECT_PUBLIC_KEY)
  Clé secrète  : $(get LANGFUSE_INIT_PROJECT_SECRET_KEY)
  Adresse depuis les autres conteneurs : http://langfuse-web:3000
MSG
