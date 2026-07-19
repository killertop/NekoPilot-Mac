#!/usr/bin/env bash
set -euo pipefail

repository=/opt/git/NekoPilot-Mac.git
github_remote=github
zero=0000000000000000000000000000000000000000

while read -r oldrev newrev refname; do
  case "$refname" in
    refs/heads/*|refs/tags/*)
      ;;
    *)
      continue
      ;;
  esac

  if [ "$newrev" = "$zero" ]; then
    git --git-dir="$repository" push "$github_remote" ":$refname"
  else
    git --git-dir="$repository" push "$github_remote" "$refname:$refname"
  fi
done
