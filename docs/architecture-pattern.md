# PowerShell + WPF 業務ツールの構成パターン

FileTransfer で使っている「install.bat をダブルクリックするだけで導入でき、exe から UI が開き、裏では PowerShell が処理する」という構成をまとめたものです。ほかの CLI 業務ツールに UI を付けるときの雛形として使ってください。

- 対象: Windows 10 / 11（Windows PowerShell 5.1 と .NET Framework 4.x は OS に標準搭載）
- 追加で入れるもの: なし（Python・Node.js・.NET SDK・管理者権限、どれも不要）

---

## 1. 全体像

```
配布フォルダ（zip や共有フォルダで配る）
 ├─ install.bat ───────┐ ダブルクリック
 │                      ▼
 │              tools\Install.ps1
 │               ① %LOCALAPPDATA%\Programs\<App> にファイルをコピー
 │               ② csc.exe（OS 標準）で launcher\Launcher.cs → <App>.exe をビルド
 │               ③ デスクトップとスタートメニューにショートカットを作る
 │
 └─ （開発中は <App>.bat を直接ダブルクリックしても起動できる）

ユーザーがショートカットを開く
   <App>.exe（ランチャー。中身は 40 行ほど）
      └─ powershell.exe -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File <App>.ps1
            ├─ lib\*.cs  → Add-Type でコンパイル（DLL をキャッシュ）
            ├─ lib\*.psm1 → 業務ロジック（GUI と CLI で共用）
            ├─ ui\*.xaml → XamlReader で読み込んで WPF の画面を表示
            └─ 時間のかかる処理 → Runspace プールで裏で実行し、UI スレッドで結果を受け取る
```

ポイントは次の 3 つです。

1. **exe はただの起動役**。ロジックはすべて `.ps1` / `.psm1` にあり、テキストのまま読める・直せる。
2. **exe は配布しない**。各 PC の install 時に OS 標準の C# コンパイラでビルドする。署名なしバイナリの配布や、ウイルス対策ソフト・SmartScreen の問題を避けられる。
3. **1 本のスクリプトが GUI と CLI の両方になる**。引数なしなら画面、引数ありならコマンドラインとして動き、ロジックは同じモジュールを使う。

---

## 2. フォルダ構成

```
<App>\
├─ install.bat              導入・更新・削除の入口（ASCII のみ）
├─ <App>.bat                exe を使わない起動・CLI 実行の入口（ASCII のみ）
├─ <App>.ps1                本体（起動処理・画面のイベント処理）
├─ <App>.ico                アイコン（exe・ウィンドウ・ショートカット共通）
├─ settings.default.json    配布側の既定設定（組織ごとに書き換える）
├─ launcher\Launcher.cs     exe のソース（ASCII のみ）
├─ lib\
│   ├─ *.psm1               業務ロジック（UI に依存しない）
│   ├─ Cli.psm1             コマンドライン実行
│   ├─ Config.psm1          設定と履歴
│   ├─ Log.psm1             ログ
│   ├─ Update.psm1          更新の確認（コピーするファイルの一覧もここ）
│   └─ Native.cs, Models.cs Win32 API 呼び出し・画面にバインドするクラス
├─ ui\
│   ├─ Styles.xaml          共通スタイル（Application.Resources に入れる）
│   └─ MainWindow.xaml ほか 画面ごとの XAML
├─ tools\
│   ├─ Install.ps1          インストール処理の本体
│   ├─ Build-Launcher.ps1   exe のビルド
│   └─ New-Icon.ps1         アイコン生成（開発者だけが使う）
└─ tests\
    ├─ Run-Tests.ps1        ロジックの自動テスト（Pester 不要）
    └─ Render-Screens.ps1   画面を画面外に出して操作・PNG 保存する結合テスト
```

---

## 3. 各部品の設計

### 3.1 install.bat — 入口を「ダブルクリック 1 回」にする

```bat
@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Install.ps1" %*
if errorlevel 1 pause
```

