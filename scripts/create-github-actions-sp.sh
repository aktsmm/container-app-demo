#!/bin/bash
# ============================================================================
# create-github-actions-sp.sh
# GitHub Actions から Azure へ接続するための Service Principal を作成するスクリプト
# Mac / Linux ユーザー向けのシェルスクリプト版
#
# 主な処理:
# 1. 指定スコープで Service Principal を作成
# 2. ロールを割り当て (Contributor + Resource Policy Contributor + User Access Administrator)
# 3. GitHub Actions に設定すべき AZURE_CLIENT_ID などの値を出力
# ============================================================================

set -e

# ============================================================
# デフォルト値
# -s, --subscription-id : [必須] Azure サブスクリプション ID
# -g, --resource-group  : [任意] リソースグループ名
# -n, --display-name    : [任意] SP 表示名 (既定: gha-sp-secret)
# -r, --role            : [任意] ロール (既定: Contributor)
# -y, --years           : [任意] シークレット有効期限 (既定: 2年)
# ============================================================
DISPLAY_NAME="gha-sp-secret"
ROLE_DEFINITION_NAME="Contributor"
SECRET_DURATION_YEARS=2

# 使用方法を表示
usage() {
    cat << EOF
使用方法:
    $0 -s <SUBSCRIPTION_ID> [オプション]

必須パラメータ:
    -s, --subscription-id    Azure サブスクリプション ID

オプション:
    -g, --resource-group     リソースグループ名（指定時は RG スコープで権限付与）
    -n, --display-name       Service Principal の表示名（デフォルト: gha-sp-secret）
    -r, --role               付与するロール（デフォルト: Contributor）
    -y, --years              シークレット有効期限（1-5年、デフォルト: 2）
    -h, --help               このヘルプを表示

例:
    # サブスクリプションスコープで作成
    $0 -s "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

    # リソースグループスコープで作成（推奨）
    $0 -s "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -g "RG-bbs-app-demo"
EOF
    exit 1
}

# Azure CLI の確認
check_az_cli() {
    if ! command -v az &> /dev/null; then
        echo "❌ エラー: Azure CLI (az) が見つかりません。"
        echo "インストール: https://learn.microsoft.com/cli/azure/install-azure-cli"
        exit 1
    fi

    if ! az account show &> /dev/null; then
        echo "❌ エラー: Azure CLI にサインインしていません。"
        echo "実行してください: az login"
        exit 1
    fi

    echo "✅ Azure CLI 確認完了"
}

# スコープを解決
resolve_scope() {
    local subscription_id="$1"
    local resource_group="$2"

    if [[ -n "$resource_group" ]]; then
        # リソースグループの存在確認
        local group_id
        group_id=$(az group show --name "$resource_group" --subscription "$subscription_id" --query id -o tsv 2>/dev/null)
        if [[ -z "$group_id" ]]; then
            echo "❌ エラー: リソースグループ '$resource_group' が見つかりません。"
            exit 1
        fi
        echo "$group_id"
    else
        echo "/subscriptions/$subscription_id"
    fi
}

# ロール割り当てを確認して追加
set_role_if_missing() {
    local assignee_object_id="$1"
    local role_name="$2"
    local scope="$3"

    local existing
    existing=$(az role assignment list \
        --assignee "$assignee_object_id" \
        --scope "$scope" \
        --role "$role_name" \
        --only-show-errors 2>/dev/null | jq length)

    if [[ "$existing" -eq 0 ]]; then
        echo "📝 追加ロール '$role_name' を割り当てています..."
        az role assignment create \
            --assignee-object-id "$assignee_object_id" \
            --assignee-principal-type ServicePrincipal \
            --scope "$scope" \
            --role "$role_name" \
            --only-show-errors > /dev/null
        echo "✅ ロール '$role_name' を割り当てました"
    else
        echo "ℹ️  ロール '$role_name' は既に割り当て済みです"
    fi
}

# パラメータ解析
SUBSCRIPTION_ID=""
RESOURCE_GROUP=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--subscription-id)
            SUBSCRIPTION_ID="$2"
            shift 2
            ;;
        -g|--resource-group)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        -n|--display-name)
            DISPLAY_NAME="$2"
            shift 2
            ;;
        -r|--role)
            ROLE_DEFINITION_NAME="$2"
            shift 2
            ;;
        -y|--years)
            SECRET_DURATION_YEARS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "❌ 不明なオプション: $1"
            usage
            ;;
    esac
done

# 必須パラメータチェック
if [[ -z "$SUBSCRIPTION_ID" ]]; then
    echo "❌ エラー: サブスクリプション ID は必須です。"
    usage
fi

# 有効期限のバリデーション
if [[ "$SECRET_DURATION_YEARS" -lt 1 || "$SECRET_DURATION_YEARS" -gt 5 ]]; then
    echo "❌ エラー: シークレット有効期限は 1-5 年の範囲で指定してください。"
    exit 1
fi

echo ""
echo "============================================"
echo "🔧 Service Principal 作成スクリプト"
echo "============================================"
echo ""

# Azure CLI 確認
check_az_cli

# スコープを解決
echo ""
echo "📌 スコープを解決しています..."
SCOPE=$(resolve_scope "$SUBSCRIPTION_ID" "$RESOURCE_GROUP")
echo "   スコープ: $SCOPE"

# サブスクリプションを設定
az account set --subscription "$SUBSCRIPTION_ID"

# Service Principal を作成
echo ""
echo "🔐 Service Principal を作成しています..."
RESULT=$(az ad sp create-for-rbac \
    --name "$DISPLAY_NAME" \
    --role "$ROLE_DEFINITION_NAME" \
    --scopes "$SCOPE" \
    --years "$SECRET_DURATION_YEARS" \
    --only-show-errors)

if [[ -z "$RESULT" ]]; then
    echo "❌ エラー: Service Principal の作成に失敗しました。"
    echo "権限と名前の重複を確認してください。"
    exit 1
fi

# 結果を解析
APP_ID=$(echo "$RESULT" | jq -r '.appId')
TENANT_ID=$(echo "$RESULT" | jq -r '.tenant')
CLIENT_SECRET=$(echo "$RESULT" | jq -r '.password')

# Service Principal の Object ID を取得
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

echo "✅ Service Principal を作成しました"
echo "   表示名: $DISPLAY_NAME"
echo "   アプリID: $APP_ID"

# 追加ロールを割り当て
echo ""
echo "📝 追加ロールを割り当てています..."

# Resource Policy Contributor (Azure Policy デプロイに必要)
set_role_if_missing "$SP_OBJECT_ID" "Resource Policy Contributor" "$SCOPE"

# User Access Administrator (Managed Identity へのロール割り当てに必要)
set_role_if_missing "$SP_OBJECT_ID" "User Access Administrator" "$SCOPE"

# 結果を出力
echo ""
echo "============================================"
echo "--- setup-github-secrets_variables.sh に転記 ---"
echo "============================================"
echo ""
echo "AZURE_SUBSCRIPTION_ID=\"$SUBSCRIPTION_ID\""
echo "AZURE_CLIENT_ID=\"$APP_ID\""
echo "AZURE_CLIENT_SECRET=\"$CLIENT_SECRET\""
echo "AZURE_TENANT_ID=\"$TENANT_ID\""
echo ""
echo "============================================"
echo "Scope: $SCOPE"
echo "シークレット有効期限: ${SECRET_DURATION_YEARS}年"
echo "============================================"
echo ""
echo "💡 上記の値を scripts/setup-github-secrets_variables.sh の Azure 認証情報セクションに転記してください。"
echo ""
