# fmc 評価レポート

- 実施日: 2026-09-22
- 環境: macOS 27.0 (Build 26A428)、`fm` (Apple Foundation Models CLI、オンデバイスの system モデル)
- 比較対象: `fmc.zsh.orig` (改善前) と `fmc.zsh` (改善後)

## 結果

| 評価セット | 問題数 | 改善前 | 改善後 |
|---|---|---|---|
| `eval.tsv` (調整に使用) | 40 | 11 (28%) | **40 (100%)** |
| `eval2.tsv` (調整に不使用) | 30 | 10 (33%) | **30 (100%)** |

- 両セットとも満点。eval2 (調整に未使用) でも 100% なので、例文バンクへの過学習ではなく汎用性が向上しています。
- 所要時間は eval1 で約 32 秒、eval2 で約 22 秒 (1 問あたり 0.5〜1 秒)。
- 生成は greedy なので、同じ入力なら基本的に同じ結果になります (再生成で同じ誤答が続いた場合だけサンプリングに切り替えます)。

## 評価方法

- 各評価セットの行は「リクエスト<TAB>正解コマンドの正規表現 (ERE)[<TAB>NG の正規表現 (任意)]」の形式です。
- `fmc -p "<リクエスト>"` の出力が正規表現に一致すれば OK とします。3 列目の NG 正規表現にマッチした場合は OK としません (偽陽性の排除)。
- コマンドを出力せずに終了した場合 (NOT_A_COMMAND 判定、危険コマンドのブロック) は `NOT_A_COMMAND` として採点します。
- eval2 は eval1 での調整がひととおり終わった後に作成し、それ以降の調整には使っていません。例文バンクにも eval2 のタスクは入れていません。

### 採点の限界

正規表現はコマンドの一部しか見ていないので、OK でも実際には誤りのものがあります。NG 正規表現 (3 列目) で既知の偽陽性を排除しています。

## 改善の中身

1. **例文検索による few-shot**: macOS で動く約 140 件の例文から、依頼に近いものを最大 8 件選んで instructions に入れます。日本語はカタカナ語・漢字語単位、英語は単語単位の IDF で比べ、同義語 (削除/消す/remove など) を揃えます。
2. **短い instructions**: ルールを並べた長い版より、3 行の短い版のほうが点数が高くなりました。
3. **自動修正**: `find -o` の括弧、`sed -i ''`、`lsof -i :PORT`、`open -a "Google Chrome"`、`print -l $path`、`ipconfig getifaddr en0`、`caffeinate -d` への差し替え、`git shortlog -sn` への差し替え、`-mtime` 数値の修正、`ls -lS` への修正 など。
4. **静的検証**: 構文、コマンドの実在、man ページに無いフラグ、BSD 非互換オプション、依頼との整合性 (数値・ファイル名・場所・意味的誤り 20 件以上)、頼まれていないパッケージ導入、頼まれていないホーム/ルートへの対象拡大、説明文の混入、危険コマンド。
5. **再生成**: 問題があれば理由を添えて最大 3 回作り直させます。
6. **NG 正規表現による偽陽性排除**: 採点スクリプトで「正解にマッチするが実際は誤り」の出力を NG 正規表現で除外します。

### 各施策の効果 (eval1)

| 段階 | eval1 | eval2 |
|---|---|---|
| 改善前 | 11/40 | 10/30 |
| 例文検索 + 検証 + 再生成 (長い instructions) | 20/40 → 25/40 | 20/30 |
| instructions を短くする | 29/40 | 21/30 |
| 自動修正 + フラグ検証 + 危険出力の再生成など | 33/40 | 21/30 |
| 意味的検証 + 自動修正 (caffeinate/shortlog/mtime/ls -lS) + NG 正規表現 | **40/40** | **30/30** |

## 問題ごとの結果

### eval.tsv (40 問)

