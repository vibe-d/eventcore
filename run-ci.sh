#!/bin/bash

set -e -x -o pipefail

# test for successful release build
dub build -b release --arch=$ARCH --compiler=$DC -c $CONFIG

# test for successful 32-bit build
if [ "$DC" == "ldc2" ]; then
	dub build --arch=x86 --compiler=ldc2 -c $CONFIG
fi

dub test --arch=$ARCH --compiler=$DC -c $CONFIG

if [ ${BUILD_EXAMPLE=1} -eq 1 ]; then
    for ex in $(\ls -1 examples/*.d); do
        echo "[INFO] Building example $ex"
        dub build --arch=$ARCH --compiler=$DC --override-config eventcore/$CONFIG --single $ex
    done
    rm -rf examples/.dub/
    rm -f examples/*-example
    rm -f examples/*-example.exe
fi
if [ ${RUN_TEST=1} -eq 1 ]; then
    for ex in `\ls -1 tests/*.d`; do
        echo "[INFO] Running test $ex"
        # NOTE: timer and directory watcher tests tend to be flaky on macOS VMs
        dub --temp-build --arch=$ARCH --compiler=$DC --override-config eventcore/$CONFIG --single $ex \
            || dub --temp-build --arch=$ARCH --compiler=$DC --override-config eventcore/$CONFIG --single $ex
    done
fi