- `.ps1` はダブルクリックで実行できず、実行ポリシーにも止められる。`.bat` から `-ExecutionPolicy Bypass` 付きで呼ぶことで、どちらも回避する。
- `powershell.exe` はフルパスで指定する（PATH や pwsh 7 に左右されないように）。
- 失敗したときだけ `pause` してエラーを読めるようにする。成功時はすぐ閉じる。
- `%*` で引数を渡し、`install.bat -Uninstall` で削除もできるようにする。
- **ASCII のみで書く**（cmd は UTF-8 の .bat を正しく読めないことがある）。日本語のメッセージは Install.ps1 側に書く。

### 3.2 tools\Install.ps1 — ユーザー単位でインストールする

| 処理 | 内容 |
|------|------|
| 置き場所 | `%LOCALAPPDATA%\Programs\<App>`（ユーザー単位なので管理者権限が不要） |
| 起動中チェック | 実行中なら止める（`MainWindowTitle` で判定）。ファイルが使用中で上書きに失敗するのを防ぐ |
| コピー | `lib` `ui` などのフォルダは**一度消してからコピー**する。名前を変えたり削除したりした古いファイルが残らないように |
| exe のビルド | `Build-Launcher.ps1 -OutputDirectory <インストール先>` |
| ビルド失敗時 | 警告だけ出し、ショートカットの先を `powershell.exe -WindowStyle Hidden -File <App>.ps1` にする（起動時にコンソールが一瞬見えるだけで、動作はする） |
| ショートカット | `WScript.Shell` の COM で `.lnk` を作る（デスクトップとスタートメニュー）。アイコンと作業フォルダも設定する |
| 更新 | もう一度 install.bat を実行するだけ（上書き）。起動時の自動確認もある（3.10） |
| 更新確認用の記録 | インストール先に `install.json`（コピー元のパスと、コピーしたファイル一式の SHA-256）を書く |
| 削除 | `-Uninstall` でプログラムとショートカットを消す。ユーザー設定（`%APPDATA%\<App>`）は残す |

> **注意:** ショートカットが指しているのはインストール先のコピーです。リポジトリでコードを直しても、更新するまで反映されません（次回起動時に更新を勧められます。3.10）。開発中は `<App>.bat` で直接起動します。

### 3.3 launcher\Launcher.cs と Build-Launcher.ps1 — コンソールを出さずに起動する

`powershell.exe -WindowStyle Hidden` だけだと、黒いウィンドウが一瞬見えます。既定のターミナルが Windows Terminal の環境では、ウィンドウが隠れないこともあります。これを避けるため、`/target:winexe`（コンソールを持たない exe）の小さな C# ランチャーから PowerShell を起動します。

ランチャーがすること:

1. 自分と同じフォルダの `<App>.ps1` を探す（`AppDomain.CurrentDomain.BaseDirectory`）
2. `powershell.exe -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "<App>.ps1"` を `CreateNoWindow = true` で起動する
3. 8 秒以内に終了コード ≠ 0 で終わったら（実行ポリシー・ファイルの破損など）、ログの場所をメッセージボックスで知らせる

ビルドは OS 標準の .NET Framework 4.x に付いている `csc.exe` で行います。

```powershell
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
& $csc /nologo /target:winexe /optimize+ /out:<App>.exe /reference:System.Windows.Forms.dll /win32icon:<App>.ico launcher\Launcher.cs
```

- `-STA` は必須です（WPF は STA スレッドでしか動かない）。
- **Launcher.cs は ASCII のみで書きます**（csc の既定の文字コードに左右されないように）。日本語は `\uXXXX` で書きます。
- exe は**ロジックを持たない**ので、アプリの更新で exe を作り直す必要はありません。exe 単体を配っても動きません（同じフォルダに `.ps1` 一式が必要です）。

### 3.4 <App>.ps1 — 1 本で GUI と CLI を兼ねる

パラメーターセットで、起動モードを切り替えます。

