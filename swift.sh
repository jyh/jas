#!/bin/sh

cd JasSwift

set -e -x

swift build
.build/debug/Jas
