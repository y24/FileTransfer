# FileTransfer

共有フォルダ・この PC・仮想端末 の間で、ファイルを速く・手軽に転送するツールです。
リモートデスクトップのコピー＆ペーストの代わりに、Windows のファイル共有（SMB）と robocopy で直接転送します。

- 送るファイルを選ぶ（＋、ドラッグ＆ドロップ、エクスプローラーでコピーして Ctrl+V）
- 送り先にホスト名（または「このPC」）とフォルダ（例: `C:\Work\{datetime}`）を入れる
- ［転送開始］

サーバーへは `C:\Work` のようなサーバー上のパスを書くだけで、`\\ホスト名\C$\Work` に自動で変換して送ります。
Python などのインストールは不要で、Windows 10 / 11 標準の PowerShell 5.1 と .NET Framework だけで動きます。

## インストール

1. このフォルダを共有フォルダなどに置く
2. 各自が `install.bat` をダブルクリックする（管理者権限は不要）
3. デスクトップかスタートメニューの「FileTransfer」から起動する

`%LOCALAPPDATA%\Programs\FileTransfer` にインストールされます。更新するときは `install.bat` をもう一度実行し、削除するときは `install.bat -Uninstall` を実行します。

インストールせずに試すときは `FileTransfer.bat` をダブルクリックします。

## 使い方

| やりたいこと | 送り先 | フォルダの例 |
|--------------|--------|-------------|
| パッチをサーバーに置く | `SV-APP01` | `C:\Work\{datetime}` |
| 共有フォルダからこの PC に持ってくる | `このPC` | `D:\Transfer\{date}` |
| この PC から共有フォルダに置く | `このPC` | `\\fs01\work\yamada\{date}` |

- フォルダ欄で使えるテンプレート: `{datetime}`（20261015_1432）、`{date}`（20261015）、`{time}`（1432）、`{now:yyyy-MM-dd_HHmmss}`、`{user}`、`{host}`
- 送り先とフォルダは ▾ から履歴を選べます
- 送り先の左端の ● は接続状態です（緑: OK／黄: ログオンが必要／赤: 接続できない）。クリックすると接続するアカウントを変えられます
- ローカルアカウントは `ホスト名\ユーザー名`、AD アカウントは `ドメイン\ユーザー名` でログオンします。「資格情報を保存する」にすると Windows の資格情報マネージャーに保存され、次回から入力不要になります
- Ctrl+Enter で転送開始、Delete で選んだファイルを一覧から外せます

## サーバー側の前提

- クライアント PC からサーバーのファイル共有（TCP 445）に接続できること
- 管理共有（`C$` など）が有効で、接続するアカウントがサーバーの管理者であること
- ローカルアカウントの場合、組み込みの Administrator 以外は Windows の仕様で管理共有に接続できないことがあります。その場合はサーバーに転送用の共有を作り、`settings.default.json` の `serverShareMappings` に登録します（詳しくは設計書 11 章）

## 設定

| ファイル | 内容 |
|----------|------|
| `settings.default.json`（このフォルダ） | 管理者が配る既定値。サーバーの一覧、`serverShareMappings`、転送オプションなど |
| `%APPDATA%\FileTransfer\settings.json` | ユーザーごとの履歴・前回の値・ウィンドウ位置 |
| `%LOCALAPPDATA%\FileTransfer\logs\` | 転送ログ（1 日 1 ファイル、30 日で削除） |

項目の一覧は [docs/design.md](docs/design.md) の 8 章にあります。

## 開発

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
```

```bash
powershell -NoProfile -STA -ExecutionPolicy Bypass -File tests\Render-Screens.ps1 -OutDir screens
```

- `Run-Tests.ps1`: パス解決、実行計画、robocopy の出力解析、実際のローカル転送、中止などの自動テスト
- `Render-Screens.ps1`: アプリを画面外に表示して操作し、各状態の画面を PNG に保存します（自分自身の管理共有を使ったサーバー転送も行います）
- `.ps1` / `.psm1` は **BOM 付き UTF-8** で保存してください（Windows PowerShell 5.1 は BOM なしの UTF-8 を Shift-JIS として読みます）。`.cs` と `.bat` は ASCII のみにしてください
- 設計書: [docs/design.md](docs/design.md)、UI モック: [docs/ui-mock.html](docs/ui-mock.html)