```powershell
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Gui')]
param(
    [Parameter(ParameterSetName = 'Cli')][string]$Destination,
    [Parameter(ParameterSetName = 'Cli', Position = 0, ValueFromRemainingArguments)][string[]]$Source,
    # ...
    [Parameter(ParameterSetName = 'Gui')][switch]$NoShow   # テストから読み込むとき用
)
$script:IsCli = $PSCmdlet.ParameterSetName -eq 'Cli'
```

起動の流れ:

1. `trap` で起動時の例外を受け止め、`%LOCALAPPDATA%\<App>\logs\startup-error.log` に書く。CLI なら終了コード 2、GUI ならメッセージボックスを出して終了コード 1 を返す（ランチャーはこの終了コードを見る）。
2. `lib\*.cs` を読み込む（3.6）。
3. `lib\*.psm1` を `Import-Module` する。
4. 設定を読む（3.8）。
5. **CLI モードなら** `Invoke-<App>Cli` を呼んで `exit $code`。WPF は読み込まない。
6. **GUI モードなら** WPF を読み込み、XAML から画面を作り、イベントを登録して `ShowDialog()` する。

`<App>.bat` は、引数がなければ `start` で GUI を非同期に起動し、引数があれば CLI として同期実行して終了コードを返します。こうすると、バッチやタスク スケジューラからも同じツールを呼べます。

### 3.5 画面（WPF + XAML）

- 画面は `ui\*.xaml` に書き、`[System.Windows.Markup.XamlReader]::Load()` で読み込む。`x:Class` やコードビハインドは使えないので、イベントは PowerShell 側で `Add_Click({ ... })` のように登録する。
- 名前付きの要素は `FindName()` でまとめて取り出し、`$ui.StartButton` のようにハッシュテーブルで扱う。
- 共通スタイルは `Styles.xaml` にまとめて `Application.Resources.MergedDictionaries` に追加し、各画面からは `StaticResource` で参照する。そのため、先に `[System.Windows.Application]` を作り、`ShutdownMode = OnExplicitShutdown` にしておく。
- 一覧などのバインド先は `ObservableCollection[<C# クラス>]` にする。C# のクラスで `INotifyPropertyChanged` を実装すると、値の変化が画面に反映される。
- 画面表示後の想定外の例外は `Application.DispatcherUnhandledException` で受けてログに書き、`Handled = $true` にしてアプリを落とさない。
- ウィンドウの位置・大きさや最後の入力値は `Closing` で設定に保存し、次回起動時に復元する（画面外にはみ出す位置は無視する）。

### 3.6 C# の型（Native.cs / Models.cs）— ハッシュ別に DLL をキャッシュする

Win32 API（P/Invoke）や、バインド用のクラスが必要なときは C# で書いて `Add-Type` します。ただ、毎回コンパイルすると起動が目に見えて遅くなります。そこで、ソースの SHA-256 をファイル名に入れた DLL を `%LOCALAPPDATA%\<App>\bin` にキャッシュします。

```powershell
$dll = Join-Path $binDir "<App>.Types.$hash.dll"
if (-not (Test-Path $dll)) { Add-Type -Path $sources -OutputAssembly $dll -OutputType Library }
Add-Type -Path $dll
# ハッシュの違う古い DLL は消す（使用中で消せなければ無視）
```

ソースを変えればハッシュが変わり、自動で作り直されます。

### 3.7 バックグラウンド処理 — Runspace プール + DispatcherTimer

WPF の UI スレッドで時間のかかる処理（ネットワーク・ファイルコピーなど）を実行すると、画面が固まります。そこで、次の仕組みを使います。

```
UI スレッド                                 Runspace プール（1〜16 本）
 Start-Job -Script '...' -OnComplete {...}  ──BeginInvoke──▶ 処理（lib の関数を呼ぶ）
 DispatcherTimer（120ms ごと）
   └─ Update-Jobs: IsCompleted を確認 ◀─────────────── 完了
        └─ EndInvoke → OnComplete($value, $err, $context) を UI スレッドで実行
```

