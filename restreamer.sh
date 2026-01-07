#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config"

# Load config
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

usage() {
    cat << EOF
Usage: $0 <command>

Commands:
    start   - Create ACI and start Restreamer
    stop    - Delete ACI (stop billing)
    status  - Show current status and URL
    logs    - Show container logs

Configuration is read from: $CONFIG_FILE
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
        --dns-name-label "$DNS_LABEL"

    echo ""
    echo "Container created!"
    echo ""
    cmd_status
}

cmd_stop() {
    echo "Stopping and deleting container: $CONTAINER_NAME"

    if az container show --resource-group "$RESOURCE_GROUP" --name "$CONTAINER_NAME" &>/dev/null; then
        az container delete \
            --resource-group "$RESOURCE_GROUP" \
            --name "$CONTAINER_NAME" \
            --yes \
            --output none
        echo "Container deleted. Billing stopped."
    else
        echo "Container not found."
    fi
}

cmd_status() {
    if ! az container show --resource-group "$RESOURCE_GROUP" --name "$CONTAINER_NAME" &>/dev/null; then
        echo "Container '$CONTAINER_NAME' not found in resource group '$RESOURCE_GROUP'"
        exit 1
    fi

    FQDN=$(az container show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CONTAINER_NAME" \
        --query "ipAddress.fqdn" \
        --output tsv)

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
}

cmd_logs() {
    az container logs \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CONTAINER_NAME" \
        --follow
}

# Main
case "${1:-}" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    logs)   cmd_logs ;;
    *)      usage ;;
esac
