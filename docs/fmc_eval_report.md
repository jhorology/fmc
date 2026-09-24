# fmc 評価レポート

- 実施日: 2026-09-23
- 環境: macOS 27.0、`fm` (Apple Foundation Models CLI、オンデバイスの system モデル)
- 比較対象: 改善前 = コミット 841df99 の `fmc.zsh`、改善後 = 現在の `fmc.zsh` + `data/examples.tsv` + `data/rules.tsv`
- 評価セットの問題文は、コミット 841df99 で自動整形により入った空白 (「3 日」など) を取り除いた元の形に戻して測っています

## 結果

| 評価セット | 問題数 | 用途 | 改善前 | 改善後 | 平均生成回数 (改善後) | 警告付きの出力 (改善後) |
|---|---|---|---|---|---|---|
| `eval.tsv` | 40 | 調整用 | 40 | 37 | 1.20 | 0 |
| `eval2.tsv` | 30 | 調整用 | 29 | 27 | 1.47 | 2 |
| `eval3.tsv` | 30 | **確認用 (調整に不使用)** | 13 | 13 | 1.27 | 1 |

- `eval.tsv` と `eval2.tsv` の点数は汎化性能の指標になりません。改善前の 40/40 は、`eval.tsv` の問題 10 問を例文バンクにそのまま入れたことと、特定の問題向けの差し替え処理 (後述) によるものでした。`eval2.tsv` も、ほぼ同じ内容の例文や専用の検証ルールが追加されていたため、確認用としては使えなくなっています。
- 例文バンクに無い問題で作った `eval3.tsv` では、改善前も改善後も 13/30 (43%) でした。これが現時点の実力です。
- 改善後に `eval.tsv` / `eval2.tsv` の点数が下がったのは、評価問題のコピーと決め打ちの差し替えを取り除いたためです。
- 所要時間は 1 セット 20〜27 秒 (1 問あたり約 0.7〜0.9 秒)。

## クラウドのモデル (2026-09-24 追記)

ショートカットの「Use Model」(Cloud) を `FMC_BACKEND=cloud` で使った場合の `eval3.tsv` の結果です。

| 構成 | eval3 | 平均生成回数 |
|---|---|---|
| オンデバイス (`fmc` 既定) | 13/30 | 1.27 |
| クラウド、ショートカット単体 (例文・検証なし) | 27/30 | 1 |
| クラウド + `fmc` (例文 8 件) | 23/30 | 1.07 |
| クラウド + `fmc` (例文なし、`FMC_CLOUD_NUM_EXAMPLES=0`、現在の既定) | **28/30** | 1.10 |

- 例文を渡すとクラウドのモデルは例文に引きずられ、「差分を表示」「Wi-Fi をオフ」を NOT_A_COMMAND と答えるなど、かえって悪くなりました。このため、クラウドでは既定で例文を渡しません。
- 例文なしの 28/30 のうち、`ps -ax | wc -l` は正しい出力で採点側の漏れです。実際の誤りは「画面をロックする」の 1 問だけでした。
- ショートカット単体で出た `rm -rf carpeta` (「buildフォルダを削除」の誤り) は、`fmc` の検証を通すと `rm -rf build` になりました。
- いずれも 1 回ずつの測定です。クラウドのモデルは出力が毎回同じとは限りません。
- 約 130 回呼んだところで利用上限 (「You have reached the usage limit for this model.」) に達し、`eval.tsv` / `eval2.tsv` はクラウドで測れていません。

## 評価方法

- 各評価セットの行は「リクエスト<TAB>正解コマンドの正規表現 (ERE)[<TAB>NG の正規表現 (任意)]」の形式です。
- `fmc -p "<リクエスト>"` の出力が正規表現に一致すれば OK とします。3 列目の NG 正規表現にマッチした場合は OK としません (偽陽性の排除)。
- コマンドを出力せずに終了した場合 (NOT_A_COMMAND 判定、危険コマンドのブロック) は `NOT_A_COMMAND` として採点します。
- 平均生成回数と警告付きの件数は `FMC_STATS_FILE` で集計しています (改善前のコードには集計機能がないため空欄)。
- `eval3.tsv` は改善後のコードを見る前に作り、結果を見たあとの調整には使っていません。採点の正規表現を1か所だけ直しています (`lsof -i :9000 -t` という正しい出力を不合格にしていたため)。この修正は改善前・改善後の両方の採点に反映しています。

### 例文バンクと評価セットの重複チェック

`zsh tests/check.zsh` が、例文バンクと全評価セットの問題文を空白・大文字小文字を無視して突き合わせ、一致するものがあれば失敗にします。特徴語がほぼ同じ例文は警告として表示します。

### 採点の限界

正規表現はコマンドの一部しか見ていないので、OK でも実際には誤りのものがあります。逆に、正しいのに正規表現が想定していない書き方で NG になるものもあります。

## eval3.tsv (確認用、30 問)

