# fmc

自然言語で書いた依頼を zsh のコマンドに変換する、Mac 用のシェル関数です。
変換には Apple Foundation Models の CLI (`fm`) を使い、既定では処理がすべてオンデバイスで完結します。
設定すれば、ショートカット経由で Apple のクラウドのモデルを使うこともできます (より正確ですが、依頼文がサーバーに送られます)。

```console
$ fmc "3日以内に変更された.pyファイルを検索"
✨ コマンドを生成中...

✅ 生成されたコマンド:
   find . -type f -name "*.py" -mtime -3

$ find . -type f -name "*.py" -mtime -3█    ← プロンプトに入るので、確認・編集してから Enter
```

生成されたコマンドはすぐには実行されず、zsh の入力行に置かれます。内容を確認し、必要なら編集してから Enter で実行してください。

## 特徴

- **オンデバイス (既定)**: 依頼の内容を外部サービスに送りません。クラウドのモデルを使うのは、`-c` か `FMC_BACKEND=cloud` を指定したときだけです。
- **macOS 向け**: BSD 版のコマンド (`sed -i ''`、`date -v-1d`、`stat -f` など) を使うように誘導し、Linux 専用コマンドは検証で弾きます。
- **生成後の検証と再生成**: 構文、コマンドやフラグの実在、依頼との整合性をチェックし、問題があれば理由を添えて作り直させます。
- **危険なコマンドの抑止**: `rm -rf ~` のようなコマンドはブロックします。`-y` で即実行する場合も、削除などの操作は実行前に確認します。

## 必要なもの

- `fm` コマンドが使える macOS (macOS 26 以降、Apple Intelligence が有効)
- zsh

`fm` が使えるかは次のコマンドで確認できます。

```zsh
fm available
```

## インストール

### zsh プラグインマネージャを使う場合

`fmc.plugin.zsh` を提供しているため、各種 zsh プラグインマネージャでそのまま読み込めます。

#### Oh My Zsh
```zsh
git clone https://github.com/jhorology/fmc.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/fmc
```
`~/.zshrc` の `plugins=(...)` に `fmc` を追加します。
```zsh
plugins=(
  # ...
  fmc
)
```

#### Zinit
```zsh
zinit light jhorology/fmc
```

#### Antidote
`~/.zsh_plugins.txt` に追記します。
```zsh
jhorology/fmc
```

### 手動でインストールする場合

```zsh
git clone https://github.com/jhorology/fmc.git ~/fmc
echo 'source ~/fmc/fmc.plugin.zsh' >> ~/.zshrc
source ~/.zshrc
```

例文バンク (`examples.tsv`) と検証ルール (`rules.tsv`) はスクリプトと同じディレクトリから自動解決されるため、リポジトリをそのままクローンして読み込むだけで使えます。

## 使い方

### 1. ショートカットから使う (おすすめ)

プロンプトで **`Ctrl+O`** を押すと、Atuin 風のポップアップ入力が開きます。

```text
╭─ ✨ fmc (自然言語からコマンド生成 / Esc: 取消)
╰─▶ 依頼: 3日以内に変更された.pyファイルを検索
```

1. 自然言語で依頼を入力して **Enter** を押します (中断したいときは **Esc** または **Ctrl+C**)。
2. 生成されたコマンドがプロンプトの入力行に直接展開されます。
3. 内容を確認・編集し、**Enter** で実行します。

> [!TIP]
> - プロンプトにすでに依頼テキストを入力した状態で `Ctrl+O` を押すと、そのテキストが初期入力として引き継がれます。
> - キーバインドを変更したい場合は後述の `FMC_KEYBIND`、アイコンを変更したい場合は `FMC_ICON` を設定してください。

### 2. コマンドから使う

```zsh
fmc "ポート8080を使っているプロセスを殺す"
fmc "git logを著者別にランキング"
fmc "list the 10 largest files in this directory"   # 英語でも可
```

