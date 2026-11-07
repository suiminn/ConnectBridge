#!/var/jb/bin/sh
# librespot --onevent hook (PoC): forward the Connect volume to the output route volume.
LOG=/var/mobile/poc/onevent.log
echo "$(date +%T) event=$PLAYER_EVENT volume=$VOLUME" >> "$LOG"
case "$PLAYER_EVENT" in
  volume_changed)
    T=$((VOLUME * 1000 / 65535))
    if [ "$T" -ge 1000 ]; then V=1.000; else V=0.$(printf %03d "$T"); fi
    /var/mobile/poc/routetool sysvol "$V" >> "$LOG" 2>&1
    ;;
esac
