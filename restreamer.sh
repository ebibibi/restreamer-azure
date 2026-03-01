#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config"
BACKUP_DIR="$SCRIPT_DIR/backup"
BACKUP_DB_FILE="$BACKUP_DIR/db.json"
AUTO_YES=false
STOP_AFTER_MINUTES=0  # 0 = タイマーなし

# Load config
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

usage() {
    cat << EOF
Usage: $0 [-y] [-t <minutes>] <command>

Options:
    -y           - Skip confirmation prompt (auto-yes)
    -t <minutes> - Auto-stop after specified minutes (0 = disabled)

Commands:
    start      - Create ACI and start Restreamer
    stop       - Backup config and delete ACI (stop billing)
    status     - Show current status and URL
    checklist  - Show pre-broadcast checklist (OBS settings, output destinations)
    logs       - Show container logs

Configuration is read from: $CONFIG_FILE
Backup is saved to: $BACKUP_DIR
EOF
    exit 1
}

show_az_help() {
    cat << EOF

=== Azure CLI の設定方法 ===

アカウントを変更する場合:
    az login

サブスクリプションを変更する場合:
    az account list --output table
    az account set --subscription "サブスクリプション名またはID"

リージョンやリソースグループを変更する場合:
    設定ファイルを編集してください: $CONFIG_FILE

EOF
}

get_fqdn() {
    az container show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CONTAINER_NAME" \
        --query "ipAddress.fqdn" \
        --output tsv 2>/dev/null
}

wait_for_api() {
    local fqdn="$1"
    local max_attempts=30
    local attempt=1

    echo "Waiting for Restreamer API to be ready..."
    while [ $attempt -le $max_attempts ]; do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://${fqdn}:8080/api" 2>/dev/null || echo "000")

        if [ "$http_code" = "200" ] || [ "$http_code" = "401" ]; then
            echo "API is ready."
            return 0
        fi
        echo "  Attempt $attempt/$max_attempts (HTTP: $http_code)..."
        sleep 5
        attempt=$((attempt + 1))
    done
    echo "Warning: API did not become ready in time."
    return 1
}

backup_config() {
    echo "Backing up Restreamer configuration..."

    mkdir -p "$BACKUP_DIR"

    # Use az container exec to read db.json
    local db_content
    db_content=$(az container exec \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CONTAINER_NAME" \
        --exec-command "cat /core/config/db.json" 2>/dev/null)

    if [ -n "$db_content" ]; then
        echo "$db_content" > "$BACKUP_DB_FILE"
        echo "Configuration backed up to: $BACKUP_DB_FILE"
        return 0
    else
        echo "Warning: Failed to backup configuration."
        return 1
    fi
}

restore_config() {
    if [ ! -f "$BACKUP_DB_FILE" ]; then
        echo "No backup found. Skipping restore."
        return 0
    fi

    local fqdn
    fqdn=$(get_fqdn)

    echo "Restoring Restreamer configuration from backup..."

    python3 "$SCRIPT_DIR/restore.py" \
        "http://${fqdn}:8080" \
        "$RESTREAMER_USERNAME" \
        "$RESTREAMER_PASSWORD" \
        "$BACKUP_DB_FILE"

    return $?
}

confirm_deployment() {
    echo "=== 展開設定の確認 ==="
    echo ""

    # Get current Azure account info
    ACCOUNT_NAME=$(az account show --query "user.name" --output tsv 2>/dev/null || echo "(未ログイン)")
    SUBSCRIPTION_NAME=$(az account show --query "name" --output tsv 2>/dev/null || echo "(未選択)")
    SUBSCRIPTION_ID=$(az account show --query "id" --output tsv 2>/dev/null || echo "")

    echo "Azureアカウント:     $ACCOUNT_NAME"
    echo "サブスクリプション:  $SUBSCRIPTION_NAME"
    if [ -n "$SUBSCRIPTION_ID" ]; then
        echo "                     ($SUBSCRIPTION_ID)"
    fi
    echo ""
    echo "展開先リージョン:    $LOCATION"
    echo "リソースグループ:    $RESOURCE_GROUP"
    echo "コンテナ名:          $CONTAINER_NAME"
    echo ""
    echo "Restreamer認証:"
    echo "  Username: $RESTREAMER_USERNAME"
    echo "  Password: $RESTREAMER_PASSWORD"
    echo ""

    if [ -f "$BACKUP_DB_FILE" ]; then
        echo "バックアップ:        あり (起動後に自動復元します)"
    else
        echo "バックアップ:        なし (初回セットアップ)"
    fi
    echo ""

    if $AUTO_YES; then
        echo "自動確認（-y オプション）"
        return 0
    fi

    read -p "この設定で展開しますか? [y/N]: " answer
    case "$answer" in
        [yY]|[yY][eE][sS])
            return 0
            ;;
        *)
            show_az_help
            return 1
            ;;
    esac
}

