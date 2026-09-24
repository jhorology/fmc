#!/bin/zsh
# ============================================================================
# fmc - Foundation Model Command translator
# Apple Foundation Model (fm) を使って自然言語からzshコマンドを生成する
#
# 使い方:
#   fmc "3日以内に変更された.pyファイルを検索"
#   fmc "ポート8080を使っているプロセスを殺す"
#   fmc "git logを著者別にランキング"
#   fmc -y "ファイル一覧"          # 確認スキップで即実行 (破壊的コマンドは確認あり)
#   fmc -p "ファイル一覧"          # コマンドだけを標準出力へ (スクリプト用、検証の問題が残ると終了コード 2)
#   fmc -v "ファイル一覧"          # 参照した例文・検証過程を表示
#   fmc --history                  # 過去の生成履歴を表示
#   fmc --clear-history            # 履歴を削除
#
# 仕組み:
#   1. 例文バンク (examples.tsv) からリクエストに近い例を選んで few-shot として渡す
#   2. 機械的に直せる誤りを自動修正 (find -o の括弧、sed -i '' など)
#   3. 生成結果を静的検証 (構文 / コマンドとフラグの存在 / BSD非互換 / 依頼との整合 (rules.tsv) / 対象範囲)
#   4. 問題があれば理由を添えて再生成 (最大 FMC_MAX_RETRIES 回)
# ============================================================================

# --- 設定 ---
typeset -g _FMC_DIR=${${(%):-%x}:A:h}
FMC_HISTORY_FILE="${FMC_HISTORY_FILE:-${HOME}/.fmc_history}"
FMC_MAX_HISTORY="${FMC_MAX_HISTORY:-100}"
FMC_MAX_RETRIES="${FMC_MAX_RETRIES:-3}"
FMC_NUM_EXAMPLES="${FMC_NUM_EXAMPLES:-8}"
FMC_EXAMPLES_FILE="${FMC_EXAMPLES_FILE:-${_FMC_DIR}/examples.tsv}"
FMC_RULES_FILE="${FMC_RULES_FILE:-${_FMC_DIR}/rules.tsv}"
FMC_BACKEND="${FMC_BACKEND:-local}"
FMC_SHORTCUT_NAME="${FMC_SHORTCUT_NAME:-ask-cloud-model}"
FMC_CLOUD_NUM_EXAMPLES="${FMC_CLOUD_NUM_EXAMPLES:-0}"
FMC_KEYBIND="${FMC_KEYBIND:-^O}"
FMC_ICON="${FMC_ICON:-✨}"

# source し直したときに例文・ルールを読み込み直す
unset _fmc_ex_q _fmc_ex_a _fmc_ex_f _fmc_df _fmc_rules

# --- 色定義 ---
typeset -gA _fmc_colors=(
  reset  $'\033[0m'
  bold   $'\033[1m'
  dim    $'\033[2m'
  red    $'\033[31m'
  green  $'\033[32m'
  yellow $'\033[33m'
  blue   $'\033[34m'
  cyan   $'\033[36m'
)

# --- システムプロンプト ---
typeset -g _FMC_INSTRUCTIONS='You are a macOS zsh expert. Convert the request into one zsh command line that works on macOS (BSD tools).
Answer with the command only. Follow the style of the examples. Operate on the current directory unless another place is named.
If the request is not a terminal task, answer NOT_A_COMMAND.'

# --- Linux専用コマンドなどに対する代替ヒント ---
typeset -gA _FMC_CMD_HINTS=(
  ip           'use "ipconfig getifaddr en0" (local IP) or "ifconfig"'
  ifup         'use "networksetup"'
  iwconfig     'use "networksetup -getairportnetwork en0"'
  iwgetid      'use "networksetup -getairportnetwork en0"'
  nmcli        'use "networksetup"'
  xclip        'use "pbcopy" (copy) or "pbpaste" (paste)'
  xsel         'use "pbcopy" (copy) or "pbpaste" (paste)'
  xdg-open     'use "open"'
  free         'use "vm_stat" or "top -l 1 | head -n 10"'
  nproc        'use "sysctl -n hw.ncpu"'
  lscpu        'use "sysctl -n machdep.cpu.brand_string"'
  lsb_release  'use "sw_vers"'
  apt          'use "brew"'
  apt-get      'use "brew"'
  yum          'use "brew"'
  dnf          'use "brew"'
  systemctl    'use "launchctl" or "brew services"'
  service      'use "launchctl" or "brew services"'
  journalctl   'use "log show"'
  notify-send  'use: osascript -e '\''display notification "message"'\'''
  notify_send  'use: osascript -e '\''display notification "message"'\'''
  ss           'use "lsof -iTCP -sTCP:LISTEN -n -P"'
  dcache       'use "sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder"'
  md5sum       'use "md5"'
  sha256sum    'use "shasum -a 256"'
  tree         'use "find . -print | sed -e '\''s;[^/]*/;|____;g;s;____|; |;g'\''" or simply "find ."'
  route        'use "netstat -nr"'
  watch        'use "while true; do clear; <cmd>; sleep 2; done"'
  locate       'use "mdfind -name"'
  rename       'use a "for" loop with "mv"'
  mpc          'use "afplay" (play audio files on macOS)'
)

# --- 値を1つ取るオプション (値が -3 や +7 のように - で始まってもフラグとみなさない) ---
typeset -gA _FMC_VALUE_OPTS=(
  find  '-mtime -mmin -atime -amin -ctime -cmin -Btime -Bmin -size -maxdepth -mindepth -name -iname -path -ipath -regex -iregex -type -newer -perm -user -group -links -uid -gid'
  date  '-v -f -r'
  cut   '-b -c -f -d'
  sort  '-k -t'
)

# --- 危険コマンド (即ブロック) ---
typeset -ga _FMC_DANGER_REGEX=(
  '(^|[;&|[:space:]])mkfs'
  '(^|[;&|[:space:]])dd[[:space:]].*of=/dev/'
  ':\(\)[[:space:]]*\{.*:[[:space:]]*\|[[:space:]]*:.*&.*\}'
  '>[[:space:]]*/dev/(r?disk|sd)'
  'chmod[[:space:]]+-R[[:space:]]+[0-7]+[[:space:]]+/([[:space:]]|$)'
  'chown[[:space:]]+-R[[:space:]]+[^[:space:]]+[[:space:]]+/([[:space:]]|$)'
  'diskutil[[:space:]]+(eraseDisk|eraseVolume|zeroDisk|secureErase)'
  '(curl|wget)[[:space:]].*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z)?sh([[:space:]]|$)'
)

# 実行前に確認すべき破壊的操作
typeset -g _FMC_DESTRUCTIVE_REGEX='(^|[;&|(`[:space:]])(rm|rmdir|mv|kill|pkill|killall|sudo|shutdown|reboot|halt|chmod|chown|dd|truncate|srm)([[:space:]]|$)|-delete|sed[[:space:]]+-i|git[[:space:]]+(reset[[:space:]]+--hard|clean|push[[:space:]].*(-f|--force)|branch[[:space:]]+-D)|docker[[:space:]].*(rm|prune)|(^|[^>2&])>[[:space:]]*[^&[:space:]]'

# --- ヘルパー関数 ---

_fmc_c() {
  ${print_only:-false} && return
  print -rn -- "${_fmc_colors[$1]}"
}

