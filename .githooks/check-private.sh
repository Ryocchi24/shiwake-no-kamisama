#!/bin/bash
# お客さんのデータがGitHubに上がらないようにするチェック。
# 使い方: check-private.sh staged        … コミットする内容（git add した内容）を調べる
#         check-private.sh range A B     … プッシュする範囲（AからBまで）の変更を調べる
# 引っかかったら 1 を返して、コミット／プッシュを止める。
#
# 調べること
#   1. 試算表・領収書・マスタになりうるファイル（CSV・Excel・PDF・写真など）が含まれていないか
#   2. 「禁止ワード」（お客さんの会社名・銀行名など）が含まれていないか
#      一覧はこのリポジトリの直下の .private-words（GitHubには上げない）に1行1語で書く
#   3. 科目マスタや対応表のようなデータのかたまりが、プログラムに書き込まれていないか

mode="$1"; from="$2"; to="$3"
root="$(git rev-parse --show-toplevel)"
cd "$root" || exit 1

if [ "$mode" = "staged" ]; then
  files=$(git diff --cached --name-only --diff-filter=ACMR)
  added=$(git diff --cached -U0 --diff-filter=ACMR | grep -a '^+' | grep -av '^+++')
else
  files=$(git diff --name-only --diff-filter=ACMR "$from" "$to")
  added=$(git diff -U0 --diff-filter=ACMR "$from" "$to" | grep -a '^+' | grep -av '^+++')
fi

problems=""

# 1. ファイルの種類
while IFS= read -r f; do
  [ -z "$f" ] && continue
  lower=$(printf '%s' "$f" | tr 'A-Z' 'a-z')
  case "$lower" in
    samples/*|data/*|private/*)
      problems+="  ・作業用フォルダのファイル: $f"$'\n' ;;
    *.csv|*.tsv|*.xlsx|*.xlsm|*.xls|*.pdf|*.jpg|*.jpeg|*.heic|*.heif|*.tif|*.tiff|*.zip)
      problems+="  ・お客さんのデータになりうるファイル: $f"$'\n' ;;
    *.json)
      case "$f" in
        package.json|package-lock.json|capacitor.config.json|.claude/launch.json|*/Contents.json) ;;
        *) problems+="  ・データの可能性があるJSON: $f"$'\n' ;;
      esac ;;
    *.png)
      case "$f" in
        docs/*.png|ios/App/App/Assets.xcassets/*) ;;
        *) problems+="  ・アイコン以外の画像: $f"$'\n' ;;
      esac ;;
  esac
done <<< "$files"

# 2. 禁止ワード
if [ -f .private-words ]; then
  while IFS= read -r w; do
    w="${w%%#*}"; w="$(printf '%s' "$w" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$w" ] && continue
    if printf '%s\n' "$added" | grep -aqF -- "$w"; then
      problems+="  ・禁止ワードが含まれています（一覧: .private-words）"$'\n'
      break
    fi
  done < .private-words
fi

# 3. 科目マスタ・対応表のようなデータのかたまり
n_json=$(printf '%s\n' "$added" | grep -acE '"(code|srcCode|srcName|name)"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,[[:space:]]*"(name|code|srcName|srcCode)"')
n_csv=$(printf '%s\n' "$added" | grep -acE '^\+[[:space:]]*"?[0-9]{2,6}"?[[:space:]]*,[[:space:]]*"?[^,[:space:]]')
if [ "$n_json" -ge 10 ] || [ "$n_csv" -ge 10 ]; then
  problems+="  ・科目マスタや対応表のようなデータが、まとまって書き込まれています（${n_json}件／${n_csv}件）"$'\n'
fi

if [ -n "$problems" ]; then
  echo "" >&2
  echo "【止めました】お客さんのデータがGitHubに上がる可能性があります。" >&2
  printf '%s' "$problems" >&2
  echo "" >&2
  echo "お客さんのデータは、プログラムではなく、各端末でファイルから読み込む形にしてください。" >&2
  echo "作業用のファイルは samples/ に置けば、GitHubには上がりません。" >&2
  exit 1
fi
exit 0
