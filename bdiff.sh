#!/usr/bin/env bash
set -euo pipefail

readelf -a $1 > /tmp/d1.tmp
readelf -a $2 > /tmp/d2.tmp
diff /tmp/d1.tmp /tmp/d2.tmp
