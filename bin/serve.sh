#!/system/bin/sh
# Unisoc Tuner standalone server - drive the module from any browser, no manager needed.
# serve.sh start|stop|status|url|loop
# overridable for offline testing: UT_PORT UT_TMP UT_LOG UT_WEB UT_MODDIR
#
# one connection at a time: netcat writes the request into $REQF and reads the
# response from $FIFO, which keeps the two directions on separate descriptors
# (a plain shell pipeline can only wire one of them).

HERE=${0%*}
[ -d "$HERE" ] || HERE=.
case "$HERE" in
  */bin) MODDIR=${UT_MODDIR:-$(dirname "$(dirname "$HERE")")} ;;
  *)     MODDIR=${UT_MODDIR:-$HERE} ;;
esac

PORT=${UT_PORT:-8765}
WEB=${UT_WEB:-$MODDIR/webroot}
TMPD=${UT_TMP:-/data/local/tmp}
LOGF=${UT_LOG:-/data/adb/unisoc-tuner.log}
TOKF=$TMPD/ut.serve.token
PIDF=$TMPD/ut.serve.pid
OUTF=$TMPD/ut.serve.out
REQF=$TMPD/ut.serve.req
FIFO=$TMPD/ut.serve.fifo
RUNS="tuner system dvfs doctor"

tok() { [ -f "$TOKF" ] && cat "$TOKF" 2>/dev/null; }
newtok() { head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
url() { echo "http://127.0.0.1:$PORT/?t=$(tok)"; }
L() { echo "$(date '+%m-%d %H:%M:%S') serve $*" >> "$LOGF" 2>/dev/null; return 0; }

nc_bin() {
  if command -v nc >/dev/null 2>&1; then echo nc
  elif toybox nc 2>&1 | grep -qi usage; then echo "toybox nc"
  fi
}

urldecode() { printf '%b' "$(printf '%s' "$1" | sed 's/+/ /g; s/%/\\x/g')"; }

resp() {
  body=$3
  len=$(printf '%s' "$body" | wc -c | tr -d ' ')
  printf 'HTTP/1.0 %s\r\nContent-Type: %s\r\nContent-Length: %s\r\nX-Exit: %s\r\nConnection: close\r\n\r\n%s' \
    "$1" "$2" "$len" "${4:-0}" "$body"
}

static_file() {
  n=${1#/}
  [ -z "$n" ] && n=index.html
  case "$n" in index.html|app.js|style.css) ;; *) return 1 ;; esac
  [ -f "$WEB/$n" ] || return 1
  case "$n" in
    *.css) ct=text/css ;;
    *.js)  ct=application/javascript ;;
    *)     ct=text/html ;;
  esac
  printf 'HTTP/1.0 200 OK\r\nContent-Type: %s\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' \
    "$ct" "$(wc -c < "$WEB/$n" | tr -d ' ')"
  cat "$WEB/$n"
}

where_body() {
  printf 'dir=%s\nver=%s\ncpu=%s\ndv=%s\ndoc=%s\n' \
    "$MODDIR" \
    "$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)" \
    "$([ -f "$MODDIR/bin/system.sh" ] && echo 1 || echo 0)" \
    "$([ -f "$MODDIR/bin/dvfs.sh" ] && echo 1 || echo 0)" \
    "$([ -f "$MODDIR/bin/doctor.sh" ] && echo 1 || echo 0)"
}