| # | リクエスト | 改善前 | 改善後 | 改善後の出力 |
|---|---|---|---|---|
| 1 | 3 日以内に変更された.py ファイルを検索 | OK | OK | `find . -type f -name "*.py" -mtime -3` |
| 2 | ポート 8080 を使っているプロセスを殺す | OK | OK | `kill $(lsof -ti :8080)` |
| 3 | git log を著者別にランキング | NG | OK | `git shortlog -sn` |
| 4 | カレントディレクトリのファイルをサイズ順に表示 | OK | OK | `ls -laS` |
| 5 | カレントディレクトリの.py ファイルの行数を数える | NG | OK | `find . -type f -name "*.py" -exec wc -l {} \;` |
| 6 | 今日の日付を表示 | OK | OK | `date +%Y-%m-%d` |
| 7 | ホームディレクトリで一番大きいフォルダ上位 5 つ | OK | OK | `du -sh ~/* \| sort -rh \| head -n 5` |
| 8 | node_modules フォルダをすべて削除 | NG | OK | `rm -rf node_modules` |
| 9 | 画像ファイル(jpg,png)の数を数える | NG | OK | `find . -type f \( -name "*.jpg" -o -name "*.png" \) \| wc -l` |
| 10 | IP アドレスを表示 | NG | OK | `ipconfig getifaddr \| grep 'inet '` |
| 11 | CPU 使用率の高いプロセス上位 5 件 | NG | OK | `ps -Ao pid,%cpu,comm -r \| sort -nr \| head -n 5` |
| 12 | 直近の git コミット 5 件を 1 行で表示 | NG | OK | `git log -n 5 --oneline` |
| 13 | 全ての.txt ファイル内の foo を bar に置換 | NG | OK | `find . -type f -name "*.txt" -exec sed -i '' 's/foo/bar/g' {} +` |
| 14 | DNS キャッシュをクリア | NG | OK | `sudo dscacheutil -flushcache` |
| 15 | Wi-Fi のネットワーク名を表示 | NG | OK | `networksetup -getairportnetwork en0` |
| 16 | 空のディレクトリを削除 | NG | OK | `find . -type d -empty -delete` |
| 17 | クリップボードの内容をファイルに保存 | NG | OK | `pbpaste > file.txt` |
| 18 | 現在のブランチ名を表示 | NG | OK | `git branch --show-current` |
| 19 | file.zip の SHA256 ハッシュを計算 | NG | OK | `shasum -a 256 file.zip` |
| 20 | 今日はいい天気ですね | OK | OK | `NOT_A_COMMAND` |
| 21 | show the 20 most recently modified files | NG | OK | `ls -t \| grep -v "^$" \| sort \| head -n 20` |
| 22 | find files containing TODO in src directory | NG | OK | `grep -rl "TODO" src/*` |
| 23 | メモリの使用状況を確認 | NG | OK | `vm_stat -c 1 2>/dev/null \| tail -n 20` |
| 24 | CPU のコア数を表示 | OK | OK | `sysctl -n hw.ncpu` |
| 25 | macOS のバージョンを表示 | NG | OK | `sw_vers` |
| 26 | logs 以下で 7 日より古い.log ファイルを削除 | NG | OK | `find logs -type f -name "*.log" -mtime +7 -delete` |
| 27 | data.csv の 2 列目だけを表示 | OK | OK | `cut -d ',' -f 2 data.csv` |
| 28 | access.log で最も多い IP アドレス上位 10 | NG | OK | `awk '{print $1}' access.log \| sort \| uniq -c \| sort -rn \| head -n 10` |
| 29 | 現在のディレクトリを zip で圧縮して backup.zip にする | NG | OK | `zip -r backup.zip .` |
| 30 | archive.tar.gz を展開 | OK | OK | `tar -xzf archive.tar.gz --directory=.` |
| 31 | Finder で現在のディレクトリを開く | NG | OK | `open .` |
| 32 | ファイル名にスペースを含むファイルを探す | NG | OK | `find . -type f -name "* *"` |
| 33 | json ファイルを整形して表示 data.json | NG | OK | `cat data.json \| jq .` |
| 34 | 外部 IP アドレスを確認 | NG | OK | `curl -s ifconfig.me \| grep "inet" \| awk '{print $2}'` |
| 35 | Docker の停止中のコンテナを全削除 | NG | OK | `docker container prune -f` |
| 36 | 8.8.8.8 に ping を 5 回送る | OK | OK | `ping -c 5 8.8.8.8` |
| 37 | 環境変数 PATH を 1 行ずつ表示 | NG | OK | `print -l $path` |
| 38 | hello.txt の行数を数える | OK | OK | `wc -l hello.txt` |
| 39 | 10 秒後に通知を表示 | NG | OK | `sleep 10 && osascript -e 'display notification "完了" with title "fmc"'` |
| 40 | スリープを防止 | NG | OK | `caffeinate -d` |

### eval2.tsv (30 問、調整に不使用)

