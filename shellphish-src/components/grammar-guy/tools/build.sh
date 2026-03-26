#!/bin/bash
#
set -e
set -x

export BASEDIR="$(realpath .)"
#
# 
if [ ! -d grammarinator ]; then
    git clone https://github.com/renatahodovan/grammarinator.git grammarinator
fi

pushd grammarinator
# [OSS-CRS glue] Pin to tag 23.7 — the patch was written against this version
# (verified: .gitignore blob e13ba77 matches tag 23.7)
git checkout 23.7 2>/dev/null || git fetch --tags && git checkout 23.7
git reset --hard
git apply "$(realpath ../patches/grammarinator/grammarinator_full.patch)"
popd

cd $BASEDIR

echo "Patches applied, state restored"
