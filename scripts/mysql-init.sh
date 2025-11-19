#!/usr/bin/env bash
set -euo pipefail

ROOT_PASSWORD="${1:-}"
APP_USER="${2:-}"
APP_PASSWORD="${3:-}"

if [[ -z "$ROOT_PASSWORD" || -z "$APP_USER" || -z "$APP_PASSWORD" ]]; then
    echo "[mysql-init] Required arguments are missing" >&2
    exit 1
fi

log() {
    echo "[mysql-init] $1"
}

escape_sql() {
    # Escapes single quotes for SQL statements
    printf "%s" "$1" | sed "s/'/''/g"
}

ROOT_ESC="$(escape_sql "$ROOT_PASSWORD")"
APP_USER_ESC="$(escape_sql "$APP_USER")"
APP_PASS_ESC="$(escape_sql "$APP_PASSWORD")"

log "Updating apt cache"
sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
log "Installing mysql-server"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server

log "Enabling MySQL service"
sudo systemctl enable --now mysql

log "Applying user configuration"
cat <<SQL | sudo mysql
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${ROOT_ESC}';
CREATE USER IF NOT EXISTS '${APP_USER_ESC}'@'%' IDENTIFIED WITH mysql_native_password BY '${APP_PASS_ESC}';
GRANT ALL PRIVILEGES ON *.* TO '${APP_USER_ESC}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

log "MySQL initialization complete"
