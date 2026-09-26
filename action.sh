#!/system/bin/sh
MODDIR=${0%*}
[ -d "$MODDIR" ] || MODDIR=.
T="$MODDIR/bin/tuner.sh"
cur=$(sh "$T" status | sed -n 's/^mode=//p')
case "$cur" in
  stock)  next=auto ;;
  auto)   next=perf ;;
  perf)   next=manual ;;
  manual) next=cap ;;
  *)      next=stock ;;
esac
sh "$T" set MODE "$next" >/dev/null 2>&1
echo "GPU mode: $cur -> $next"