send() {
  req=$(sed -n '1p' "$1" 2>/dev/null | tr -d '\r')
  [ -n "$req" ] || return 0
  path=${req#* }
  path=${path%% *}
  file=${path%%\?*}
  qs=${path#*\?}
  [ "$qs" = "$path" ] && qs=
  t=; run=; args=
  if [ -n "$qs" ]; then
    for pair in $(printf '%s' "$qs" | tr '&' ' '); do
      case "${pair%%=*}" in
        t)    t=$(urldecode "${pair#*=}") ;;
        run)  run=$(urldecode "${pair#*=}") ;;
        args) args=$(urldecode "${pair#*=}") ;;
      esac
    done
  fi

  case "$file" in
    /api)
      if [ -z "$t" ] || [ "$t" != "$(tok)" ]; then
        L "rejected a request without a valid token"
        resp 403 text/plain "bad or missing token" 1
      elif [ -z "$run" ] || ! printf ' %s ' "$RUNS" | grep -q " $run "; then
        resp 400 text/plain "unknown script" 1
      elif [ -n "$(printf '%s' "$args" | tr -d 'a-zA-Z0-9' | tr -d ' _:.,-')" ]; then
        resp 400 text/plain "bad characters in args" 1
      else
        body=$(sh "$MODDIR/bin/$run.sh" $args 2>&1)
        resp 200 text/plain "$body" "$?"
      fi ;;
    /where)
      if [ -z "$t" ] || [ "$t" != "$(tok)" ]; then
        resp 403 text/plain "bad or missing token" 1
      else
        resp 200 text/plain "$(where_body)" 0
      fi ;;
    /|/index.html|/app.js|/style.css)
      static_file "$file" || resp 404 text/plain "not found" 1 ;;
    *)
      resp 404 text/plain "not found" 1 ;;
  esac
}

flush_fifo() {
  ( cat <&3 >/dev/null 2>&1 & c=$!; sleep 0.2; kill $c 2>/dev/null ) 2>/dev/null
  return 0
}

serve_loop() {
  NC=$(nc_bin)
  if [ -z "$NC" ]; then
    echo "no netcat on this device (nc or toybox nc) - standalone mode unavailable"
    return 1
  fi
  rm -f "$FIFO"
  if ! mkfifo "$FIFO" 2>/dev/null; then
    echo "cannot create $FIFO - standalone mode unavailable"
    return 1
  fi
  exec 3<>"$FIFO" || { echo "cannot open $FIFO"; return 1; }
  : > "$OUTF"
  L "standalone server on port $PORT, module $MODDIR"
  pflag=1
  while :; do
    : > "$REQF"
    if [ "$pflag" = 1 ]; then
      $NC -l -p "$PORT" < "$FIFO" > "$REQF" 2>>"$OUTF" &
    else
      $NC -l "$PORT" < "$FIFO" > "$REQF" 2>>"$OUTF" &
    fi
    ncp=$!

    prev=-1; i=0
    while [ $i -lt 30 ]; do
      cur=$(wc -c < "$REQF" 2>/dev/null | tr -d ' ')
      [ -n "$cur" ] && [ "$cur" != 0 ] && [ "$cur" = "$prev" ] && break
      prev=$cur
      sleep 0.1; i=$((i + 1))
    done

    if [ -n "$(sed -n '1p' "$REQF" 2>/dev/null)" ]; then
      if ! send "$REQF" >&3; then
        flush_fifo
      fi
    fi

    wait "$ncp" 2>/dev/null
    if [ $? != 0 ]; then
      if [ "$pflag" = 1 ]; then pflag=0; else pflag=1; fi
      sleep 1
    fi
  done
}

start() {
  if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; then
    echo "already running: $(url)"
    return 0
  fi
  if [ -z "$(nc_bin)" ]; then
    echo "no netcat on this device (nc or toybox nc) - standalone mode unavailable"
    return 1
  fi
  newtok > "$TOKF" 2>/dev/null
  chmod 600 "$TOKF" 2>/dev/null
  sh "$0" loop >> "$OUTF" 2>&1 &
  echo $! > "$PIDF"
  sleep 1
  if kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; then
    echo "unisoc tuner standalone on port $PORT"
    echo "url $(url)"
    echo "open it in any browser, or:"
    echo "  am start -a android.intent.action.VIEW -d \"$(url)\""
  else
    rm -f "$PIDF"
    echo "server did not start - see $OUTF"
    return 1
  fi
}

stop() {
  if [ -f "$PIDF" ]; then
    kill "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null
    rm -f "$PIDF" "$FIFO"
    echo "stopped"
  else
    echo "not running"
  fi
}

status() {
  if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; then
    echo "running, pid $(cat "$PIDF")"
    url
  else
    echo "not running"
  fi
}

case "$1" in
  start)  start ;;
  stop)   stop ;;
  status) status ;;
  url)    url ;;
  loop)   serve_loop ;;
  *)      echo "usage: serve.sh start|stop|status|url" ;;
esac