_fmc_log_history() {
  emulate -L zsh
  # 複数行のコマンドは改行を \x1f にして1行に収める (表示時に戻す)
  local query=${1//[$'\t\n']/ } cmd=${${2//$'\t'/ }//$'\n'/$'\x1f'}
  print -r -- "$(date '+%Y-%m-%d %H:%M:%S')"$'\t'"${query}"$'\t'"${cmd}" >> "$FMC_HISTORY_FILE"

  # 履歴の最大行数を制限
  local lines=$(wc -l < "$FMC_HISTORY_FILE")
  if (( lines > FMC_MAX_HISTORY )); then
    local tmp=$(mktemp)
    tail -n "$FMC_MAX_HISTORY" "$FMC_HISTORY_FILE" > "$tmp" && mv "$tmp" "$FMC_HISTORY_FILE"
  fi
}

_fmc_show_history() {
  emulate -L zsh
  if [[ ! -s "$FMC_HISTORY_FILE" ]]; then
    print -r -- "$(_fmc_c dim)履歴はありません$(_fmc_c reset)"
    return
  fi

  print -r -- "$(_fmc_c bold)$(_fmc_c cyan)📜 fmc 生成履歴$(_fmc_c reset)"
  print -r -- "$(_fmc_c dim)──────────────────────────────────────────$(_fmc_c reset)"

  local ts query cmd nl=$'\n    '
  while IFS=$'\t' read -r ts query cmd; do
    print -r -- "$(_fmc_c dim)${ts}$(_fmc_c reset)  $(_fmc_c green)${query}$(_fmc_c reset)"
    print -r -- "  → $(_fmc_c cyan)${cmd//$'\x1f'/$nl}$(_fmc_c reset)"
  done < "$FMC_HISTORY_FILE"
}

# モデル出力からコマンドを取り出す
_fmc_sanitize() {
  emulate -L zsh
  setopt extended_glob
  local raw=$1 line
  local -a lines
  lines=("${(@f)raw}")

  # コードブロック (```) があるかチェック
  local in_block=0
  local block_content=""
  for line in $lines; do
    if [[ $line == \`\`\`* ]]; then
      if (( in_block )); then
        block_content=${block_content%%$'\n'} # 末尾の改行を削除
        [[ -n $block_content ]] && { print -r -- "$block_content"; return }
        in_block=0
      else
        in_block=1
      fi
      continue
    fi
    if (( in_block )); then
      block_content+="$line"$'\n'
    fi
  done

  # コードブロックがなければ、従来通り最初の有効な1行を抽出
  for line in $lines; do
    line=${line##[[:space:]]#}
    line=${line%%[[:space:]]#}
    [[ -z $line ]] && continue
    line=${line#(Command|command|A|Answer|zsh|bash):[[:space:]]#}
    line=${line#\$ }
    [[ $line == \`*\` ]] && line=${${line#\`}%\`}
    line=${line##[[:space:]]#}
    [[ -n $line ]] && { print -r -- "$line"; return }
  done
}

# 例文検索用: 表記ゆれ・同義語を代表語にまとめる
typeset -gA _FMC_SYNONYMS=(
  消 削除  消去 削除  除去 削除  remove 削除  delete 削除  rm 削除  clean 削除
  探 検索  search 検索  find 検索  含 検索  grep 検索
  ランキング 上位  top 上位  多 上位  大 上位  largest 上位  biggest 上位  most 上位
  数 数える  count 数える  カウント 数える  行数 数える
  フォルダ ディレクトリ  directory ディレクトリ  folder ディレクトリ  dir ディレクトリ
  file ファイル  容量 サイズ  size サイズ  大きさ サイズ
  process プロセス  kill 終了  殺 終了  止 終了  停止 終了  stop 終了
  更新 変更  modified 変更  changed 変更  置換 置き換え  replace 置き換え  換 置き換え
  copy コピー  create 作成  作 作成  make 作成  解凍 展開  extract 展開  unzip 展開
  compress 圧縮  archive 圧縮  zip 圧縮  最新 最近  recent 最近  recently 最近  直近 最近
  time 時刻  日時 時刻  date 日付  memory メモリ  cpu CPU使用率  使用率 CPU使用率
  open 開  起動 開  launch 開  network ネットワーク  wifi ネットワーク  ip IPアドレス  アドレス IPアドレス
  著者 コントリビューター  author コントリビューター  committer コントリビューター
  clipboard クリップボード  notify 通知  notification 通知  sleep スリープ  commit コミット  branch ブランチ
  macOS OS  バージョン version
)
typeset -gA _FMC_STOPWORDS=(
  the 1 a 1 an 1 in 1 of 1 to 1 all 1 with 1 and 1 for 1 on 1 by 1 is 1 it 1 that 1 this 1 from 1
  show 1 list 1 display 1 print 1 get 1 me 1 my 1 how 1 do 1 each 1 every 1 only 1
  表示 1 一覧 1 全 1 現在 1 カレント 1 以下 1 以内 1 中 1 順 1 使 1 確認 1
)

# 例文検索用の特徴量を reply に入れる
#   英数字は単語、日本語はカタカナ語 / 漢字語 (長い漢字語は bigram も) に分割
#   ※ひらがな([ぁ-ん])はあえて対象外とし、助詞(てにをは)を区切り文字として利用する
_fmc_features() {
  emulate -L zsh
  setopt extended_glob
  local s=$1 c kind prev_kind="" run="" w i j
  local -a toks
  for (( i = 1; i <= ${#s} + 1; i++ )); do
    c=${s[i]}
    case $c in
      ([ァ-ヶー]) kind=K ;;
      ([一-龥々]) kind=H ;;
      ([A-Za-z0-9_+-]) kind=A ;;
      (*) kind="" ;;
    esac
    if [[ $kind != $prev_kind ]]; then
      if [[ -n $run ]]; then
        case $prev_kind in
          (A) w=${(L)run}; [[ $w == ?*?s && ${#w} -gt 3 ]] && w=${w%s}; (( ${#w} >= 2 )) && toks+=($w) ;;
          (K) (( ${#run} >= 2 )) && toks+=($run) ;;
          (H) toks+=($run)
              (( ${#run} >= 3 )) && for (( j = 1; j < ${#run}; j++ )); do toks+=(${run[j,j+1]}); done ;;
        esac
      fi
      run=""
    fi
    [[ -n $kind ]] && run+=$c
    prev_kind=$kind
  done
  local -A seen
  reply=()
  for w in $toks; do
    [[ -n ${_FMC_STOPWORDS[$w]} ]] && continue
    [[ -n ${_FMC_SYNONYMS[$w]} ]] && w=${_FMC_SYNONYMS[$w]}
    [[ -z ${seen[$w]} ]] && { seen[$w]=1; reply+=($w) }
  done
}

# 例文バンクの特徴量と DF を初回だけ計算
_fmc_index_examples() {
  emulate -L zsh
  (( ${#_fmc_ex_q} )) && return
  typeset -ga _fmc_ex_q _fmc_ex_a _fmc_ex_f
  typeset -gA _fmc_df
  [[ -r $FMC_EXAMPLES_FILE ]] || return
  local line f
  local -a reply
  # 形式: リクエスト<TAB>コマンド (# で始まる行はコメント)
  for line in "${(@f)$(<$FMC_EXAMPLES_FILE)}"; do
    [[ $line == [^#]*$'\t'?* ]] || continue
    _fmc_ex_q+=("${line%%$'\t'*}")
    _fmc_ex_a+=("${line#*$'\t'}")
    _fmc_features "${line%%$'\t'*}"
    _fmc_ex_f+=(" ${(j: :)reply} ")
    for f in $reply; do (( _fmc_df[$f]++ )); done
  done
}

# リクエストに近い例文を選び、few-shot テキストを REPLY に入れる (関連度の高いものほど後ろ)
# reply[1] には最もよく一致したコマンド例文 (NOT_A_COMMAND 以外) のスコアが入る
_fmc_select_examples() {
  emulate -L zsh
  setopt extended_glob
  zmodload -F zsh/mathfunc f:log
  _fmc_index_examples
  local query=$1 k=${2:-$FMC_NUM_EXAMPLES}
  local -a scored
  _fmc_features "$query"
  local -a qf=($reply)
  local n=${#_fmc_ex_q} i f
  local score
  for (( i = 1; i <= n; i++ )); do
    score=0
    for f in $qf; do
      [[ ${_fmc_ex_f[i]} == *" $f "* ]] && (( score += log((n + 1.0) / _fmc_df[$f]) ))
    done
    (( score > 0 )) && scored+=("$(printf '%09.4f' $score):$i")
  done
  local -a top=(${${(On)scored}[1,k]})
  # 最上位の 1/3 未満しか一致しない例文はノイズになるので除外
  local best=${${top[1]%%:*}:-0}
  local -a kept
  local item
  for item in $top; do
    (( ${item%%:*} * 3 >= best )) && kept+=($item)
  done
  top=($kept)
  local text="" command_score=0
  for item in ${(Oa)top}; do
    i=${item#*:}
    text+="Request: ${_fmc_ex_q[i]}"$'\n'"Command: ${_fmc_ex_a[i]}"$'\n\n'
    [[ ${_fmc_ex_a[i]} != NOT_A_COMMAND ]] && (( ${item%%:*} > command_score )) && command_score=${item%%:*}
  done
  REPLY=${text%%$'\n'#}
  reply=($command_score)
}

# コマンドラインを解析し、呼び出し元の配列 cw_cmds (コマンド名) と
# cw_flags ("コマンド名 フラグ") に追加する (動的スコープ)
_fmc_parse_command() {
  emulate -L zsh
  setopt extended_glob
  local -a toks=(${(z)1})
  local expect=1 i=1 t inner cur="" exec_outer=""
  while (( i <= $#toks )); do
    t=${toks[i]}
    # コマンド置換の中身も再帰的に調べる
    if [[ $t == *'$('*')'* ]]; then
      inner=${t#*\$\(}; inner=${inner%\)*}
      _fmc_parse_command "$inner"
    fi
    # find -exec ... \; / {} + の終わりで find のオプション解析に戻る
    if [[ -n $exec_outer ]] && [[ $t == ('\;'|"';'"|'";"') || ( $t == '+' && ${toks[i-1]} == '{}' ) ]]; then
      cur=$exec_outer exec_outer="" expect=0
      (( i++ ))
      continue
    fi
    case $t in
      ('|'|'||'|'&&'|';'|'&'|'|&'|'('|'{'|'!')
        expect=1 cur="" exec_outer="" ;;
      (for|select|case|')'|'}'|fi|done|esac)
        expect=0 cur="" ;;
      (-exec|-execdir|-ok|-okdir)
        if [[ -n $cur ]]; then
          exec_outer=$cur expect=1 cur=""
        fi ;;
      # 制御語・修飾語はコマンド位置 (expect==1) のときだけ次の語をコマンドとみなす
      # (echo if / echo time のような引数で誤判定しないようにする)
      (then|do|else|elif|if|while|until|time|nohup|noglob|builtin|command|exec)
        (( expect )) && { expect=1; cur=""; } ;;
      (*)
        if (( expect )); then
          if [[ $t == [A-Za-z_][A-Za-z0-9_]#=* ]]; then
            :   # 変数代入
          elif [[ $t == (sudo|env|xargs|nice) ]]; then
            cw_cmds+=($t)
            # オプション (と引数を取るオプション) を読み飛ばす
            while (( i < $#toks )); do
              case ${toks[i+1]} in
                (-[IJLnPsEtu]) (( i += 2 )) ;;
                ([A-Za-z_][A-Za-z0-9_]#=*|-*) (( i++ )) ;;
                (*) break ;;
              esac
            done
          else
            cw_cmds+=($t); cur=$t; expect=0
          fi
        elif [[ -n $cur && $t == -* && $t != -- ]]; then
          local base_flag=${t%%=*}
          if [[ $cur == (kill|killall|pkill) && $base_flag == -([0-9]##|[A-Z][A-Z0-9]#) ]]; then
            :   # シグナル指定 (kill -9, killall -HUP)
          elif [[ $base_flag == -[A-Za-z0-9-]* && $base_flag != *[^A-Za-z0-9-]* ]]; then
            cw_flags+=("$cur $base_flag")
          fi
          [[ $t != *=* && " ${_FMC_VALUE_OPTS[$cur]} " == *" $base_flag "* ]] && (( i++ ))
        elif [[ $t == -- ]]; then
          cur=""
        fi ;;
    esac
    (( i++ ))
  done
}

# macOS 標準コマンドの man ページに載っているフラグ一覧 (キャッシュ付き)
typeset -gA _fmc_man_cache
_fmc_man_flags() {
  emulate -L zsh
  local c=$1
  local cache_file=${XDG_CACHE_HOME:-$HOME/.cache}/fmc/manflags/$c
  if (( ! ${+_fmc_man_cache[$c]} )) && [[ -r $cache_file ]]; then
    _fmc_man_cache[$c]=$(<$cache_file)
  fi
  if (( ! ${+_fmc_man_cache[$c]} )); then
    # 単一文字フラグ (-x) と単語フラグ (-name) を空白区切りで保存 (man が無ければ空)
    local -a found
    found=(${(f)"$(MANPAGER=cat man $c 2>/dev/null | col -b | grep -oE -e '(^|[^A-Za-z0-9-])--?[A-Za-z0-9-]+' | sed -E -e 's/^[^-]*//')"})
    if (( $#found )); then
      _fmc_man_cache[$c]=" ${(j: :)${(u)found}} "
    else
      _fmc_man_cache[$c]=""
    fi
    mkdir -p ${cache_file:h} 2>/dev/null && print -rn -- "${_fmc_man_cache[$c]}" > $cache_file 2>/dev/null
  fi
  REPLY=${_fmc_man_cache[$c]}
}

# 意味的な検証ルール (rules.tsv) を初回だけ読み込む
#   形式: 依頼の正規表現<TAB>依頼の除外正規表現<TAB>コマンドの正規表現<TAB>コマンドの除外正規表現<TAB>指摘文
#   正規表現は ERE。依頼は小文字化して照合する。条件なしは "-"
_fmc_load_rules() {
  emulate -L zsh
  (( ${+_fmc_rules} )) && return
  typeset -ga _fmc_rules=()
  [[ -r $FMC_RULES_FILE ]] || return
  local line
  for line in "${(@f)$(<$FMC_RULES_FILE)}"; do
    [[ -z $line || $line == \#* ]] && continue
    (( ${#${(ps:\t:)line}} == 5 )) && _fmc_rules+=("$line")
  done
}

# 生成されたコマンドを静的検証し、問題点 (英語: モデルへのフィードバック用) を1行ずつ出力する
_fmc_validate() {
  emulate -L zsh
  setopt extended_glob
  local cmd=$1 query=$2 w
  local lcmd=${(L)cmd} lquery=${(L)query}

  # 説明文になっていないか
  if [[ $cmd == *[ぁ-んァ-ヶ一-龥]* && $cmd != *[\'\"]*[ぁ-んァ-ヶ一-龥]*[\'\"]* ]] || \
     [[ $cmd =~ '(^|[[:space:]])(is not|does not|instead|use|Use|should|you can)[[:space:]]' && $cmd != *[\'\"]* ]]; then
    print -r -- 'the answer contains an explanation; answer with the command only'
    return
  fi

  # 構文チェック
  local err
  if ! err=$(zsh -n -c "$cmd" 2>&1); then
    print -r -- "zsh syntax error: ${${err#zsh:[0-9]#: }//$'\n'/ }"
    return
  fi

  local -a cw_cmds cw_flags
  _fmc_parse_command "$cmd"

  # コマンドの存在チェック
  local -A reported
  for w in $cw_cmds; do
    [[ $w == (\$*|\"*|\'*|\{*|\(*|\[*|\]*|./*|\~/*|-*) ]] && continue
    [[ -n ${reported[$w]} ]] && continue
    reported[$w]=1
    if [[ $w == (your_*|*_command|\<*\>|command_name|directory_name|file_name) ]]; then
      print -r -- "\"$w\" is a placeholder; write the real command"
    elif ! whence -- "$w" >/dev/null 2>&1; then
      if [[ -n ${_FMC_CMD_HINTS[$w]} ]]; then
        print -r -- "\"$w\" does not exist on macOS; ${_FMC_CMD_HINTS[$w]}"
      else
        print -r -- "command \"$w\" does not exist on this Mac"
      fi
    fi
  done

  # フラグの存在チェック: macOS 標準コマンドについて man ページに無いフラグを指摘
  local entry c flag l bad cpath
  local -A flag_reported
  for entry in $cw_flags; do
    c=${entry%% *} flag=${entry#* }
    [[ -n ${flag_reported[$entry]} ]] && continue
    flag_reported[$entry]=1
    [[ $c == (git|docker|brew|npm|npx|pip|pip3|python|python3|ruby|perl|swift|xcrun|go|cargo|kubectl|java|node|make|gcc|clang|defaults|security|tmutil|diskutil|hdiutil|launchctl|log|zsh|bash|sh) ]] && continue
    cpath=${commands[$c]}
    [[ $cpath == (/bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*) ]] || continue
    _fmc_man_flags $c
    [[ -z $REPLY || $REPLY == *" $flag "* ]] && continue
    # BSD date の -v は調整値を添付する (-v-7d, -v+2d, -v1w) ため man には載らない
    [[ $c == date && $flag == -v?* ]] && continue
    # 結合された短いフラグ (-lhS) は1文字ずつ確認
    bad=""
    for l in ${(s::)${flag#-}}; do
      [[ $REPLY == *" -$l "* ]] || { bad=$flag; break }
    done
    [[ -n $bad ]] && print -r -- "\"$c\" has no option $bad on macOS (check: man $c)"
  done

  # BSD 非互換 (GNU 拡張) のチェック: そのコマンドが macOS 標準のものに解決される場合のみ
  local s='(^|[;&|({[:space:]]|-exec[[:space:]]+)'
  if [[ ${commands[find]} == /usr/bin/find ]]; then
    [[ $cmd =~ "${s}find[[:space:]]+-" ]] && print -r -- 'BSD find needs a path first: find . -name ...'
    [[ $cmd =~ "${s}find[[:space:]].*-printf" ]] && print -r -- 'BSD find has no -printf; use -exec stat -f or ls -l'
    [[ $cmd =~ "${s}find[[:space:]].*[[:space:]]-name[[:space:]]+[^[:space:]]+[[:space:]]+-o[[:space:]]" && $cmd != *'\('* ]] && \
      print -r -- 'group -o conditions with parentheses: find . -type f \( -name "*.a" -o -name "*.b" \)'
    [[ $cmd =~ "${s}find[[:space:]].*[[:space:]]-count" ]] && print -r -- 'find has no -count; pipe to wc -l'
  fi
  if [[ ${commands[sed]} == /usr/bin/sed ]] && [[ $cmd =~ "${s}sed[[:space:]]+-i([[:space:]]|$)" ]] && \
     [[ ! $cmd =~ "sed[[:space:]]+-i[[:space:]]+(''|\"\")" ]]; then
    print -r -- "BSD sed needs an empty suffix: sed -i '' 's/a/b/g' file"
  fi
  [[ ${commands[grep]} == /usr/bin/grep && $cmd =~ "${s}grep[[:space:]]+(-[a-zA-Z]*P|--perl)" ]] && print -r -- 'BSD grep has no -P; use grep -E'
  [[ ${commands[xargs]} == /usr/bin/xargs && $cmd =~ "xargs[[:space:]]+-i" ]] && print -r -- 'BSD xargs uses -I {} (not -i)'
  [[ ${commands[date]} == /bin/date && $cmd =~ "${s}date[[:space:]]+(-d|--date)" ]] && print -r -- 'BSD date uses -v (e.g. date -v-1d), not -d'
  [[ ${commands[stat]} == /usr/bin/stat && $cmd =~ "${s}stat[[:space:]]+(-c|--format)" ]] && print -r -- 'BSD stat uses -f (e.g. stat -f %z file), not -c'
  [[ ${commands[du]} == /usr/bin/du && $cmd =~ "${s}du[[:space:]].*--max-depth" ]] && print -r -- 'BSD du uses -d N, not --max-depth'
  [[ ${commands[ps]} == /bin/ps && $cmd =~ "${s}ps[[:space:]].*--sort" ]] && print -r -- 'BSD ps has no --sort; use ps -Ao pid,%cpu,comm -r (CPU) or -m (memory)'
  [[ ${commands[head]} == /usr/bin/head && $cmd =~ "${s}head[[:space:]]+-n[[:space:]]*-[0-9]" ]] && print -r -- 'BSD head does not accept negative counts'
  [[ $cmd =~ "${s}lsof[[:space:]]" && $cmd =~ "lsof[[:space:]][^|;&]*[[:space:]]:[0-9]+" && ! $cmd =~ "lsof[[:space:]]+(-[a-zA-Z]*i|-i)" ]] && print -r -- 'lsof needs -i before the port: lsof -i :8080'
  [[ $cmd =~ "${s}git[[:space:]]+log[[:space:]]+--author([[:space:]]|$)" ]] && print -r -- 'git log --author needs a name; to rank authors use git shortlog -sn'

  # --- 意味的な誤りのチェック (モデルの知識不足を補う) ---
  # 単純な条件のものは rules.tsv に書く。ここには値の計算やコマンド実行が必要なものだけを置く
  # 「N週間」の依頼で -v-Nd の N が 7*N になっていない
  if [[ $lquery =~ '([0-9]+)週間' ]]; then
    local weeks=${match[1]}
    if [[ $cmd =~ 'date[[:space:]]+-v-([0-9]+)d' ]] && (( 10#${match[1]} != 10#$weeks * 7 )); then
      print -r -- "the request says ${weeks} week(s) = $(( 10#$weeks * 7 )) day(s); use \"date -v-$(( 10#$weeks * 7 ))d\" or \"date -v-${weeks}w\""
    fi
  fi
  # 「N日以内」の依頼で -mtime -M の M が N になっていない
  if [[ $lquery =~ '([0-9]+)[[:space:]]*日以内' ]]; then
    local want_days=${match[1]}
    if [[ $cmd =~ '-mtime[[:space:]]+-([0-9]+)' ]] && (( 10#${match[1]} != 10#$want_days )); then
      print -r -- "the request says ${want_days} day(s) but the command uses -mtime -${match[1]}; use \"-mtime -$want_days\""
    fi
  fi
  # sysctl のキーが実在するか
  if [[ $cmd =~ '(^|[;&|({[:space:]])sysctl[[:space:]]+([^|;&]*)' ]]; then
    local -a stoks=(${(w)match[2]})
    local sk
    for sk in $stoks; do
      [[ $sk == (-*|*=*|[0-9]*) ]] && continue
      if ! sysctl -n "$sk" &>/dev/null; then
        print -r -- "sysctl key \"$sk\" does not exist on this Mac"
        break
      fi
    done
  fi
  _fmc_load_rules
  local rule
  local -a rf
  for rule in $_fmc_rules; do
    rf=("${(@ps:\t:)rule}")
    [[ $rf[1] == - || $lquery =~ $rf[1] ]] || continue
    [[ $rf[2] == - || ! $lquery =~ $rf[2] ]] || continue
    [[ $rf[3] == - || $cmd =~ $rf[3] ]] || continue
    [[ $rf[4] == - || ! $cmd =~ $rf[4] ]] || continue
    print -r -- "$rf[5]"
  done

  # リクエストとの整合性: 数値・ファイル名・引用された語がコマンドに含まれているか
  local tok rest
  local -a missing
  # 数値 (時間・容量など単位変換されうるものと 0/1 は除く)
  rest=${lquery//[0-9]##[[:space:]]#(時間|分|週間|週|ヶ月|か月|カ月|年|hours#|minutes#|mins#|weeks#|months#|years#|gb|kb)/ }
  for tok in ${(u)=${rest//[^0-9]/ }}; do
    [[ $tok == (0|1) ]] && continue
    [[ $lcmd == *$tok* ]] && continue
    # 見出し行の分だけ多く出す "上位10" → head -n 11
    [[ $lcmd =~ "head[[:space:]]+-n?[[:space:]]*$(( 10#$tok + 1 ))([^0-9]|$)" ]] && continue
    missing+=($tok)
  done
  # ファイル名 (data.csv) と拡張子 (.py)
  for tok in ${(u)=${lquery//[^a-z0-9._-]/ }}; do
    [[ $tok == *.[a-z][a-z0-9]# ]] || continue
    [[ $lcmd == *$tok* ]] || missing+=($tok)
  done
  # 場所の指定: 「logs以下」「srcフォルダ」「in src directory」
  rest=$query
  while [[ $rest == (#b)(|*[^A-Za-z0-9_.~/-])([A-Za-z0-9_.~/-]##)(以下|の中|内の|フォルダ|ディレクトリ|\ directory|\ folder|\ dir)* ]]; do
    [[ ${(L)match[2]} == (only|the|this|current|each|all|my|a|an|sub|empty|hidden|new|old) || $lcmd == *${(L)match[2]}* ]] || missing+=($match[2])
    rest=$match[1]
  done
  if [[ $lquery == (#b)*\ in\ ([a-z0-9_.~/-]##)* && ${match[1]} != (the|a|an|this|current|my|all|each) ]]; then
    [[ $lcmd == *${match[1]}* ]] || missing+=($match[1])
  fi
  # 引用された語: "foo" / 「foo」
  rest=$query
  while [[ $rest == (#b)*\"([^\"]##)\"* ]]; do
    [[ $lcmd == *${(L)match[1]}* ]] || missing+=($match[1])
    rest=${rest%\"$match[1]\"*}
  done
  rest=$query
  while [[ $rest == (#b)*「([^」]##)」* ]]; do
    [[ $lcmd == *${(L)match[1]}* ]] || missing+=($match[1])
    rest=${rest%「$match[1]」*}
  done
  (( $#missing )) && print -r -- "the command ignores values from the request: ${(j:, :)missing}"

  # 頼まれていないパッケージ導入
  if [[ $cmd =~ '(brew|npm|pip3?|gem)[[:space:]]+(tap|install|i)[[:space:]]' ]] && \
     [[ ! $lquery =~ '(install|インストール|導入|入れ)' ]]; then
    print -r -- 'do not install packages; the request did not ask for installation'
  fi

  # 対象範囲のチェック: 頼まれていないのにホームやルートを対象にしていないか
  local home_words='(ホーム|home|~|\$HOME|ユーザ|download|ダウンロード|desktop|デスクトップ|document|書類|ドキュメント|library|ライブラリ|\.ssh|\.zshrc|dotfile|picture|ピクチャ|写真|movies|music|ミュージック|icloud|ゴミ箱|trash|xcode|deriveddata)'
  if [[ $cmd =~ '(^|[[:space:]=])(~|\$HOME)(/|[[:space:]]|$)' ]] && [[ ! ${(L)query} =~ $home_words ]]; then
    print -r -- 'the request did not mention the home directory; use the current directory (.) instead of ~'
  fi
  if [[ $cmd =~ '(^|[;&|[:space:]])(find|du|grep[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*[[:space:]]+[^[:space:]]+)[[:space:]]+/([[:space:]]|$)' ]] && \
     [[ ! ${(L)query} =~ '(ルート|root|全体|システム|system|/)' ]]; then
    print -r -- 'the request did not ask to search the whole disk; use the current directory (.) instead of /'
  fi
}

_fmc_check_danger() {
  emulate -L zsh
  local cmd=$1 re
  for re in $_FMC_DANGER_REGEX; do
    [[ $cmd =~ $re ]] && return 0
  done
  # rm -r / rm -f をルート・ホーム・ワイルドカード全体に対して実行
  local -a toks=(${(z)cmd})
  local i t in_rm=0 recursive=0
  for (( i = 1; i <= $#toks; i++ )); do
    t=${toks[i]}
    case $t in
      (rm) in_rm=1; recursive=0 ;;
      ('|'|'||'|'&&'|';'|'&') in_rm=0 ;;
      (-*) (( in_rm )) && [[ $t == -*[rRf]* ]] && recursive=1 ;;
      (*)
        if (( in_rm && recursive )) && [[ $t == ('/'|'/*'|'~'|'~/'|'~/*'|'$HOME'|'$HOME/'|'$HOME/*'|'"$HOME"'|'"$HOME"/*'|'*'|'./*'|'.'|'./'|'..'|'../*'|'.*'|'/Users'|'/Users/'*|'/System'*|'/Applications'|'/Library'|'/usr'|'/bin'|'/etc'|'/private'*) ]]; then
          return 0
        fi ;;
    esac
  done
  return 1
}

# 機械的に直せる誤りを自動修正する
_fmc_autofix() {
  emulate -L zsh
  setopt extended_glob
  local cmd=$1 query=$2 app
  # find の -name A -o -name B を括弧でまとめる
  if [[ $cmd != *'\('* && $cmd =~ '(-i?name [^ ]+( -o -i?name [^ ]+)+)' ]]; then
    cmd=${cmd/$MATCH/\\( $MATCH \\)}
  fi
  if [[ ${commands[sed]} == /usr/bin/sed ]]; then
    # BSD sed -i にはバックアップ拡張子 (空文字列) が必要
    cmd=${cmd//(#b)(sed[[:space:]]##)-i([[:space:]]##)([^\'\"[:space:]-])/${match[1]}-i \'\'${match[2]}${match[3]}}
    cmd=${cmd//(#b)(sed[[:space:]]##)-i([[:space:]]##)([\'\"][^\'\"]##[\'\"][[:space:]]##[^\'\"[:space:]-])/${match[1]}-i \'\'${match[2]}${match[3]}}
  fi
  # BSD xargs は -I {}
  [[ $cmd == *'{}'* ]] && cmd=${cmd//xargs -i /xargs -I {} }
  # lsof :PORT には -i が必要
  cmd=${cmd//(#b)lsof -t :([0-9]##)/lsof -ti :${match[1]}}
  cmd=${cmd//(#b)lsof :([0-9]##)/lsof -i :${match[1]}}
  # zsh の $path 配列
  cmd=${cmd//print -l \$PATH/print -l \$path}
  # インターフェース名の省略
  [[ $cmd == (ipconfig getifaddr|networksetup -getairportnetwork) ]] && cmd+=" en0"
  # 空白を含むアプリ名をクォート (open -a Google Chrome)
  if [[ $cmd == (#b)open\ -a\ ([A-Za-z0-9]##\ [A-Za-z0-9 ]##)(|\ *) ]]; then
    local -a words=(${=match[1]})
    local i
    for (( i = $#words; i >= 2; i-- )); do
      app="${(j: :)words[1,i]}"
      if [[ -d "/Applications/${app}.app" || -d "/System/Applications/${app}.app" ]]; then
        cmd="open -a \"${app}\" ${(j: :)words[i+1,-1]} ${match[2]}"
        cmd=${${cmd//  ##/ }%% #}
        break
      fi
    done
  fi
  # 「N日以内」がひとつだけの依頼で、-mtime -M がひとつだけなら M を N に揃える
  local nq=${query//[[:space:]]/}
  local -a days=(${(M)${(s: :)${nq//[^0-9日以内]/ }}:#[0-9]##日以内})
  if (( $#days == 1 )) && [[ $cmd == (#b)(*)-mtime\ -([0-9]##)(*) && $match[1] != *-mtime* && $match[3] != *-mtime* ]]; then
    cmd="${match[1]}-mtime -${days[1]%日以内}${match[3]}"
  fi
  print -r -- "$cmd"
}

# コマンドを1つ生成する
#   local: fm (オンデバイス) / cloud: ショートカット経由のクラウドモデル
#   cloud のショートカットは入力をそのままモデルに渡すものを想定し、instructions も入力に含める
_fmc_generate() {
  emulate -L zsh
  local prompt=$1 instructions=$2 sampling=${3:-greedy} backend=${4:-local} raw
  if [[ $backend == cloud ]]; then
    # 失敗理由 (利用上限など) は標準エラーに出す
    local errf=$(mktemp -t fmc) rc=0
    raw=$(print -r -- "${instructions}"$'\n\n'"${prompt}" |
      shortcuts run "$FMC_SHORTCUT_NAME" --input-path - --output-path - --output-type public.plain-text 2>$errf) || rc=1
    [[ -n ${raw//[[:space:]]/} ]] || rc=1
    (( rc )) && [[ -s $errf ]] && print -r -- "   ${$(<$errf)//$'\n'/ }" >&2
    rm -f $errf
    (( rc )) && return 1
  else
    local -a opts=(--no-stream)
    [[ $sampling == greedy ]] && opts+=(--greedy)
    raw=$(fm respond $opts --instructions "$instructions" "$prompt") || return 1
  fi
  _fmc_sanitize "$raw"
}

# --- メイン関数 ---
fmc() {
  emulate -L zsh
  setopt extended_glob

  local auto_exec=false print_only=false verbose=false backend=$FMC_BACKEND
  while (( $# )); do
    case "$1" in
      --history|-H)
        _fmc_show_history
        return 0
        ;;
      --clear-history)
        rm -f "$FMC_HISTORY_FILE"
        print -r -- "✅ 履歴を削除しました"
        return 0
        ;;
      --help|-h)
        cat <<'EOF'
fmc - Foundation Model Command translator

使い方:
  fmc "自然言語でコマンドを説明"     コマンドを生成してzshバッファに配置
  fmc -y "説明"                      確認なしで即実行 (破壊的な操作は確認あり)
  fmc -p "説明"                      コマンドだけを標準出力に出す (検証の問題が残ると終了コード 2)
  fmc -v "説明"                      参照した例文と検証の過程を表示
  fmc -c "説明"                      クラウドのモデル (ショートカット経由) で生成
  fmc -l "説明"                      オンデバイスのモデル (fm) で生成
  fmc --history                      生成履歴を表示
  fmc --clear-history                履歴を削除
  fmc --help                         このヘルプを表示

環境変数:
  FMC_HISTORY_FILE    履歴ファイルのパス (デフォルト: ~/.fmc_history)
  FMC_MAX_HISTORY     最大履歴行数 (デフォルト: 100)
  FMC_MAX_RETRIES     検証エラー時の再生成回数 (デフォルト: 3)
  FMC_NUM_EXAMPLES    few-shot に使う例文の数 (デフォルト: 8)
  FMC_EXAMPLES_FILE   例文バンク (デフォルト: fmc.zsh と同じ場所の examples.tsv)
  FMC_RULES_FILE      意味的な検証ルール (デフォルト: fmc.zsh と同じ場所の rules.tsv)
  FMC_BACKEND         生成に使うモデル: local (fm、既定) / cloud (ショートカット経由)
  FMC_SHORTCUT_NAME   cloud で呼ぶショートカット名 (デフォルト: ask-cloud-model)
  FMC_CLOUD_NUM_EXAMPLES  cloud で渡す例文の数 (デフォルト: 0)
  FMC_STATS_FILE      設定すると、生成回数・残った問題数・使ったモデルを1行ずつ追記する (評価用)

例:
  fmc "ポート3000のプロセスを殺す"
  fmc "カレントディレクトリの.pyファイルの行数を数える"
  fmc -y "今日の日付を表示"
EOF
        return 0
        ;;
      -y|--yes)     auto_exec=true; shift ;;
      -p|--print)   print_only=true; shift ;;
      -v|--verbose) verbose=true; shift ;;
      -c|--cloud)   backend=cloud; shift ;;
      -l|--local)   backend=local; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  # 進捗メッセージは -p のとき標準エラーへ
  local out=1
  $print_only && out=2

  # --- 入力チェック ---
  if [[ -z "$*" ]]; then
    print -r -- "$(_fmc_c yellow)使い方: fmc \"実行したいコマンドの説明\"$(_fmc_c reset)" >&2
    print -r -- "$(_fmc_c dim)例: fmc \"カレントディレクトリのファイルをサイズ順に表示\"$(_fmc_c reset)" >&2
    return 1
  fi

  local query="$*"

  # --- 生成に使うコマンドの存在チェック ---
  if [[ $backend != (local|cloud) ]]; then
    print -r -- "$(_fmc_c red)❌ FMC_BACKEND は local か cloud を指定してください: ${backend}$(_fmc_c reset)" >&2
    return 1
  fi
  if [[ $backend == cloud ]] && ! command -v shortcuts &>/dev/null; then
    print -r -- "$(_fmc_c yellow)⚠️  'shortcuts' コマンドが無いため、オンデバイスのモデルを使います$(_fmc_c reset)" >&2
    backend=local
  fi
  if [[ $backend == local ]] && ! command -v fm &>/dev/null; then
    print -r -- "$(_fmc_c red)❌ 'fm' コマンドが見つかりません。macOS 26 以降が必要です。$(_fmc_c reset)" >&2
    return 1
  fi

  if ! $print_only; then
    if [[ $backend == cloud ]]; then
      print -r -- "$(_fmc_c dim)☁️  コマンドを生成中 (クラウド: ${FMC_SHORTCUT_NAME})...$(_fmc_c reset)"
    else
      print -r -- "$(_fmc_c dim)${FMC_ICON:-✨} コマンドを生成中...$(_fmc_c reset)"
    fi
  fi

  # --- few-shot 付きの instructions を組み立て ---
  local REPLY
  local -a reply
  _fmc_select_examples "$query"
  local examples=$REPLY match_score=${reply[1]}
  local local_instructions=$_FMC_INSTRUCTIONS cloud_instructions=$_FMC_INSTRUCTIONS
  [[ -n $examples ]] && local_instructions+=$'\n\nExamples:\n\n'"${examples}"
  # クラウドのモデルは例文に引きずられて精度が下がるので、既定では例文を渡さない
  if (( FMC_CLOUD_NUM_EXAMPLES > 0 )); then
    _fmc_select_examples "$query" $FMC_CLOUD_NUM_EXAMPLES
    [[ -n $REPLY ]] && cloud_instructions+=$'\n\nExamples:\n\n'"${REPLY}"
  fi
  local instructions=$local_instructions
  if [[ $backend == cloud ]]; then
    instructions=$cloud_instructions
    (( FMC_CLOUD_NUM_EXAMPLES > 0 )) && examples=$REPLY || examples=""
  fi
  if $verbose; then
    print -r -- "$(_fmc_c dim)── 参照した例文 ──"$'\n'"${examples}$(_fmc_c reset)" >&$out
  fi

  # --- 生成 → 検証 → 再生成 ---
  local prompt="Request: ${query}
Command:"
  local cmd best_cmd="" attempt problems best_problems="" history_note="" sampling=greedy fixed
  local -i best_count=999 count tries=0
  local -A seen_cmds
  for (( attempt = 0; attempt <= FMC_MAX_RETRIES; attempt++ )); do
    (( tries++ ))
    local -i gen_ok=0
    cmd=$(_fmc_generate "$prompt" "$instructions" $sampling $backend) && gen_ok=1
    # クラウドは回数制限やネットワークで失敗しうるので、オンデバイスに切り替えて続ける
    if (( ! gen_ok )) && [[ $backend == cloud ]] && command -v fm &>/dev/null; then
      print -r -- "$(_fmc_c yellow)⚠️  クラウドでの生成に失敗したため、オンデバイスのモデルに切り替えます$(_fmc_c reset)" >&2
      backend=local instructions=$local_instructions
      cmd=$(_fmc_generate "$prompt" "$instructions" $sampling $backend) && gen_ok=1
    fi
    if (( ! gen_ok )); then
      print -r -- "$(_fmc_c red)❌ コマンドの生成に失敗しました$(_fmc_c reset)" >&2
      return 1
    fi

    if [[ ${(U)cmd} == NOT_A_COMMAND* ]]; then
      cmd=NOT_A_COMMAND problems="" count=0
      # 例文とよく一致する (= 端末操作らしい) のに NOT_A_COMMAND なら一度だけ問い直す
      if (( attempt == 0 && match_score >= 5.5 )); then
        problems="this is a terminal task; write a command" count=1
      fi
    elif [[ -z $cmd ]]; then
      problems="empty output" count=1
    else
      fixed=$(_fmc_autofix "$cmd" "$query")
      if $verbose && [[ $fixed != $cmd ]]; then
        print -r -- "$(_fmc_c dim)[自動修正] ${cmd} → ${fixed}$(_fmc_c reset)" >&$out
      fi
      cmd=$fixed
      problems=$(_fmc_validate "$cmd" "$query")
      if _fmc_check_danger "$cmd"; then
        problems="this command is destructive and affects far more than requested; target only what the request describes${problems:+$'\n'$problems}"
      fi
      count=${#${(f)problems}}
    fi

    if $verbose; then
      print -r -- "$(_fmc_c dim)[試行 $((attempt + 1))] ${cmd}$(_fmc_c reset)" >&$out
      [[ -n $problems ]] && print -rl -- "$(_fmc_c dim)  問題: "${^${(f)problems}}"$(_fmc_c reset)" >&$out
    fi

    if (( count < best_count )); then
      best_cmd=$cmd best_problems=$problems best_count=$count
    fi
    (( count == 0 )) && break

    # 同じ誤答を繰り返したらサンプリングに切り替えて多様性を出す
    [[ -n ${seen_cmds[$cmd]} ]] && sampling=sample
    seen_cmds[$cmd]=1

    # 問題点をフィードバックして再生成
    history_note+="Wrong answer: ${cmd}
Problem: ${problems//$'\n'/; }
"
    prompt="Request: ${query}
${history_note}Write a corrected command that fixes these problems. Answer with the command only.
Command:"
  done
  cmd=$best_cmd problems=$best_problems
  [[ -n $FMC_STATS_FILE ]] && print -r -- "${tries}"$'\t'"${#${(f)problems}}"$'\t'"${backend}" >> "$FMC_STATS_FILE"

  # --- NOT_A_COMMAND チェック ---
  if [[ ${(U)cmd} == NOT_A_COMMAND* ]]; then
    print -r -- "$(_fmc_c yellow)⚠️  コマンドに変換できない入力です。ターミナル操作の説明を入力してください。$(_fmc_c reset)" >&2
    return 1
  fi

  if [[ -z "$cmd" ]]; then
    print -r -- "$(_fmc_c red)❌ 空のコマンドが生成されました$(_fmc_c reset)" >&2
    return 1
  fi

  # --- 危険パターンチェック ---
  if _fmc_check_danger "$cmd"; then
    {
      print
      print -r -- "$(_fmc_c red)$(_fmc_c bold)🚨 危険なコマンドが検出されました！$(_fmc_c reset)"
      print -r -- "$(_fmc_c red)   ${cmd}$(_fmc_c reset)"
      print
      print -r -- "$(_fmc_c yellow)このコマンドはシステムに重大な損害を与える可能性があります。$(_fmc_c reset)"
      print -r -- "$(_fmc_c dim)実行したい場合は手動で入力してください。$(_fmc_c reset)"
    } >&2
    _fmc_log_history "$query" "[BLOCKED] $cmd"
    return 1
  fi

  _fmc_log_history "$query" "$cmd"

  if $print_only; then
    print -r -- "$cmd"
    if [[ -n $problems ]]; then
      print -r -- "⚠️  ${problems//$'\n'/; }" >&2
      return 2
    fi
    return 0
  fi

  # --- 結果を表示 ---
  print
  print -r -- "$(_fmc_c green)$(_fmc_c bold)✅ 生成されたコマンド:$(_fmc_c reset)"
  print -r -- "   $(_fmc_c cyan)$(_fmc_c bold)${cmd}$(_fmc_c reset)"
  if [[ -n $problems ]]; then
    print -r -- "$(_fmc_c yellow)⚠️  検証で問題が残っています。実行前に確認してください:$(_fmc_c reset)"
    print -rl -- "   $(_fmc_c yellow)• "${^${(f)problems}}"$(_fmc_c reset)"
  fi
  print

  # --- 実行モード ---
  if $auto_exec; then
    if [[ -n $problems || $cmd =~ $_FMC_DESTRUCTIVE_REGEX ]]; then
      if ! read -q "?$(_fmc_c yellow)この操作は変更を伴う可能性があります。実行しますか? [y/N] $(_fmc_c reset)"; then
        print
        print -z -- "$cmd"
        return 1
      fi
      print
    fi
    print -r -- "$(_fmc_c dim)⚡ 実行中...$(_fmc_c reset)"
    print -r -- "$(_fmc_c dim)──────────────────────────────────────────$(_fmc_c reset)"
    eval "$cmd"
  else
    # zsh のコマンドラインバッファに配置（Enter で実行、編集も可能）
    print -z -- "$cmd"
  fi
}

# ============================================================================
# Zsh Line Editor (ZLE) ウィジェット & キーバインド (ポップアップ入力)
# ============================================================================

# ウィジェット多重起動防止フラグ
typeset -g _FMC_WIDGET_ACTIVE=0

# ミニバッファ入力ヘルパー (ESC / Ctrl-C で即時キャンセル、入力バッファの完全復元を保証)
_fmc_read_minibuf() {
  emulate -L zsh
  setopt extended_glob

  local prompt_text="$1"
  local init_val="$2"

  # ミニバッファ専用キーマップ (初回のみ作成)
  if ! bindkey -l _fmc_minibuf &>/dev/null; then
    bindkey -N _fmc_minibuf main
    # ESC, Ctrl-C, Ctrl-G で即座にキャンセル (send-break)
    bindkey -M _fmc_minibuf '^[' send-break
    bindkey -M _fmc_minibuf '\e' send-break
    bindkey -M _fmc_minibuf '^C' send-break
    bindkey -M _fmc_minibuf '^G' send-break
    # ミニバッファ入力中はウィジェット呼び出しキーを無効化 (二重起動防止)
    if [[ -n "$FMC_KEYBIND" ]]; then
      bindkey -M _fmc_minibuf "$FMC_KEYBIND" undefined-key
    fi
  fi

  local saved_buf="$BUFFER"
  local saved_cur="$CURSOR"
  integer stat=1

  # 過去の PREDISPLAY を累積させず、現在の入力行の直下にクリーンに表示する
  local +h PREDISPLAY="${LBUFFER}${RBUFFER}"$'\n'"$prompt_text"
  local +h POSTDISPLAY=""
  local +h LBUFFER="$init_val"
  local +h RBUFFER=""

  # ESC キーの検出待機時間を短縮 (ESC 単体で即座にキャンセル)
  local old_keytimeout=$KEYTIMEOUT
  KEYTIMEOUT=5

  zle split-undo
  integer changeno=$UNDO_CHANGE_NO
  integer savelim=$UNDO_LIMIT_NO
  UNDO_LIMIT_NO=$UNDO_CHANGE_NO

  {
    zle recursive-edit -K _fmc_minibuf
    stat=$?
    (( stat == 0 )) && REPLY="$BUFFER"
  } always {
    # どのような理由で終了しても、PREDISPLAY をリセットし元の BUFFER と CURSOR を完全復元
    PREDISPLAY=""
    POSTDISPLAY=""
    zle undo $changeno 2>/dev/null || true
    UNDO_LIMIT_NO=$savelim
    BUFFER="$saved_buf"
    CURSOR="$saved_cur"
    KEYTIMEOUT=$old_keytimeout
  }

  return $stat
}

_fmc_widget() {
  emulate -L zsh
  setopt extended_glob

  # すでにウィジェット実行中なら多重起動しない
  (( _FMC_WIDGET_ACTIVE )) && return 0
  _FMC_WIDGET_ACTIVE=1

  {
    local initial_query="$BUFFER"
    local initial_cursor="$CURSOR"
    local icon="${FMC_ICON:-✨}"
    # ANSI エスケープを含めないクリーンなプロンプト (文字化け・折り返し崩れ防止)
    local prompt_str="╭─ ${icon} fmc (自然言語からコマンド生成 / Esc: 取消)"$'\n'"╰─▶ 依頼: "

    local REPLY
    if ! _fmc_read_minibuf "$prompt_str" "$initial_query"; then
      BUFFER="$initial_query"
      CURSOR="$initial_cursor"
      zle -M "fmc: キャンセルしました"
      return 0
    fi

    local query="$REPLY"
    query="${query##[[:space:]]#}"
    query="${query%%[[:space:]]#}"

    if [[ -z "$query" ]]; then
      BUFFER="$initial_query"
      CURSOR="$initial_cursor"
      return 0
    fi

    # 生成中ステータスを表示して即時再描画 (zle -M は ANSI エスケープを解釈しないためプレーンテキストで渡す)
    local backend_msg=""
    [[ ${FMC_BACKEND:-local} == cloud ]] && backend_msg=" (クラウド)"
    zle -M "${icon} コマンドを生成中${backend_msg}..."
    zle -R

    # fmc -p でコマンドを生成 (stdout: コマンド, stderr: 警告/エラーメッセージ)
    local err_file=$(mktemp -t fmc_widget_err)
    local cmd
    cmd=$(fmc -p "$query" 2>"$err_file")
    local ret=$?
    local err_msg=""
    [[ -f "$err_file" ]] && err_msg=$(<"$err_file")
    rm -f "$err_file"

    # エラーメッセージから ANSI エスケープシーケンスを完全に除去
    [[ -n "$err_msg" ]] && err_msg=$(print -r -- "$err_msg" | sed -E $'s/\033\\[[0-9;]*[a-zA-Z]//g')
    err_msg="${err_msg##[[:space:]]#}"
    err_msg="${err_msg%%[[:space:]]#}"
    err_msg="${err_msg//$'\n'/; }"

    if (( ret == 0 )); then
      BUFFER="$cmd"
      CURSOR=${#BUFFER}
      zle -M "✅ 生成完了 (Enter で実行、編集も可能)"
    elif (( ret == 2 )); then
      # 生成成功したが検証の警告あり
      BUFFER="$cmd"
      CURSOR=${#BUFFER}
      zle -M "${err_msg:-⚠️  検証で問題が見つかりました}"
    else
      # 失敗、NOT_A_COMMAND、危険コマンドブロック
      BUFFER="$initial_query"
      CURSOR="$initial_cursor"
      zle -M "${err_msg:-❌ コマンドの生成に失敗しました}"
    fi
  } always {
    _FMC_WIDGET_ACTIVE=0
  }
}

# インタラクティブシェルの場合のみ ZLE ウィジェットとキーバインドを登録
if [[ -o interactive ]]; then
  zle -N fmc-widget _fmc_widget

  # 既定のキーバインド (^O: Ctrl+O)
  # 無効にしたい場合は FMC_KEYBIND="" を設定
  if [[ -n "$FMC_KEYBIND" ]]; then
    bindkey "$FMC_KEYBIND" fmc-widget
  fi
fi