| # | リクエスト | 改善前 | 改善後 | 改善後の出力 |
|---|---|---|---|---|
| 1 | 1時間以内に変更されたファイルを探す | NG | NG | `find . -type f -mtime -1` |
| 2 | 500MB以上のファイルを探す | OK | OK | `find . -type f -size +500M` |
| 3 | .jpgファイルを全部数える | NG | NG | `find . -type f -name "*.jpg" -exec wc -l {} +` |
| 4 | src以下の.tsファイルでimportを含む行を検索 | NG | NG | `grep -l "import" src/**/*.ts` |
| 5 | notes.mdの最後の30行を表示 | OK | OK | `tail -n 30 notes.md` |
| 6 | buildフォルダを削除 | OK | OK | `rm -r build` |
| 7 | data.jsonからidフィールドを取り出す | NG | NG | `grep -o 'id' data.json` |
| 8 | ポート9000を使っているプロセスのPIDを表示 | OK | OK | `lsof -i :9000 -t` |
| 9 | Terminalアプリを開く | OK | OK | `open -a Terminal` |
| 10 | 現在のgitコミットのハッシュを表示 | OK | OK | `git rev-parse HEAD` |
| 11 | mainブランチに切り替え | OK | OK | `git switch main` |
| 12 | gitで追跡されていないファイルを一覧 | OK | OK | `git ls-files --others` |
| 13 | photo.pngの画像の幅と高さを表示 | NG | NG | `stat -f '%t %s' photo.png` |
| 14 | 明日の日付を表示 | NG | NG | `date +%Y-%m-%d` |
| 15 | old.txtとnew.txtの違いを表示 | OK | OK | `diff old.txt new.txt` |
| 16 | users.csvの行数を表示 | OK | OK | `wc -l < users.csv` |
| 17 | log.txtに今日の日付を追記 | NG | NG | `echo "$(date +%Y-%m-%d)" >> log.txt` |
| 18 | 実行中のプロセス数を数える | NG | NG | `ps -Ao pid,status -C 'exec' \| wc -l` |
| 19 | Wi-Fiをオフにする | NG | NG | `networksetup -disabledevice wifi` |
| 20 | 画面をロックする | NG | NG | `osascript -e 'osascript -e "lock" -e "exit"'` |
| 21 | 音量をミュートにする | NG | NG | `osascript -e 'tell application "System Events" to mute the volume'` |
| 22 | Homebrewでインストール済みのパッケージを一覧 | OK | OK | `brew list` |
| 23 | .zshrcを再読み込み | NG | NG | `source .zshrc` |
| 24 | カレントディレクトリの.shファイルに実行権限を付ける | NG | NG | `chmod +x .sh` |
| 25 | main.cの中のTODOの数を数える | NG | NG | `grep -rl "TODO" main.c \| wc -l` |
| 26 | おすすめの映画を教えて | OK | OK | `NOT_A_COMMAND` |
| 27 | find files larger than 1GB in Downloads | OK | OK | `find ~/Downloads -type f -size +1G` |
| 28 | show disk usage of the Desktop folder | NG | NG | `du -sh Desktop/*` |
| 29 | kill the process named Slack | NG | NG | `kill -9 $(pgrep -f Slack)` |
| 30 | convert image.png to jpg | NG | NG | `convert image.png jpg --output image.jpg` |

17 は正規表現が `echo "$(date)" >> log.txt` を想定しておらず、実際には正しい出力です (採点側の漏れ)。ただし結果を見たあとで直すと確認用として弱くなるので、採点はそのままにしています。

### eval3 で見えた誤りの傾向

- **単位・量の取り違え**: 1時間を `-mtime -1` (1日) にする、「数える」を `wc -l` (行数) にする (3, 25)
- **macOS 固有の操作を知らない**: 画像の幅と高さ (`sips -g pixelWidth`)、画面ロック、ミュート、Wi-Fi のオフ (13, 19, 20, 21)
- **場所の解決**: `.zshrc` や `Desktop` をホーム (`~/`) ではなくカレントディレクトリとして扱う (23, 28)
- **glob の書き方**: `*.sh` を `.sh` と書く (24)
- **標準で入っていないコマンド**: `convert` (ImageMagick) (30)。評価した Mac には ImageMagick が入っているので検証を通りますが、標準の `sips` を使うべき場面です。しかも引数の形が ImageMagick の使い方として誤っています

これらを直すときは、eval3 の問題そのものではなく、同じ種類の別の依頼を例文やルールに加えてください。加えたあとは eval3 を確認用として使えなくなるので、新しい確認用セット (eval4) を用意してください。

## eval.tsv / eval2.tsv (調整用) で残っている NG

| セット | リクエスト | 改善後の出力 |
|---|---|---|
| eval | git logを著者別にランキング | `git shortlog -sn --summary \| sort -nr \| head -n 5` |
| eval | カレントディレクトリのファイルをサイズ順に表示 | `du -lh ./*` |
| eval | CPU使用率の高いプロセス上位5件 | `ps -Ao pid,%cpu,comm -m \| sort -nr \| head -n 5` |
| eval2 | 2日以内に作成・変更された.mdファイルを一覧 | `find . -type f -name "*.md" -newermt '2024-01-01 00:00:00' -exec rm -f {} +` (警告付き) |
| eval2 | カレントディレクトリで一番大きいファイル上位3つ | `ls -lTr \| sort -k5 -nr \| head -3` |
| eval2 | dockerで起動中のコンテナを全部停止 | `docker stop $(docker ps -u RUNNING -q)` |

「一覧」の依頼に `rm` が付く誤りは、`rules.tsv` の「削除を頼まれていないのに rm / -delete」ルールで指摘されるようになりました。再生成しても直らなかったため警告付きで出力されますが、`-y` で実行しようとした場合も確認が入ります。

## 再現方法

```zsh
zsh tests/check.zsh                             # モデルを使わない回帰テスト (数秒)
FMC_HISTORY_FILE=/dev/null zsh tests/score.zsh fmc.zsh tests/eval.tsv
FMC_HISTORY_FILE=/dev/null zsh tests/score.zsh fmc.zsh tests/eval2.tsv
FMC_HISTORY_FILE=/dev/null zsh tests/score.zsh fmc.zsh tests/eval3.tsv
```

調整できる環境変数: `FMC_MAX_RETRIES` (再生成回数、既定 3)、`FMC_NUM_EXAMPLES` (few-shot の例文数、既定 8)。
