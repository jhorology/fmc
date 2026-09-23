#!/bin/zsh
# 使い方: zsh score.zsh [fmc.zsh] [eval.tsv]
#   各行 "リクエスト<TAB>正解の正規表現(ERE)[<TAB>NGの正規表現(任意)]" を fmc -p で生成して採点する
#   3列目 (NGの正規表現) があれば、それにマッチした場合は OK としない (偽陽性の排除用)
#   最後に、平均生成回数と、検証の問題が残ったまま出力された件数も表示する
zmodload zsh/datetime
src=${1:-${0:h}/fmc.zsh}
ev=${2:-${0:h}/eval.tsv}
source $src
export FMC_STATS_FILE=$(mktemp -t fmc_stats)
pass=0
total=0
t0=$EPOCHREALTIME
while IFS=$'\t' read -r q re neg; do
	((total++))
	cmd=$(fmc -p "$q" 2>/dev/null </dev/null) || { [[ -z $cmd ]] && cmd=NOT_A_COMMAND; }
	if print -r -- "$cmd" | grep -Eq -- "$re" && { [[ -z ${neg:-} ]] || ! print -r -- "$cmd" | grep -Eq -- "$neg"; }; then
		((pass++))
		mark=OK
	else mark=NG; fi
	printf '%s  %-36s => %s\n' $mark "$q" "$cmd"
done <$ev
tries=0 warned=0 runs=0
while IFS=$'\t' read -r t p; do
	((runs++, tries += t))
	((p > 0)) && ((warned++))
done <$FMC_STATS_FILE
rm -f $FMC_STATS_FILE
printf '\nSCORE %d/%d  (%.1fs)  平均生成回数 %.2f  警告付き %d件\n' $pass $total $((EPOCHREALTIME - t0)) $((runs ? tries * 1.0 / runs : 0)) $warned
