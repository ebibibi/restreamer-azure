# restreamer-azure

Azure Container Instances (ACI) で [Restreamer](https://github.com/datarhei/restreamer) を必要な時だけ起動し、終わったら削除するためのシンプルなスクリプト。

設定は自動的にバックアップ・リストアされるため、毎回同じ配信設定で使えます。

## 前提条件

- Azure CLI (`az`) がインストール済み
- `curl` がインストール済み
- `python3` がインストール済み

## 使い方

### 初回セットアップ

1. `config` ファイルを作成してパスワードを設定

```bash
cp config.example config
# config ファイルを編集してパスワードを変更してください
RESTREAMER_USERNAME=admin
RESTREAMER_PASSWORD=yourpassword  # 変更してください
```

2. 起動

```bash
./restreamer.sh start
```

3. 表示されたWeb UIにアクセスして配信先を設定

### 2回目以降

```bash
./restreamer.sh start
```

前回の設定が自動的に復元されます。

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

設定がバックアップされてからコンテナが削除されます。

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

# Restreamer認証情報
RESTREAMER_USERNAME=admin
RESTREAMER_PASSWORD=changeme123
```

## バックアップ

- 設定は `backup/` ディレクトリに自動保存されます
- `stop` 時に自動バックアップ
- `start` 時に自動リストア
- `backup/` は `.gitignore` に含まれているため、Gitにはコミットされません

## 配信の流れ

1. `./restreamer.sh start` でRestreamerを起動
2. 表示されたWeb UIにアクセスしてログイン
3. Restreamerの管理画面で配信先（YouTube, Twitchなど）を設定
4. OBSなどから表示されたRTMP URLに配信
5. 配信終了後、`./restreamer.sh stop` で削除（設定はバックアップされる）
6. 次回は `./restreamer.sh start` で同じ設定が復元される