- プールは `InitialSessionState` に `lib\*.psm1` と `ExecutionPolicy = Bypass` を設定して作る。各 Runspace で、同じ関数がすぐ使える。
- 結果を受け取るのは常に UI スレッド（タイマーの Tick）なので、`OnComplete` の中で画面を自由に触れる（`Dispatcher.Invoke` が不要）。
- `TimeoutMs` を付けると、期限を過ぎた時点で `TimeoutException` を `OnComplete` に渡す。止められない処理（ネットワーク接続など）は裏で終わるまで待ち、遅れて終わったら `OnLate` で後始末する。
- 進捗は、ジョブと UI で共有する同期済みハッシュテーブルや C# のクラスに書き込み、同じタイマーで読んで画面に反映する。
- 終了時に、応答のない処理が裏に残っていると PowerShell が終わらないことがある。その場合は `[Environment]::Exit(0)` で終了する。

### 3.8 設定・履歴・資格情報・ログの置き場所

| 種類 | 場所 | 備考 |
|------|------|------|
| 既定値 | スクリプト内の組み込み値 < 配布フォルダの `settings.default.json` | 組織ごとの既定は json を書き換えて配る |
| ユーザー設定・履歴 | `%APPDATA%\<App>\settings.json` | アンインストールしても残す。上の 2 つに重ねて読む |
| パスワード | Windows 資格情報マネージャー（`CredWrite` / `CredRead`） | 設定ファイルやログに平文で残さない |
| ログ | `%LOCALAPPDATA%\<App>\logs\yyyyMMdd.log` | 古いものは起動時に保持日数で削除 |
| キャッシュ | `%LOCALAPPDATA%\<App>\bin` | コンパイル済み DLL |

テストのために、設定とログの場所は環境変数（例: `FILETRANSFER_CONFIG`、`FILETRANSFER_LOGDIR`）で差し替えられるようにしておきます。

### 3.9 テスト

- **ロジック**: `tests\Run-Tests.ps1` で `lib\*.psm1` を直接読み込み、自前の `Assert-Equal` で確認する（Pester が入っていない PC でも動く）。
- **画面**: `tests\Render-Screens.ps1` で `<App>.ps1 -NoShow` をドットソースし、画面を表示せずに初期化だけ行う。そのうえで画面外にウィンドウを出して操作し、状態ごとに PNG を保存して見た目を確認する。

### 3.10 更新の確認（lib\Update.psm1）

配布元のフォルダを新しくするだけで、各利用者が次の起動時に更新できるようにします。

```
install.bat（初回）
  └─ Install.ps1: コピーしたファイル一式の SHA-256 とコピー元のパスを install.json に書く

アプリの起動時（GUI のみ。裏のジョブで実行し、15 秒で打ち切る）
  └─ Test-FtUpdate: install.json のコピー元で同じハッシュを計算して比べる
       ├─ install.json が無い（リポジトリから直接起動） / コピー元に届かない / 同じ → 何もしない
       └─ 違う → 「新しいバージョンがあります。更新します」
             └─［OK］: コピー元の Install.ps1 -WaitProcessId <自分の PID> -Restart を隠して起動し、ウィンドウを閉じる
                   Install.ps1: アプリとランチャー（exe）の終了を待つ → 上書き → exe を作り直す → 起動し直す
                                失敗したらメッセージボックスで知らせる
```

- ハッシュの対象は「インストール時にコピーするもの」と同じ一覧（`Get-FtAppContents`）。一覧を 1 か所に置き、Install.ps1 と更新の確認の両方で使う。README など、コピーしないファイルを変えても更新扱いにならない。
- git のコミットハッシュは使わない（コミット前の変更を検知できず、利用者の PC に git が無いことも多いため）。
- 更新のインストーラーは**コピー元の** Install.ps1 を使う。インストール処理自体が新しくなっていても正しく更新できる。
- ランチャーの exe が終わる前に作り直すと、使用中で上書きに失敗する。そのため、アプリの PID だけでなく、インストール先の exe の終了も待つ。

---

## 4. 他の CLI ツールに適用する手順