| オプション | 説明 |
|---|---|
| (なし) | コマンドを生成して zsh の入力行に置く |
| `-y`, `--yes` | 生成したコマンドをすぐ実行する。削除・移動・`sudo` などの操作や、検証で問題が残った場合は実行前に確認する |
| `-p`, `--print` | コマンドだけを標準出力に出す (スクリプトやパイプ用)。検証の問題が残った場合は、警告を標準エラーに出して終了コード 2 を返す |
| `-v`, `--verbose` | 参照した例文、自動修正、検証と再生成の過程を表示する |
| `-c`, `--cloud` | クラウドのモデル (ショートカット経由) で生成する。後述の設定が必要 |
| `-l`, `--local` | オンデバイスのモデル (`fm`) で生成する (`FMC_BACKEND=cloud` のときの一時的な切り替え用) |
| `-H`, `--history` | 生成履歴を表示する |
| `--clear-history` | 生成履歴を削除する |
| `-h`, `--help` | ヘルプを表示する |

ターミナル操作ではない入力 (「こんにちは」など) には、コマンドを生成せずにその旨を表示します。

### 環境変数

| 変数 | 既定値 | 説明 |
|---|---|---|
| `FMC_KEYBIND` | `^O` | ポップアップ入力を開くショートカットキー (`""` で無効化) |
| `FMC_ICON` | `✨` | プロンプトや生成状況に表示するアイコン (`🪄` や `⌘` などに変更可能) |
| `FMC_HISTORY_FILE` | `~/.fmc_history` | 履歴ファイルのパス |
| `FMC_MAX_HISTORY` | `100` | 履歴として残す最大行数 |
| `FMC_MAX_RETRIES` | `3` | 検証で問題が見つかったときの再生成回数 |
| `FMC_NUM_EXAMPLES` | `8` | few-shot としてモデルに渡す例文の最大数 |
| `FMC_EXAMPLES_FILE` | `fmc.zsh` と同じ場所の `examples.tsv` | 例文バンク |
| `FMC_RULES_FILE` | `fmc.zsh` と同じ場所の `rules.tsv` | 意味的な検証ルール |
| `FMC_BACKEND` | `local` | 生成に使うモデル。`local` (オンデバイス) か `cloud` (ショートカット経由) |
| `FMC_SHORTCUT_NAME` | `ask-cloud-model` | `cloud` で呼ぶショートカットの名前 |
| `FMC_CLOUD_NUM_EXAMPLES` | `0` | `cloud` のときに渡す例文の数 |
| `FMC_STATS_FILE` | (なし) | 設定すると、生成回数・残った問題数・使ったモデルを1行ずつ追記する (評価用) |

### クラウドのモデルを使う

ショートカットアプリの「Use Model」アクションを経由して、Apple のクラウドのモデル (Private Cloud Compute) でコマンドを生成できます。オンデバイスのモデルより大幅に正確ですが (後述の評価を参照)、**依頼文が Apple のサーバーに送られます**。既定はオンデバイスのままです。

1. ショートカットアプリで `ask-cloud-model` という名前のショートカットを作り、次のようにします (英語 UI の表記)。
   - Details で **Use as Quick Action** などをオンにし、**Receive [Text] input** にする
   - **Use Model** アクションを追加し、モデルを **Cloud**、プロンプトを **Shortcut Input** だけにする
   - **Stop and Output** で **Use Model** の **Response** を返す
2. 動作を確認します。

   ```zsh
   print -r -- "say hi" | shortcuts run ask-cloud-model --input-path - --output-path - --output-type public.plain-text
   ```

3. `fmc -c "依頼"` で使うか、`FMC_BACKEND=cloud` を設定します。

クラウドのモデルには利用上限があります。上限の値や解除までの時間は公開されていませんが、評価で1時間ほどの間に約130回呼んだところで「You have reached the usage limit for this model.」と断られるようになりました。普段使いで上限に届くことはまず無いはずですが、評価のように続けて呼ぶときは注意してください。失敗した場合は理由を表示し、オンデバイスのモデルに切り替えて生成を続けます。

