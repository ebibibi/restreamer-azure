# restreamer-azure

Azure Container Instances (ACI) で [Restreamer](https://github.com/datarhei/restreamer) を必要な時だけ起動し、終わったら削除するためのシンプルなスクリプト。

## 前提条件

- Azure CLI (`az`) がインストール済み

## 使い方

### 起動

```bash
./restreamer.sh start
```

実行すると、以下のような確認画面が表示されます：

```
=== 展開設定の確認 ===

Azureアカウント:     user@example.com
サブスクリプション:  My Subscription
                     (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)

展開先リージョン:    japaneast
リソースグループ:    restreamer-rg
コンテナ名:          restreamer

この設定で展開しますか? [y/N]:
```

`y` で展開開始、それ以外で Azure CLI の設定方法が表示されます。

### 状態確認

```bash
./restreamer.sh status
```

### ログ確認

```bash
./restreamer.sh logs
```

### 停止（削除）

```bash
./restreamer.sh stop
```

## 設定

設定は `config` ファイルで管理されます：

```bash
# リソースグループ名
RESOURCE_GROUP=restreamer-rg

# コンテナ名
CONTAINER_NAME=restreamer

# Azureリージョン
LOCATION=japaneast

# コンテナスペック
CPU=1
MEMORY=1.5
```

リージョンやリソースグループを変更したい場合は、このファイルを編集してください。

## 配信の流れ

1. `./restreamer.sh start` でRestreamerを起動
2. 表示されたWeb UIにアクセス
3. Restreamerの管理画面で初期設定・配信先を設定
4. OBSなどから表示されたRTMP URLに配信
5. 配信終了後、`./restreamer.sh stop` で削除（課金停止）