1. **ロジックを関数に切り出す**: 既存の CLI スクリプトの処理を `lib\<Name>.psm1` の関数にする。`Write-Host` や `Read-Host` は使わず、引数で受け取って戻り値やオブジェクトで返す（GUI と CLI で共用するため）。
2. **CLI の入口を作る**: `lib\Cli.psm1` に `Invoke-<App>Cli` を作り、従来どおりのコマンドライン実行と終了コードを保つ。
3. **画面を作る**: `ui\MainWindow.xaml` を書き、`<App>.ps1` でイベントを登録する。時間のかかる処理は必ず 3.7 のジョブ経由で呼ぶ。
4. **雛形をコピーする**: `install.bat` `<App>.bat` `tools\Install.ps1` `tools\Build-Launcher.ps1` `launcher\Launcher.cs` をコピーし、アプリ名（フォルダ名・exe 名・ウィンドウタイトル・ログ フォルダ名）を置き換える。
5. **アイコンを作る**: `tools\New-Icon.ps1` を参考に `.ico` を作る（任意。無くても動く）。
6. **確認する**: 別のユーザーまたは別の PC で、配布フォルダから install.bat → ショートカットから起動 → `install.bat -Uninstall` まで試す。

### アプリ名を置き換える箇所（チェックリスト）

- [ ] `install.bat`（呼び出すスクリプトのパス）
- [ ] `tools\Install.ps1`（インストール先、ショートカット名、起動中チェックのウィンドウタイトル、コピーするファイル名）
- [ ] `tools\Build-Launcher.ps1`（exe 名・ico 名）
- [ ] `launcher\Launcher.cs`（起動する `.ps1` 名、ログ フォルダ名、エラーメッセージ）
- [ ] `<App>.ps1`（ログ・設定・キャッシュのフォルダ名）
- [ ] `ui\MainWindow.xaml` の `Title`（起動中チェックと一致させる）

---

## 5. 守るべき約束事・つまずきやすい点

| 項目 | 内容 |
|------|------|
| PowerShell のバージョン | **Windows PowerShell 5.1** を前提にする（`#Requires -Version 5.1`）。pwsh 7 は標準搭載ではない |
| 文字コード | `.ps1` / `.psm1` は **UTF-8（BOM 付き）**。BOM が無いと 5.1 は日本語を Shift-JIS として読み、文字化けや構文エラーになる。`.bat` と `Launcher.cs` は ASCII のみ |
| STA | WPF には `-STA` が必要（ランチャー・`.bat` の両方で指定する） |
| 実行ポリシー | 起動はすべて `-ExecutionPolicy Bypass` 付きにする。ユーザーやPCの設定は変更しない |
| ダウンロードした zip | インターネットから取得した zip を展開すると、install.bat の実行時にセキュリティ警告が出ることがある。展開前に zip のプロパティで「ブロックの解除」をしてもらうか、社内の共有フォルダから配る |
| 更新の反映 | 動くのはインストール先のコピー。コードを直したら install.bat を再実行する |
| 起動中の更新 | 実行中はファイルが使われているため、Install.ps1 で起動中を検出して止める |
| UI スレッド | 時間のかかる処理を UI スレッドで直接呼ばない。Runspace の中から画面を触らない（結果は OnComplete で受け取る） |
| exe の役割 | exe にロジックを入れない。入れると、更新のたびにビルドが必要になり、「テキストのまま直せる」利点がなくなる |
| 管理者権限 | 要求しない設計にする（`%LOCALAPPDATA%` と `%APPDATA%` だけに書く） |

---

## 6. 向き・不向き

**向いているもの**
- 社内の数人〜数百人に配る業務ツール（ファイル操作・サーバー操作・定型作業）
- すでに PowerShell で書いた CLI ツールに、画面を足したいとき
- ソフトのインストールやストアからの配布が制限された環境

**向いていないもの**
- 凝ったアニメーションや大量データの高速描画が必要な画面（WPF は使えるが、PowerShell からの操作は遅い）
- Windows 以外でも動かしたいツール
- 改ざん防止や署名が求められる配布（`.ps1` が平文で置かれるため）