クラウドのモデルは例文を渡すとかえって精度が下がったため、既定では例文を渡しません (`FMC_CLOUD_NUM_EXAMPLES`)。検証・自動修正・再生成・危険コマンドのブロックは、オンデバイスのときと同じようにかかります。

### (コラム) ショートカットの「On-Device」モデルとの違い

ショートカットアプリの「Use Model」アクションには「On-Device」の選択肢もありますが、`fmc` ではオンデバイスの生成にショートカットを使わず、`fm` コマンドを直接呼んでいます。macOS の内部ログ (`log show`) や推論プロセスの解析、実際の生成テストで比較した結果は次のとおりです。

| 項目 | `fm` コマンド (`system`) | ショートカットの「On-Device」 |
|---|---|---|
| **ベースモデル** | `com.apple.fm.language.instruct_3b` (3B) | `com.apple.fm.language.instruct_3b` (3B) *(同一)* |
| **推論エンジン** | `TGOnDeviceInferenceProviderService` (ANE) | `TGOnDeviceInferenceProviderService` (ANE) *(同一)* |
| **ドラフト / 安全モデル** | `instruct_300m.base` / `safety` | `instruct_300m.base` / `safety` *(同一)* |
| **適用アダプタ** | `...instruct_3b.fm_api_generic` | `...instruct_3b.shortcuts_ask_afm_action_3b` |
| **内部 UseCase ID** | `FMFramework.onDevice.Public` | `com.apple.Shortcuts.AskAFMAction3B` |
| **指示 (instructions)** | `--instructions` で独立して指定可能 | プロンプト内に連結 (ショートカット用ペルソナが注入) |
| **自己認識の回答** | `...created by Apple.` | `...developed by Apple, built into Shortcuts.` |
| **指示への応答傾向** | 指示通りコマンドのみを出力しやすい | アシスタントとして聞き返しやすい (単文指示のときなど) |
| **生成速度 (1回)** | **約 0.3〜0.5 秒** | **約 0.6〜0.9 秒** (CLI・XPC のオーバーヘッドあり) |

- **基盤モデルと知識は同一**: どちらも同一の 3B モデルで動いており、例えば計算問題で全く同じ間違いを出力する (`123 * 45` に対して共に `5545` と誤答) など、内部の重みは共通です。
- **アダプタとペルソナの差**: ショートカット版はショートカット内の対話型アシスタントとしての振る舞いが組み込まれているため、短い依頼に対して「Please provide more details...」のように聞き返してしまう傾向があります。
- **結論**: オンデバイスモデルを使う場合は、オーバーヘッドがなく指示を綺麗に分離できる `fm` コマンドの直接呼び出し (`FMC_BACKEND=local`) が最も高速で安定しています。

## 仕組み

オンデバイスのモデルは小さく、単純に頼むだけでは Linux のコマンドや存在しないフラグを出しがちです。
そこで、モデルの前後に次の処理を挟んでいます。

1. **例文の検索**: 例文バンク `examples.tsv` (macOS で動く約140件) から、依頼に近いものを選んでモデルに渡します。日本語はカタカナ語・漢字語の単位、英語は単語単位で比べ、「削除 / 消す / remove」のような言い換えも同じ語として扱います。
2. **生成**: 短い instructions と選んだ例文を付けて、`fm respond` で1行のコマンドを生成します。クラウドのモデルを使う場合は、instructions と依頼文をショートカットに渡します (例文は既定で渡しません)。
3. **自動修正**: `find -o` の括弧、`sed -i ''`、`lsof -i :PORT`、`open -a "Google Chrome"` など、定型的な誤りは直接直します。
4. **検証**:
   - zsh の構文
   - コマンドが実在するか (`ip` なら `ipconfig` を使うように、などの代替案付き)
   - 使っているフラグが man ページに載っているか (macOS 標準コマンドのみ)
   - GNU 版にしかないオプションを使っていないか
   - 依頼にある数値・ファイル名・場所がコマンドに入っているか
   - macOS の知識不足による意味的な誤り (`rules.tsv` に1行1ルールで記述。例: 過去の日付なのに `date -v+3d`、ゴミ箱の場所)
   - 頼まれていないパッケージのインストールや、ホーム・ルートへの対象の拡大をしていないか
   - 危険なコマンドではないか
