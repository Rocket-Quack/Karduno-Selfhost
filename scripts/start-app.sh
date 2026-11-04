#!/bin/sh
# Karduno Self-Hosted: load secret files for the unchanged API image.
set -eu

JWT_SECRET=$(cat /run/secrets/jwt_secret)
if [ "${#JWT_SECRET}" -lt 32 ]; then
    echo 'Karduno: the JWT secret is missing or shorter than 32 characters.' >&2
    exit 1
fi
export JWT_SECRET

# Encode URL characters in existing passwords and database names.
DATABASE_URL=$(/venv/bin/python -c '
import os
from pathlib import Path
from urllib.parse import quote

password = Path("/run/secrets/postgres_password").read_text().rstrip("\n")
if not password:
    raise SystemExit("Karduno: the database password is empty.")
user = quote(os.environ["POSTGRES_USER"], safe="")
database = quote(os.environ["POSTGRES_DB"], safe="")
password = quote(password, safe="")
print(f"postgresql+asyncpg://{user}:{password}@postgres:5432/{database}")
')
export DATABASE_URL

# Empty optional values must not create an empty bootstrap account.
if [ -z "${INITIAL_ADMIN_EMAIL:-}" ]; then unset INITIAL_ADMIN_EMAIL; fi
if [ -z "${INITIAL_ADMIN_PASSWORD:-}" ]; then unset INITIAL_ADMIN_PASSWORD; fi

case "${1:-}" in
    api)
        # The current image passes this URL through Alembic ConfigParser.
        # Reject percent escapes before its exception can expose credentials.
        case "$DATABASE_URL" in
            *%*)
                echo 'Karduno: this API image requires URL-unreserved database credentials for migrations. Use generated hex secrets for a fresh installation; preserve existing secrets before migrating an existing instance.' >&2
                exit 1
                ;;
        esac
        /venv/bin/python scripts/ensure_schema.py
        exec /venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000 \
            --workers "${API_WORKERS:-1}" --no-proxy-headers
        ;;
    worker)
        exec /venv/bin/arq app.jobs.Worker
        ;;
    exec)
        shift
        exec "$@"
        ;;
    *)
        echo 'Karduno: the startup mode must be api, worker, or exec.' >&2
        exit 1
        ;;
esac