notify_discord_start() {
    [ -z "${NOTIFY_DISCORD_URL:-}" ] && return 0

    local fqdn
    fqdn=$(get_fqdn 2>/dev/null || echo "unknown")

    local timer_msg=""
    if [ "$STOP_AFTER_MINUTES" -gt 0 ]; then
        timer_msg="\n⏱ ${STOP_AFTER_MINUTES}分後に自動停止します"
    else
        timer_msg="\n⚠️ 自動停止なし。終わったら忘れずに停止してね"
    fi

    local message
    message="🔴 **Restreamer 起動中（課金中）**\n\`\`\`\nWeb UI: http://${fqdn}:8080\nRTMP:   rtmp://${fqdn}:1935/live/stream\n\`\`\`${timer_msg}\n\n停止コマンド:\n\`\`\`bash\ncd ~/restreamer-azure && ./restreamer.sh stop\n\`\`\`"

    curl -s -X POST "${NOTIFY_DISCORD_URL}" \
        -H "Content-Type: application/json" \
        -d "{\"content\": \"${message}\"}" &>/dev/null || true
}

ensure_resource_group() {
    if ! az group show --name "$RESOURCE_GROUP" &>/dev/null; then
        echo "Creating resource group: $RESOURCE_GROUP in $LOCATION"
        az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
    fi
}

cmd_start() {
    if ! confirm_deployment; then
        exit 0
    fi

    echo ""
    ensure_resource_group

    echo "Starting Restreamer on ACI..."
    echo ""

    DNS_LABEL="$CONTAINER_NAME-$(openssl rand -hex 4)"

    az container create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CONTAINER_NAME" \
        --image "$IMAGE" \
        --os-type Linux \
        --cpu "$CPU" \
        --memory "$MEMORY" \
        --ip-address Public \
        --ports 8080 1935 \
        --dns-name-label "$DNS_LABEL" \
        --environment-variables \
            CORE_API_AUTH_ENABLE=true \
            CORE_API_AUTH_USERNAME="$RESTREAMER_USERNAME" \
            CORE_API_AUTH_PASSWORD="$RESTREAMER_PASSWORD"

    echo ""
    echo "Container created!"
    echo ""

    cmd_status

    # Wait and restore config if backup exists
    if [ -f "$BACKUP_DB_FILE" ]; then
        echo ""
        FQDN=$(get_fqdn)
        if wait_for_api "$FQDN"; then
            restore_config
        fi
    fi

    # Auto-stop timer
    if [ "$STOP_AFTER_MINUTES" -gt 0 ]; then
        local stop_time
        stop_time=$(date -d "+${STOP_AFTER_MINUTES} minutes" "+%H:%M" 2>/dev/null || date -v "+${STOP_AFTER_MINUTES}M" "+%H:%M")
        nohup bash -c "sleep $((STOP_AFTER_MINUTES * 60)) && cd '$SCRIPT_DIR' && ./restreamer.sh -y stop" &>/dev/null &
        echo ""
        echo "⏱ 自動停止タイマー: ${STOP_AFTER_MINUTES}分後（約 ${stop_time}）に自動停止します（PID: $!）"
    fi

    # Discord notification
    notify_discord_start

    # 配信前チェックリストを自動表示
    echo ""
    cmd_checklist
}

cmd_stop() {
    echo "Stopping container: $CONTAINER_NAME"

    if ! az container show --resource-group "$RESOURCE_GROUP" --name "$CONTAINER_NAME" &>/dev/null; then
        echo "Container not found."
        return 0
    fi

    # Backup before deleting
    backup_config || true

    echo ""
    echo "Deleting container..."
    az container delete \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CONTAINER_NAME" \
        --yes \
        --output none
    echo "Container deleted. Billing stopped."
}

