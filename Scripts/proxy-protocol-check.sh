#!/bin/sh
# Scripts/proxy-protocol-check.sh [--emulate]
#
# Puts a real balancer in front of the kit's server and checks the client address a handler sees.
#
#   1. starts the kit's server (the skipped-by-default test BalancerCheckServer) on 127.0.0.1:18080, behind the PROXY
#      protocol, trusting loopback;
#   2. starts HAProxy with Scripts/proxy-protocol/haproxy.cfg: port 18081 sends PROXY v2, port 18082 sends PROXY v1, and
#      each claims the source address named in the request's X-Test-Src header;
#   3. for IPv4 and IPv6 claimed addresses, on both versions, requests /who and expects exactly
#      `remote=<claimed address>;peer=127.0.0.1` (the handler sees the client the balancer named, and the socket's peer
#      separately);
#   4. checks that a request straight to the kit's port, from a loopback peer that sends no PROXY header, is refused.
#
# HAProxy comes from, in order: a local `haproxy` on PATH; `docker` (Linux hosts: it needs the host network); or, only with
# --emulate, a Python stand-in (Scripts/proxy-protocol/emulated_balancer.py) that exercises everything but HAProxy itself.
# With none of them the script says so and exits 3. Exit 0: every check passed. Exit 1: a check failed.
#
# STATUS: UNRUN against HAProxy. Where this was written there was no haproxy, no nginx and no docker; only the --emulate
# path has been run (see RigFindings.md for its result).
set -eu
cd "$(git rev-parse --show-toplevel)"

EMULATE=0
[ "${1:-}" = "--emulate" ] && EMULATE=1
BACKEND=18080; V2=18081; V1=18082
WORK="$(mktemp -d)"
PIDS=""
DOCKER_NAME=""
cleanup() {
  touch "$WORK/stop"
  for p in $PIDS; do kill "$p" 2>/dev/null || true; done
  if [ -n "$DOCKER_NAME" ]; then docker rm -f "$DOCKER_NAME" >/dev/null 2>&1 || true; fi
  wait 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# 1. The kit's side.
PROXY_CHECK_BACKEND_PORT="$BACKEND" PROXY_CHECK_READY="$WORK/ready" PROXY_CHECK_STOP="$WORK/stop" \
  swift test --filter BalancerCheckServer >"$WORK/kit.log" 2>&1 &
KIT=$!
PIDS="$PIDS $KIT"
i=0
while [ ! -f "$WORK/ready" ]; do
  if ! kill -0 "$KIT" 2>/dev/null; then echo "the kit's server exited before it was up:" >&2; tail -40 "$WORK/kit.log" >&2; exit 1; fi
  i=$((i + 1))
  if [ "$i" -gt 1200 ]; then echo "the kit's server did not come up:" >&2; cat "$WORK/kit.log" >&2; exit 1; fi
  sleep 0.5
done
echo "kit server up on 127.0.0.1:$BACKEND"

# 2. The balancer.
if [ "$EMULATE" = "0" ] && command -v haproxy >/dev/null 2>&1; then
  haproxy -f Scripts/proxy-protocol/haproxy.cfg -db >"$WORK/balancer.log" 2>&1 &
  PIDS="$PIDS $!"
  BALANCER="haproxy $(haproxy -v 2>/dev/null | head -1)"
elif [ "$EMULATE" = "0" ] && command -v docker >/dev/null 2>&1; then
  DOCKER_NAME="proxy-protocol-check-$$"
  docker run --rm --name "$DOCKER_NAME" --network host \
    -v "$PWD/Scripts/proxy-protocol/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" haproxy:3.0 >"$WORK/balancer.log" 2>&1 &
  PIDS="$PIDS $!"
  BALANCER="docker haproxy:3.0"
elif [ "$EMULATE" = "1" ]; then
  python3 -I Scripts/proxy-protocol/emulated_balancer.py >"$WORK/balancer.log" 2>&1 &
  PIDS="$PIDS $!"
  BALANCER="EMULATED (python), not HAProxy"
else
  echo "no balancer: install haproxy, or use docker on Linux, or pass --emulate for the Python stand-in" >&2
  exit 3
fi
i=0
until curl -s -m 2 -o /dev/null -H "X-Test-Src: 192.0.2.1" "http://127.0.0.1:$V2/who"; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then echo "the balancer did not answer on $V2:" >&2; cat "$WORK/balancer.log" >&2; exit 1; fi
  sleep 0.5
done
echo "balancer: $BALANCER"

# 3. What the handler sees.
FAILED=0
check() { # name port claimed-address expected-canonical-text
  got="$(curl -s -m 5 -H "X-Test-Src: $3" "http://127.0.0.1:$2/who" || true)"
  want="remote=$4;peer=127.0.0.1"
  if [ "$got" = "$want" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$got', want '$want'"; FAILED=1; fi
}
check "v2, IPv4 client" "$V2" 203.0.113.77 203.0.113.77
check "v2, IPv6 client" "$V2" 2001:db8::77 2001:db8::77
check "v1, IPv4 client" "$V1" 203.0.113.78 203.0.113.78
check "v1, IPv6 client" "$V1" 2001:db8::78 2001:db8::78
check "v2, a different client on a new connection (nothing leaks between connections)" "$V2" 203.0.113.79 203.0.113.79

# 4. A loopback peer that sends no PROXY header is refused, not served as 127.0.0.1.
direct="$(curl -s -m 3 "http://127.0.0.1:$BACKEND/who" || true)"
if [ -z "$direct" ]; then
  echo "ok    a request straight to the kit with no PROXY header is refused"
else
  echo "FAIL  a direct request was served: '$direct'"
  FAILED=1
fi

exit "$FAILED"
