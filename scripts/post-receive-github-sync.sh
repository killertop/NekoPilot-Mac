#!/usr/bin/env bash
set -euo pipefail

repository=/opt/git/NekoPilot-Mac.git
github_remote=github
zero=0000000000000000000000000000000000000000
refspecs=()

while read -r oldrev newrev refname; do
  case "$refname" in
    refs/heads/*|refs/tags/*)
      ;;
    *)
      continue
      ;;
  esac

  if [ "$newrev" = "$zero" ]; then
    refspecs+=(":$refname")
  else
    refspecs+=("$refname:$refname")
  fi
done

if [ "${#refspecs[@]}" -gt 0 ]; then
  # A receive can update several refs. Mirror them as one transaction so a
  # network/auth failure cannot leave GitHub with only part of the push.
  git --git-dir="$repository" push --atomic "$github_remote" "${refspecs[@]}"
fi