cmd_status() {
    if ! az container show --resource-group "$RESOURCE_GROUP" --name "$CONTAINER_NAME" &>/dev/null; then
        echo "Container '$CONTAINER_NAME' not found in resource group '$RESOURCE_GROUP'"
        exit 1
    fi

    FQDN=$(get_fqdn)

    STATE=$(az container show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CONTAINER_NAME" \
        --query "instanceView.state" \
        --output tsv)

    IP=$(az container show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CONTAINER_NAME" \
        --query "ipAddress.ip" \
        --output tsv)

    echo "=== Restreamer Status ==="
    echo "State: $STATE"
    echo ""
    echo "Web UI:     http://${FQDN}:8080"
    echo "RTMP URL:   rtmp://${FQDN}:1935/live/stream"
    echo ""
    echo "IP Address: $IP"
    echo ""
    echo "Login:"
    echo "  Username: $RESTREAMER_USERNAME"
    echo "  Password: $RESTREAMER_PASSWORD"
}

cmd_checklist() {
    if [ ! -f "$BACKUP_DB_FILE" ]; then
        echo "バックアップが見つかりません。先に start を実行してください。"
        exit 1
    fi

    # コンテナが起動中かチェック
    local fqdn=""
    if az container show --resource-group "$RESOURCE_GROUP" --name "$CONTAINER_NAME" &>/dev/null 2>&1; then
        fqdn=$(get_fqdn)
    fi

    BACKUP_DB_FILE="$BACKUP_DB_FILE" \
    FQDN="$fqdn" \
    RESTREAMER_USERNAME="$RESTREAMER_USERNAME" \
    RESTREAMER_PASSWORD="$RESTREAMER_PASSWORD" \
    python3 << 'PYEOF'
import json, os

with open(os.environ["BACKUP_DB_FILE"]) as f:
    db = json.load(f)

processes = db.get("process", {})
fqdn = os.environ.get("FQDN", "")

# ingest から stream key を取得
stream_key = ""
for pid, proc in processes.items():
    if ":ingest:" in pid and "_snapshot" not in pid:
        for inp in proc.get("config", {}).get("input", []):
            addr = inp.get("address", "")
            if "rtmp,name=" in addr:
                stream_key = addr.split("name=")[1].split("}")[0]
                break

# egress から配信先ラベルを取得
platforms = {
    "facebook.com": "Facebook Live",
    "youtube.com":  "YouTube Live",
    "x.com":        "X (Twitter)",
    "linkedin.com": "LinkedIn Live",
    "twitch.tv":    "Twitch",
}
outputs = []
for pid, proc in processes.items():
    if ":egress:" in pid:
        for out in proc.get("config", {}).get("output", []):
            addr = out.get("address", "")
            label = next((v for k, v in platforms.items() if k in addr), addr[:60])
            outputs.append(label)

print("=" * 50)
print("配信前チェックリスト")
print("=" * 50)
print()

if fqdn:
    print("[Restreamer]")
    print(f"  Web UI  : http://{fqdn}:8080")
    print(f"  ログイン: {os.environ['RESTREAMER_USERNAME']} / {os.environ['RESTREAMER_PASSWORD']}")
    print()
    print("[OBS 配信設定]")
    print(f"  サーバー      : rtmp://{fqdn}:1935/live/")
    print(f"  ストリームキー: {stream_key}")
else:
    print("[OBS 配信設定]  ※ start 後にサーバー URL が確定します")
    print(f"  ストリームキー: {stream_key}  (固定値・変わらない)")

print()
print("[配信先チェック]  各プラットフォームのストリームキー有効期限を確認")
for dest in outputs:
    print(f"  [ ] {dest}")

print()
print("[配信開始手順]")
print("  1. 上記 OBS 設定を入力して「配信開始」")
print("  2. Restreamer Web UI でプロセスが Running になることを確認")
print("  3. 各プラットフォームで映像が届くか確認")
PYEOF
}

cmd_logs() {
    az container logs \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CONTAINER_NAME" \
        --follow
}

# Main
while getopts "yt:" opt; do
    case "$opt" in
        y) AUTO_YES=true ;;
        t) STOP_AFTER_MINUTES="$OPTARG" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

case "${1:-}" in
    start)     cmd_start ;;
    stop)      cmd_stop ;;
    status)    cmd_status ;;
    checklist) cmd_checklist ;;
    logs)      cmd_logs ;;
    *)         usage ;;
esac