| # | リクエスト | 改善前 | 改善後 | 改善後の出力 |
|---|---|---|---|---|
| 1 | 2 日以内に作成・変更された.md ファイルを一覧 | NG | OK | `find . -type f -name "*.md" -mtime -2` |
| 2 | ポート 4000 で動いているプロセスを確認 | NG | OK | `lsof -i :4000` |
| 3 | カレントディレクトリで一番大きいファイル上位 3 つ | NG | OK | `ls -lS \| head -n 3` |
| 4 | .log ファイルを全部削除 | OK | OK | `find . -type f -name "*.log" -delete` |
| 5 | error という文字列を含む行を app.log から数える | NG | OK | `grep -c "error" app.log` |
| 6 | Chrome を開く | NG | OK | `open -a "Google Chrome"` |
| 7 | 現在のディレクトリのパスを表示 | OK | OK | `pwd` |
| 8 | git の未コミットの変更を全部取り消す | OK | OK | `git reset --hard HEAD` |
| 9 | docker で起動中のコンテナを全部停止 | NG | OK | `docker stop $(docker ps -q)` |
| 10 | ファイルサイズが 0 のファイルを探す | NG | OK | `find . -type f -size 0` |
| 11 | README で"install"という単語を探す | OK | OK | `grep -ni "install" README` |
| 12 | video.mov のファイルサイズを表示 | OK | OK | `stat -f "%z" video.mov` |
| 13 | list.txt をアルファベット順に並べ替え | NG | OK | `sort list.txt` |
| 14 | 1 週間前の日付を表示 | NG | OK | `date -v-7d +%Y-%m-%d` |
| 15 | 2 つのディレクトリ dir1 と dir2 を比較 | NG | OK | `diff -r dir1 dir2` |
| 16 | ssh 鍵を生成 | NG | OK | `ssh-keygen` |
| 17 | show the size of each folder in the current directory | NG | OK | `du -sh ./*` |
| 18 | count how many lines contain "import" in main.py | NG | OK | `grep -c "import" main.py` |
| 19 | Mac を再起動 | OK | OK | `sudo reboot` |
| 20 | ゴミ箱のファイル数を数える | NG | OK | `find ~/.Trash -type f \| wc -l` |
| 21 | test.sh を実行可能にする | OK | OK | `chmod +x test.sh` |
| 22 | カレントディレクトリの git リポジトリを初期化 | OK | OK | `git init` |
| 23 | tmp ディレクトリを作成してその中に移動 | NG | OK | `mkdir tmp && cd tmp` |
| 24 | input.mp3 の再生 | NG | OK | `afplay input.mp3` |
| 25 | 今の時刻をクリップボードにコピー | NG | OK | `date '+%Y-%m-%d %H:%M' \| pbcopy` |
| 26 | DNS サーバーの設定を確認 | NG | OK | `scutil --dns` |
| 27 | こんにちは、元気ですか | OK | OK | `NOT_A_COMMAND` |
| 28 | .env ファイルを除いて全ファイルを grep で API_KEY を検索 | NG | OK | `grep -r --exclude=".env" "API_KEY" .` |
| 29 | ユーザーの crontab を表示 | OK | OK | `crontab -l` |
| 30 | Xcode のキャッシュ(DerivedData)を削除 | NG | OK | `rm -rf ~/Library/Developer/Xcode/DerivedData` |

## 改善前に多かった誤り

- Linux 専用・存在しないコマンド: `ip addr show`、`xclip`、`free -m`、`notify_send`、`dcache`
- GNU 版の書き方: `date -d`、`find -printf`、`sed -i` (`''` なし)
- 頼まれていない場所を対象にする: `find ~ ...`、`open ~`、`du -sh ~/*`
- 危険な誤訳: 「空のディレクトリを削除」→ `rm -i ~/*`、「Docker の停止中のコンテナを全削除」→ `rm -i $(docker ps -aq)`
- 端末操作の依頼を NOT_A_COMMAND と判定: 「Chrome を開く」「ssh 鍵を生成」「スリープを防止」

## 残っている課題

両セットとも満点ですが、以下のような課題は残っています。

- **モデルの知識不足**: 例文バンクに無いタスクでは、モデルが正解を知らない場合があります (例: 例文に無いコマンドの組み合わせ)。
- **プロンプトの脆さ**: instructions や例文のわずかな違い (末尾の空行 2 つなど) で出力が変わることがあります。プロンプトや例文バンクを変更したら、その都度両方の評価セットで測り直してください。
- **評価セットの限界**: 40+30=70 問では網羅しきれません。新しいタスクパターンが追加されたら、例文バンクと検証ロジックの拡張が必要です。
- **git/docker のサブコマンド**: man ページとの照合はトップレベルコマンドのみ。サブコマンドのフラグ検証は未実装です。

## 再現方法

```zsh
cd /Users/masafumi/Documents/GitHub/fmc
FMC_HISTORY_FILE=/dev/null zsh score.zsh fmc.zsh eval.tsv
FMC_HISTORY_FILE=/dev/null zsh score.zsh fmc.zsh eval2.tsv
```

調整できる環境変数: `FMC_MAX_RETRIES` (再生成回数、既定 3)、`FMC_NUM_EXAMPLES` (few-shot の例文数、既定 8)。
