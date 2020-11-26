#!/bin/bash

set -e -x -o pipefail

# test for successful release build
dub build -b release --compiler=$DC -c $CONFIG

# test for successful 32-bit build
if [ "$DC" == "ldc2" ]; then
	dub build --arch=x86 --compiler=ldc2 -c $CONFIG
fi

dub test --compiler=$DC -c $CONFIG

if [ ${BUILD_EXAMPLE=1} -eq 1 ]; then
    for ex in $(\ls -1 examples/*.d); do
        echo "[INFO] Building example $ex"
        dub build --compiler=$DC --override-config eventcore/$CONFIG --single $ex
    done
    rm -rf examples/.dub/
    rm examples/*-example
fi
if [ ${RUN_TEST=1} -eq 1 ]; then
    for ex in `\ls -1 tests/*.d`; do
        echo "[INFO] Running test $ex"
        dub --temp-build --compiler=$DC --override-config eventcore/$CONFIG --single $ex
    done
fi
