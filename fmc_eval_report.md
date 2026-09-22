# fmc 評価レポート

- 実施日: 2026-09-17
- 環境: macOS 27.0 (Build 26A428)、`fm` (Apple Foundation Models CLI、オンデバイスの system モデル)
- 比較対象: `fmc.zsh.orig` (改善前) と `fmc.zsh` (改善後)

## 結果

| 評価セット | 問題数 | 改善前 | 改善後 |
|---|---|---|---|
| `eval.tsv` (調整に使用) | 40 | 11 (28%) | **33 (83%)** |
| `eval2.tsv` (調整に不使用) | 30 | 10 (33%) | **21 (70%)** |

- 調整に使っていない eval2 でも改善しています。例文バンクへの過学習ではありません。
- 所要時間は eval1 で約28秒、eval2 で約18秒 (1問あたり 0.5〜1 秒)。改善前とほぼ同じです。
- 生成は greedy なので、同じ入力なら基本的に同じ結果になります (再生成で同じ誤答が続いた場合だけサンプリングに切り替えます)。

## 評価方法

- 各評価セットの行は「リクエスト<TAB>正解コマンドの正規表現 (ERE)」の形式です。
- `fmc -p "<リクエスト>"` の出力が正規表現に一致すれば OK とします。コマンドを出力せずに終了した場合 (NOT_A_COMMAND 判定、危険コマンドのブロック) は `NOT_A_COMMAND` として採点します。
- eval2 は eval1 での調整がひととおり終わった後に作成し、それ以降の調整には使っていません。例文バンクにも eval2 のタスクは入れていません。
- 改善前の版には `-p` オプションが無いため、`-p` を足したコピーを作って採点しました。

### 採点の限界

正規表現はコマンドの一部しか見ていないので、OK でも実際には誤りのものがあります。改善後の結果で目視で気づいたもの:

| リクエスト | 出力 | 問題 |
|---|---|---|
| git logを著者別にランキング | `git shortlog -sn --author` | 値の無い `--author` でエラーになる |
| DNSサーバーの設定を確認 | `cat /etc/resolv.conf \| grep -i dns` | `nameserver` 行が抽出されない |
| 今の時刻をクリップボードにコピー | `date +%s \| pbcopy` | UNIX 時刻になる (解釈次第) |

改善前にも、`tar -xzf archive.tar.gz --directory ~` (展開先がホーム) のように OK 扱いでも意図と違う出力があります。

## 改善の中身

1. **例文検索による few-shot**: macOS で動く約120件の例文から、依頼に近いものを最大8件選んで instructions に入れます。日本語はカタカナ語・漢字語単位、英語は単語単位の IDF で比べ、同義語 (削除/消す/remove など) を揃えます。
2. **短い instructions**: ルールを並べた長い版より、3行の短い版のほうが点数が高くなりました (eval1 で 25 → 29、eval2 で 20 → 21)。
3. **自動修正**: `find -o` の括弧、`sed -i ''`、`lsof -i :PORT`、`open -a "Google Chrome"`、`print -l $path`、`ipconfig getifaddr en0` など、定型的な誤りを直接直します。
4. **静的検証**: 構文、コマンドの実在、man ページに無いフラグ、BSD 非互換オプション、依頼中の数値・ファイル名・場所の反映、頼まれていないパッケージ導入、頼まれていないホーム/ルートへの対象拡大、説明文の混入、危険コマンド。
5. **再生成**: 問題があれば理由を添えて最大2回作り直させます。

### 各施策の効果 (eval1)

| 段階 | eval1 | eval2 |
|---|---|---|
| 改善前 | 11/40 | 10/30 |
| 例文検索 + 検証 + 再生成 (長い instructions) | 20/40 → 25/40 | 20/30 |
| instructions を短くする | 29/40 | 21/30 |
| 再生成なし (`FMC_MAX_RETRIES=0`) との比較 | 27/40 → 29/40 | - |
| 自動修正 + フラグ検証 + 危険出力の再生成など | 33/40 | 21/30 |

## 問題ごとの結果

### eval.tsv (40問)

