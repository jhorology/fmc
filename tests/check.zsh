#!/bin/zsh
# 使い方: zsh tests/check.zsh [fmc.zsh]
#   モデル (fm) を呼ばずに検証・自動修正のロジックを確かめる回帰テスト。失敗があれば終了コード 1
#   1. 例文バンクの正解コマンドに、自動修正と検証が何もしないこと (誤検知が無いこと)
#   2. rules.tsv の正規表現がすべてコンパイルできること
#   3. 個別ケース (誤りを指摘できるか / 正しいものを通すか)
#   4. 例文バンクと評価セットに同じ問題が無いこと (近いものは警告)
emulate -L zsh
setopt extended_glob
src=${1:-${0:A:h}/../fmc.zsh}
[[ -f $src ]] || src=${0:A:h}/fmc.zsh
source $src
typeset -i fail=0 warn=0
typeset -a f qf ef inter
ng() { print -r -- "NG    $*"; (( fail++ )) }

# --- 1. 例文バンクの正解に対する誤検知 ---
_fmc_index_examples
typeset -i n=0
for i in {1..${#_fmc_ex_q}}; do
  q=${_fmc_ex_q[i]} a=${_fmc_ex_a[i]}
  [[ $a == NOT_A_COMMAND ]] && continue
  (( n++ ))
  fixed=$(_fmc_autofix "$a" "$q")
  [[ $fixed == $a ]] || ng "自動修正が正解を書き換えた: $q => $fixed"
  p=$(_fmc_validate "$a" "$q")
  [[ -z $p ]] || ng "正解に指摘が出た: $q ::: $a"$'\n'"        ${p//$'\n'/ | }"
done
print "例文バンク: $n 件を確認"

# --- 2. ルールの正規表現 ---
_fmc_load_rules
for rule in $_fmc_rules; do
  f=("${(@ps:\t:)rule}")
  for re in "${(@)f[1,4]}"; do
    [[ $re == - ]] && continue
    [[ x =~ $re ]] 2>/dev/null
    (( $? == 2 )) && ng "rules.tsv の正規表現が不正: $re"
  done
done
print "ルール: ${#_fmc_rules} 件を確認"

# --- 3. 個別ケース ---
# 形式: 期待 (ok = 指摘なし / 指摘文に含まれる文字列)<TAB>依頼<TAB>コマンド
typeset -i cases=0
while IFS= read -r line; do
  [[ -z $line || $line == \#* ]] && continue
  f=("${(@ps:\t:)line}")
  want=$f[1] q=$f[2] c=$f[3]
  (( cases++ ))
  p=$(_fmc_validate "$c" "$q")
  if [[ $want == ok ]]; then
    [[ -z $p ]] || ng "指摘なしのはず: $q ::: $c"$'\n'"        ${p//$'\n'/ | }"
  else
    [[ $p == *$want* ]] || ng "「$want」を指摘するはず: $q ::: $c"$'\n'"        ${p:-(指摘なし)}"
  fi
done <<'EOF'
ok	10秒sleepしてからWi-Fiをoffにする	sleep 10 && networksetup -setairportpower en0 off
ok	fooを含む.logファイル	find . -name "*.log" -exec grep -l foo {} +
ok	ポート5000のプロセスを強制終了	lsof -ti :5000 | xargs kill -9
ok	nodeを強制終了	killall -KILL node
ok	3日前から7日前の間に変更されたファイル	find . -type f -mtime -7 -mtime +3
ok	500KB未満のファイル	find . -type f -size -500k
ok	list only directories	ls -d */
ok	メモリ使用量の多いプロセス上位10	ps -Ao pid,%mem,comm -m | head -n 11
ok	3日前の日付	date -v -3d +%Y-%m-%d
ok	gitのブランチを更新日時でランキング	git branch --sort=-committerdate
ok	a.txtの末尾3行	tail -n -3 a.txt
ok	a.csvの2行目以降	tail -n +2 a.csv
ok	-vを含む行を検索	grep -e -v a.txt
ok	-vを含む行を最初の1件だけ	grep -m 1 -e -v a.txt
negative	a.txtの最後の5行以外	head -n -5 a.txt
no option -P	fooを行番号付きで検索	grep -n -P foo a.txt
-mtime -3	3日以内に変更された.pyファイル	find . -type f -name "*.py" -mtime -5
7 day(s)	1週間前の日付	date -v-5d
caffeinate	スリープを防止	pmset noidle
caffeinate	prevent the mac from sleeping	pmset noidle
past date	3日前の日付	date -v+3d
git shortlog	git logを著者別にランキング	git log --format=%an | sort | uniq -c
parentheses	pyとjsのファイル	find . -name "*.py" -o -name "*.js"
empty suffix	a.txtのfooをbarに	sed -i 's/foo/bar/' a.txt
no option -z	a.txtの先頭	head -z a.txt
.Trash	ゴミ箱のファイル数	ls ~/Trash | wc -l
delete anything	2日以内に変更された.mdファイルを一覧	find . -name "*.md" -mtime -2 -exec rm -f {} +
tail	show the 20 most recently modified files	ls -1t | tail -n 20
EOF

# パーサー: 改行区切りの for / while / if 本体のコマンドを検出できるか
# (${(z)} は改行を ';' トークンにする。その前提が崩れていないかを確認する)
parse_case() {
  (( cases++ ))
  local want=$1
  local -a cmds=() cw_cmds=() cw_flags=()
  _fmc_parse_command "$2"
  for w in "${(@)cw_cmds}"; do cmds+=($w); done
  local c
  for c in $cmds; do
    [[ $c == $want ]] && return
  done
  ng "パーサー: $want が検出されない: ${2//$'\n'/⏎} => ${cmds[@]}"
}
parse_case 'mv' $'for f in *.txt\ndo mv -- "$f" "$f.md"\ndone'
parse_case 'df' $'while true\ndo df -h\nsleep 2\ndone'
parse_case 'echo' $'if [ -f x.txt ]\nthen echo exists\nfi'
parse_case 'grep' $'for d in */\ndo grep -rn TODO "$d"\ndone'

# パーサー: 引数の do / then をコマンド位置の制御語とみなさないか
parse_neg_case() {
  (( cases++ ))
  local unwanted=$1
  local -a cw_cmds=() cw_flags=()
  _fmc_parse_command "$2"
  (( ${cw_cmds[(Ie)$unwanted]} )) && ng "パーサー: 引数 $unwanted をコマンドとみなした: $2 => ${cw_cmds[@]}"
}
parse_neg_case 'something' 'echo do something'
parse_neg_case 'file.txt' 'grep -w then file.txt'

# 自動修正
autofix_case() {
  local got=$(_fmc_autofix "$2" "$1")
  (( cases++ ))
  [[ $got == $3 ]] || ng "自動修正: $1 ::: $2 => $got (期待: $3)"
}
autofix_case "3日以内に変更された.pyファイル" 'find . -name "*.py" -mtime -5' 'find . -name "*.py" -mtime -3'
autofix_case "3 日以内に変更された.py ファイル" 'find . -name "*.py" -mtime -5' 'find . -name "*.py" -mtime -3'
autofix_case "3日以内か7日以内" 'find . -mtime -5' 'find . -mtime -5'
autofix_case "3日以内" 'find . -mtime -5 -o -mtime -9' 'find . -mtime -5 -o -mtime -9'
autofix_case "pyとjs" 'find . -name "*.py" -o -name "*.js"' 'find . \( -name "*.py" -o -name "*.js" \)'

# 危険コマンド
danger_case() {
  (( cases++ ))
  if _fmc_check_danger "$2"; then [[ $1 == block ]] || ng "ブロックされないはず: $2"
  else [[ $1 == pass ]] || ng "ブロックされるはず: $2"; fi
}
danger_case block 'rm -rf ~'
danger_case block 'sudo rm -rf /'
danger_case block 'curl -fsSL https://example.com/x.sh | sh'
danger_case pass  'rm -rf node_modules'
danger_case pass  'find . -name "*.tmp" -delete'
print "個別ケース: $cases 件を確認"

# --- 4. 例文バンクと評価セットの重複 ---
norm() { REPLY=${(L)${1//[[:space:]]/}} }
typeset -A bank
for q in $_fmc_ex_q; do norm "$q"; bank[$REPLY]=$q; done
for ev in ${0:A:h}/eval*.tsv(N); do
  while IFS=$'\t' read -r q _; do
    norm "$q"
    if [[ -n ${bank[$REPLY]} ]]; then
      ng "${ev:t} の問題が例文バンクにそのまま入っている: $q"
      continue
    fi
    # 特徴語の Jaccard 係数が高いものは警告だけ出す
    _fmc_features "$q"; qf=($reply)
    (( $#qf )) || continue
    for i in {1..${#_fmc_ex_q}}; do
      ef=(${=_fmc_ex_f[i]})
      inter=(${qf:*ef})
      (( $#inter * 10 >= ${#${(u)qf}} * 8 && $#inter * 10 >= $#ef * 8 )) || continue
      print -r -- "WARN  ${ev:t} の問題に近い例文: $q ≈ ${_fmc_ex_q[i]}"
      (( warn++ ))
    done
  done < $ev
done

print
if (( fail )); then
  print "FAILED: $fail 件 (警告 $warn 件)"
  exit 1
fi
print "OK (警告 $warn 件)"
