#!/bin/sh

cd JasSwift

set -e -x

# Run the built binary directly (not `swift run`) so environment variables
# like JAS_PATH_B propagate to the app process. `swift run` does not forward
# them to the launched GUI binary.
swift build
exec .build/debug/Jas
