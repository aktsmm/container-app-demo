#!/usr/bin/env bash
set -euo pipefail

# 引数が base64 エンコードされている場合はデコード
if [[ "${1:-}" =~ ^[A-Za-z0-9+/=]+$ ]]; then
    ROOT_PASSWORD=$(echo "$1" | base64 -d)
    APP_USER=$(echo "$2" | base64 -d)
    APP_PASSWORD=$(echo "$3" | base64 -d)
else
    ROOT_PASSWORD="${1:-}"
    APP_USER="${2:-}"
    APP_PASSWORD="${3:-}"
fi

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

CONFIG_FILE='/etc/mysql/mysql.conf.d/mysqld.cnf'

ensure_bind_address() {
    local key="$1"
    if sudo grep -q "^[[:space:]]*${key}[[:space:]]*=" "$CONFIG_FILE"; then
        sudo sed -i "s/^[[:space:]]*${key}[[:space:]]*=.*/${key} = 0.0.0.0/" "$CONFIG_FILE"
    else
        echo "${key} = 0.0.0.0" | sudo tee -a "$CONFIG_FILE" >/dev/null
    fi
}

ROOT_ESC="$(escape_sql "$ROOT_PASSWORD")"
APP_USER_ESC="$(escape_sql "$APP_USER")"
APP_PASS_ESC="$(escape_sql "$APP_PASSWORD")"

log "Updating apt cache"
# command-not-found が cnf-update-db を実行すると欠落ファイルで失敗するため、一時的に無効化
disable_command_not_found_update() {
    local cnf_conf="/etc/apt/apt.conf.d/50command-not-found"
    if [ -f "$cnf_conf" ]; then
        log "Disabling command-not-found apt hook"
        sudo mv "$cnf_conf" "${cnf_conf}.disabled" || sudo truncate -s 0 "$cnf_conf"
    fi
}

disable_command_not_found_update
sudo DEBIAN_FRONTEND=noninteractive apt-get update -y -o APT::Update::Post-Invoke-Success::=

# MySQL パッケージが配布されていないイメージ向けに段階的なフォールバックを実装
install_mysql_server() {
    log "Installing mysql-server (with automatic fallback)"
    if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server; then
        return 0
    fi

    log "mysql-server パッケージが標準リポジトリに無いため Universe を再有効化して再試行"
    sudo apt-get install -y software-properties-common >/dev/null 2>&1 || true
    sudo add-apt-repository -y universe >/dev/null 2>&1 || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y -o APT::Update::Post-Invoke-Success::=
    if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server; then
        return 0
    fi

    log "mysql-server メタパッケージが取得できないため mysql-server-8.0 で再試行"
    if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server-8.0 mysql-client-8.0; then
        return 0
    fi

    log "MySQL パッケージのインストールに失敗しました"
    return 1
}

install_mysql_server

log "Enabling MySQL service"
sudo systemctl enable --now mysql

log "Applying user configuration"
cat <<SQL | sudo mysql
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${ROOT_ESC}';
CREATE USER IF NOT EXISTS '${APP_USER_ESC}'@'%' IDENTIFIED WITH mysql_native_password BY '${APP_PASS_ESC}';
GRANT ALL PRIVILEGES ON *.* TO '${APP_USER_ESC}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

log "Enabling remote MySQL connections"
ensure_bind_address 'bind-address'
ensure_bind_address 'mysqlx-bind-address'

log "Restarting MySQL to apply configuration"
sudo systemctl restart mysql

log "MySQL initialization complete"
