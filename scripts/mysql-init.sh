#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

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

# apt リポジトリの問題に対する耐性を強化
log "Fixing potentially broken apt lists"
sudo rm -rf /var/lib/apt/lists/*
sudo mkdir -p /var/lib/apt/lists/partial
sudo apt-get clean

retry_apt_update() {
    for i in {1..5}; do
        log "apt-get update (try $i)..."
        if sudo apt-get update -y; then
            log "apt-get update succeeded"
            return 0
        fi
        log "apt-get update failed. Sleeping 10s and retrying..."
        sleep 10
    done
    log "apt-get update failed after 5 attempts" >&2
    return 1
}

log "Updating apt cache with retry logic"
retry_apt_update

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

# command-not-found が cnf-update-db を実行すると欠落ファイルで失敗するため、一時的に無効化
# command-not-found の Post-Invoke を全パターン無効化
disable_command_not_found_update() {
    log "Disabling command-not-found apt hooks"
    local targets
    targets=$(sudo find /etc/apt/apt.conf.d -maxdepth 1 -type f -name '*command-not-found*' 2>/dev/null || true)
    if [[ -n "$targets" ]]; then
        while IFS= read -r file; do
            if [[ -f "$file" ]]; then
                sudo mv "$file" "${file}.disabled" || sudo truncate -s 0 "$file"
            fi
        done <<< "$targets"
    fi
    sudo rm -f /var/lib/apt/lists/*command-not-found* 2>/dev/null || true
}

disable_command_not_found_update

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

# Azure CLI のインストール（既存の場合はスキップ）
if command -v az >/dev/null 2>&1; then
    log "Azure CLI is already installed. Skipping installation."
else
    log "Installing Azure CLI"
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
    log "Azure CLI installation complete"
fi

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