| # | リクエスト | 改善前 | 改善後 | 改善後の出力 |
|---|---|---|---|---|
| 1 | 3日以内に変更された.pyファイルを検索 | OK | OK | `find . -type f -name "*.py" -mtime -3` |
| 2 | ポート8080を使っているプロセスを殺す | OK | OK | `kill -9 $(lsof -ti :8080)` |
| 3 | git logを著者別にランキング | NG | OK※ | `git shortlog -sn --author` |
| 4 | カレントディレクトリのファイルをサイズ順に表示 | OK | **NG** | `du -lh .` |
| 5 | カレントディレクトリの.pyファイルの行数を数える | NG | OK | `find . -type f -name "*.py" -exec wc -l {} +` |
| 6 | 今日の日付を表示 | OK | OK | `date +%Y-%m-%d` |
| 7 | ホームディレクトリで一番大きいフォルダ上位5つ | OK | OK | `du -sh ~/* \| sort -rh \| head -n 5` |
| 8 | node_modulesフォルダをすべて削除 | NG | OK | `rm -rf node_modules` |
| 9 | 画像ファイル(jpg,png)の数を数える | NG | OK | `find . -type f \( -name "*.jpg" -o -name "*.png" \) \| wc -l` |
| 10 | IPアドレスを表示 | NG | OK | `ipconfig getifaddr en0` |
| 11 | CPU使用率の高いプロセス上位5件 | NG | OK | `ps -Ao pid,%cpu,comm -r \| sort -k2 -nr \| head -n 5` |
| 12 | 直近のgitコミット5件を1行で表示 | NG | OK | `git log -5 --oneline` |
| 13 | 全ての.txtファイル内のfooをbarに置換 | NG | OK | `find . -type f -name "*.txt" -exec sed -i '' 's/foo/bar/g' {} +` |
| 14 | DNSキャッシュをクリア | NG | OK | `sudo dscacheutil -flushcache` |
| 15 | Wi-Fiのネットワーク名を表示 | NG | OK | `networksetup -getairportnetwork en0` |
| 16 | 空のディレクトリを削除 | NG | OK | `find . -type d -empty -delete` |
| 17 | クリップボードの内容をファイルに保存 | NG | OK | `pbpaste > file.txt` |
| 18 | 現在のブランチ名を表示 | NG | OK | `git branch --show-current` |
| 19 | file.zipのSHA256ハッシュを計算 | NG | OK | `shasum -a 256 file.zip` |
| 20 | 今日はいい天気ですね | OK | OK | `NOT_A_COMMAND` |
| 21 | show the 20 most recently modified files | NG | NG | `git log --oneline --date=iso -n 20 --nameonly` |
| 22 | find files containing TODO in src directory | NG | OK | `grep -rl "TODO" src` |
| 23 | メモリの使用状況を確認 | NG | NG | `sysctl vm.swup_max_memory_usage 1` |
| 24 | CPUのコア数を表示 | OK | OK | `sysctl -n hw.ncpu` |
| 25 | macOSのバージョンを表示 | NG | OK | `sw_vers` |
| 26 | logs以下で7日より古い.logファイルを削除 | NG | OK | `find logs -type f -name "*.log" -mtime +7 -delete` |
| 27 | data.csvの2列目だけを表示 | OK | OK | `cut -d ',' -f 2 data.csv` |
| 28 | access.logで最も多いIPアドレス上位10 | NG | NG | `grep -oI "$(tail -n 100 access.log \| ...)" \| head -n 10` |
| 29 | 現在のディレクトリをzipで圧縮してbackup.zipにする | NG | OK | `zip -r backup.zip .` |
| 30 | archive.tar.gzを展開 | OK | OK | `tar -xzf archive.tar.gz --directory=.` |
| 31 | Finderで現在のディレクトリを開く | NG | OK | `open .` |
| 32 | ファイル名にスペースを含むファイルを探す | NG | OK | `find . -type f -name "* *"` |
| 33 | jsonファイルを整形して表示 data.json | NG | NG | `jq '.data' data.json` |
| 34 | 外部IPアドレスを確認 | NG | OK | `curl -s ifconfig.me` |
| 35 | Dockerの停止中のコンテナを全削除 | NG | OK | `docker container prune -f` |
| 36 | 8.8.8.8にpingを5回送る | OK | OK | `ping -c 5 8.8.8.8` |
| 37 | 環境変数PATHを1行ずつ表示 | NG | OK | `print -l $path` |
| 38 | hello.txtの行数を数える | OK | OK | `wc -l < hello.txt` |
| 39 | 10秒後に通知を表示 | NG | NG | `osascript -e 'display notification ...' &>/dev/null & wait` |
| 40 | スリープを防止 | NG | NG | `osascript -e 'tell application "System Events" to sleepModal(...)'` |

※ 採点上は OK だが実際には誤り (「採点の限界」を参照)。

改善前に OK で改善後に NG になったのは #4 (サイズ順) の1問です。

### eval2.tsv (30問、調整に不使用)

