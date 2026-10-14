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

### 複数のサーバーに配る

送り先にホスト名をカンマ区切りで書くと、同じファイルを全台に配ります（例: `SV-APP01, SV-APP02, SV-APP03`）。

- 共有フォルダのファイルは、先にこの PC へ 1 回だけ取得してから、最大 3 台ずつ並列に送ります（取得したものは終わったら消します）
- フォルダの `{datetime}` は全台で同じ日時になります。`{host}` を使うと台ごとに変えられます（例: `\\{host}\Deploy$\{date}`）
- 一部の台だけ失敗したら、［転送開始］を押し直すと失敗した台にだけ送り直します
- ログオンが必要な台が複数あるときは、1 台目でログオンするときに「ほかの台にも同じアカウントで接続する」を選べます（`SV-APP01\Administrator` は台ごとに `SV-APP02\Administrator` のように読み替えます）
- 台の組み合わせは 1 件の履歴として残るので、2 回目からは ▾ で選ぶだけです

## コマンドラインから使う

`FileTransfer.bat`（インストール先は `%LOCALAPPDATA%\Programs\FileTransfer`）に引数を付けると、画面を出さずに転送します。バッチファイルやタスク スケジューラから呼べます。

```bash
FileTransfer.bat -Destination SV-APP01,SV-APP02 -Folder C:\Work\{datetime} \\fs01\patches\2026-10\*.msu
```

```bash
FileTransfer.bat -Destination このPC -Folder D:\Transfer\{date} \\fs01\release\app\setup.exe
```

| 引数 | 内容 |
|------|------|
| `-Destination` | 送り先。ホスト名（カンマ区切りで複数可）または `このPC` |
| `-Folder` | 送り先のフォルダ（画面のフォルダ欄と同じ書き方） |
| 送るファイル | 末尾に並べる（`*` `?` 可、スペースを含むときは `"` で囲む） |
| `-Credential <ユーザー名>` | ログオンが必要なサーバーに、このアカウントで接続する（パスワードは起動時に聞かれる） |
| `-SaveCredential` | そのアカウントを資格情報マネージャーに保存する |
| `-KeepLocalCopy` | 共有のファイルを、この PC にもコピーして残す |
| `-WhatIf` | 送り先と robocopy のコマンドを表示するだけで、転送しない |

- 終了コード: `0` 成功 / `1` 転送に失敗（一部の台だけ失敗した場合も含む）/ `2` 指定の誤り・接続できない・ログオンが必要
- 転送を始める前に全台の接続を確認し、1 台でも問題があればどこにも送らずに終わります（終了コード 2）
- 画面で保存した資格情報がそのまま使われます。ログは画面からの転送と同じファイルに残ります

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

- `Run-Tests.ps1`: パス解決、実行計画、robocopy の出力解析、実際の転送、複数台への配布、中止、コマンドライン実行などの自動テスト
- `Render-Screens.ps1`: アプリを画面外に表示して操作し、各状態の画面を PNG に保存します（自分自身の管理共有を `PC名` と `127.0.0.1` の 2 台に見立てた配布も行います）
- `.ps1` / `.psm1` は **BOM 付き UTF-8** で保存してください（Windows PowerShell 5.1 は BOM なしの UTF-8 を Shift-JIS として読みます）。`.cs` と `.bat` は ASCII のみにしてください
- 設計書: [docs/design.md](docs/design.md)、UI モック: [docs/ui-mock.html](docs/ui-mock.html)