5. **再生成**: 問題があれば理由を添えて作り直させます (既定で最大3回)。解消しなかった場合は、問題点を警告として表示したうえで最も問題の少ない候補を出します。

man ページから読み取ったフラグ一覧は `~/.cache/fmc/manflags/` にキャッシュします (`XDG_CACHE_HOME` が設定されていればその下)。

## 評価

モデルを使わない回帰テストと、正解パターン付きの評価セットがあります。

```zsh
zsh check.zsh                                             # 検証・自動修正の回帰テスト (数秒)
FMC_HISTORY_FILE=/dev/null zsh score.zsh fmc.zsh eval.tsv
FMC_HISTORY_FILE=/dev/null zsh score.zsh fmc.zsh eval2.tsv
FMC_HISTORY_FILE=/dev/null zsh score.zsh fmc.zsh eval3.tsv
```

`check.zsh` は次のことを確かめ、失敗があれば終了コード 1 を返します。

- 例文バンクの正解コマンドに対して、自動修正が何も書き換えず、検証が何も指摘しないこと
- `rules.tsv` の正規表現がすべて正しいこと
- 個別のテストケース (誤りを指摘できるか、正しいものを通すか、危険なコマンドをブロックするか)
- 例文バンクと評価セットに同じ問題が無いこと

| 評価セット | 用途 | 現在 |
|---|---|---|
| `eval.tsv` (40問) | 調整用 | 37/40 |
| `eval2.tsv` (30問) | 調整用 | 27/30 |
| `eval3.tsv` (30問) | 調整に使わない確認用 | 13/30 (クラウド: 28/30) |

クラウドのモデルで測るときは `FMC_BACKEND=cloud zsh score.zsh fmc.zsh eval3.tsv` のように実行します (利用上限に注意)。

各行は「リクエスト<TAB>正解コマンドの正規表現 (ERE)」の形式です。`score.zsh` は点数のほかに、平均生成回数と、検証の問題が残ったまま出力された件数も表示します。問題ごとの結果や採点の限界は [fmc_eval_report.md](fmc_eval_report.md) にまとめています。

汎化性能を表すのは `eval3.tsv` の点数だけです。`eval3.tsv` の問題やそれに近い依頼を例文バンクや `rules.tsv` に入れると確認用として機能しなくなるので、入れないでください。eval3 の結果を見て調整したくなったら、先に新しい確認用セットを作ってください。

モデルは入力の細部 (例文の並びや空行など) で出力が変わります。instructions、例文バンク、ルールを変更したら、`check.zsh` とすべての評価セットで測り直してください。

## 注意と制限

- 生成されたコマンドは、実行前に必ず内容を確認してください。検証で拾えるのは形式的な誤りだけで、意味の取り違え (「1週間前」を未来の日付にする、など) は残ります。
- macOS 固有の場所や機能 (ゴミ箱の `~/.Trash` など) は、例文に無いと正しく扱えないことがあります。
- `git` や `docker` などサブコマンドを持つツールのフラグは、man ページとの照合をしていません。
- 1回の生成には 0.5〜1 秒ほどかかり、再生成が入るとその分長くなります。

## ファイル構成

| ファイル | 内容 |
|---|---|
| `fmc.zsh` | 本体 (`source` して使う) |
| `examples.tsv` | 例文バンク (リクエスト<TAB>コマンド) |
| `rules.tsv` | 意味的な検証ルール (書式はファイル先頭のコメントを参照) |
| `eval.tsv`, `eval2.tsv`, `eval3.tsv` | 評価セット |
| `score.zsh` | 採点スクリプト |
| `check.zsh` | モデルを使わない回帰テスト |
| `fmc_eval_report.md` | 評価レポート |
| `review_and_fixes.md` | レビューと修正の記録 |