| # | リクエスト | 改善前 | 改善後 | 改善後の出力 |
|---|---|---|---|---|
| 1 | 2日以内に作成・変更された.mdファイルを一覧 | NG | OK | `find . -type f -name "*.md" -mtime -2` |
| 2 | ポート4000で動いているプロセスを確認 | NG | OK | `lsof -i :4000` |
| 3 | カレントディレクトリで一番大きいファイル上位3つ | NG | NG | `ls -lhC */ \| sort -k5 -hr \| head -n 3` |
| 4 | .logファイルを全部削除 | OK | OK | `find . -type f -name "*.log" -delete` |
| 5 | errorという文字列を含む行をapp.logから数える | NG | OK | `grep -c "error" app.log` |
| 6 | Chromeを開く | NG | OK | `open -a "Google Chrome"` |
| 7 | 現在のディレクトリのパスを表示 | OK | OK | `pwd` |
| 8 | git の未コミットの変更を全部取り消す | OK | OK | `git reset --hard` |
| 9 | dockerで起動中のコンテナを全部停止 | NG | NG | `docker stop $(docker ps -aq)` |
| 10 | ファイルサイズが0のファイルを探す | NG | OK | `find . -type f -size 0` |
| 11 | READMEで"install"という単語を探す | OK | OK | `grep -ni "install" README` |
| 12 | video.movのファイルサイズを表示 | OK | OK | `stat -f "%z" video.mov` |
| 13 | list.txtをアルファベット順に並べ替え | NG | NG | `sort -u list.txt` |
| 14 | 1週間前の日付を表示 | NG | NG | `date -v +7d +%Y-%m-%d` |
| 15 | 2つのディレクトリdir1とdir2を比較 | NG | NG | `diff dir1 dir2` |
| 16 | ssh鍵を生成 | NG | OK | `ssh-keygen` |
| 17 | show the size of each folder in the current directory | NG | OK | `du -sh ./*` |
| 18 | count how many lines contain "import" in main.py | NG | OK | `grep -c "import" main.py` |
| 19 | Macを再起動 | OK | OK | `sudo reboot` |
| 20 | ゴミ箱のファイル数を数える | NG | NG | `find . -type f \| wc -l` |
| 21 | test.shを実行可能にする | OK | OK | `chmod +x test.sh` |
| 22 | カレントディレクトリのgitリポジトリを初期化 | OK | OK | `git init` |
| 23 | tmpディレクトリを作成してその中に移動 | NG | NG | `mkdir tmp && mv tmp/* .` |
| 24 | input.mp3の再生 | NG | NG | `mpc play input.mp3` |
| 25 | 今の時刻をクリップボードにコピー | NG | OK※ | `date +%s \| pbcopy` |
| 26 | DNSサーバーの設定を確認 | NG | OK※ | `cat /etc/resolv.conf \| grep -i dns` |
| 27 | こんにちは、元気ですか | OK | OK | `NOT_A_COMMAND` |
| 28 | .envファイルを除いて全ファイルをgrepでAPI_KEYを検索 | NG | OK | `grep -r --exclude=".env" "API_KEY" .` |
| 29 | ユーザーのcrontabを表示 | OK | OK | `crontab -l` |
| 30 | Xcodeのキャッシュ(DerivedData)を削除 | NG | NG | `rm -rf build/DerivedData/*` |

※ 採点上は OK だが実際には誤り、または解釈次第。

改善前に OK で改善後に NG になった問題はありません。

## 改善前に多かった誤り

- Linux 専用・存在しないコマンド: `ip addr show`、`xclip`、`free -m`、`notify_send`、`dcache`
- GNU 版の書き方: `date -d`、`find -printf`、`sed -i` (`''` なし)
- 頼まれていない場所を対象にする: `find ~ ...`、`open ~`、`du -sh ~/*`
- 危険な誤訳: 「空のディレクトリを削除」→ `rm -i ~/*`、「Dockerの停止中のコンテナを全削除」→ `rm -i $(docker ps -aq)`
- 端末操作の依頼を NOT_A_COMMAND と判定: 「Chromeを開く」「ssh鍵を生成」「スリープを防止」

## 残っている課題

検証では拾えない、モデルの知識や意味理解の誤りが中心です。

- 意味の取り違え: 「アルファベット順」に `sort -u`、「1週間前」に `date -v +7d` (未来になる)、「移動」に `mv`
- macOS 固有の知識不足: ゴミ箱 (`~/.Trash`)、DerivedData の場所、`afplay`、`caffeinate`
- 条件の取りこぼし: 「起動中の」コンテナに `docker ps -aq` (停止中も含む)
- 検証の対象外: `git`、`docker` などサブコマンドを持つツールのフラグは man ページとの照合をしていない

注意点として、instructions や例文のわずかな違い (末尾の空行2つなど) で出力が変わることを確認しています。プロンプトや例文バンクを変更したら、その都度両方の評価セットで測り直してください。

## 再現方法

```zsh
cd /Users/masafumi/tmp
FMC_HISTORY_FILE=/dev/null zsh score.zsh fmc.zsh eval.tsv
FMC_HISTORY_FILE=/dev/null zsh score.zsh fmc.zsh eval2.tsv
```

調整できる環境変数: `FMC_MAX_RETRIES` (再生成回数、既定 2)、`FMC_NUM_EXAMPLES` (few-shot の例文数、既定 8)。
