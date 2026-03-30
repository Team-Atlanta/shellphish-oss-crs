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
# [OSS-CRS glue] Pin to 2025 Jun 9 commit — the exact version the patch was written for
git checkout 8fb170f8237eda017b402c98817777da7a796093
git reset --hard
git apply "$(realpath ../patches/grammarinator/grammarinator_full.patch)"
popd

cd $BASEDIR

echo "Patches applied, state restored"
