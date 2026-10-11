#!/bin/bash
# Check every stage of  SMO -> XIAO -> Pi (I2S) -> loopback -> Bluetooth -> car
# and say which one is broken.   Usage:  audio-check.sh [--fix]
. /usr/local/lib/auxlink/common.sh
[ -z "$CAR" ] && { echo "No car paired yet: open the setup page and pair the car."; exit 1; }
FIX=no; [ "$1" = "--fix" ] && FIX=yes
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; PROBLEM=yes; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
PROBLEM=no

echo "1. Music source -> Pi input (source: ${MUSIC_SOURCE:-wired})"
I2S=$(music_input)
if [ -z "$I2S" ]; then
  case "${MUSIC_SOURCE:-wired}" in
    bluetooth) bad "Bluetooth music source not connected or not streaming${SOURCE:+ ($SOURCE)}" ;;
    usbc) bad "USB-C input not found (reboot after choosing USB-C? source plugged into the Pi's USB-C?)" ;;
    *) bad "XIAO I2S input not found (overlay xiao-i2s-in loaded? arecord -l)" ;;
  esac
else
  rm -f /tmp/audio-check.wav
  timeout 2 pw-record --target "$I2S" /tmp/audio-check.wav 2>/dev/null
  rms=$(sox /tmp/audio-check.wav -n stat 2>&1 | awk '/RMS +amplitude/ {print $3}')
  if [ -z "$rms" ]; then bad "could not read the music input"
  elif awk "BEGIN{exit !($rms > 0.002)}"; then ok "audio arriving (RMS $rms)"
  else bad "input is silent (RMS $rms): source paused or volume 0? (wired/USB-C: is its output set to the Pi/XIAO? bluetooth: is a USB sound card still plugged into it? Android prefers USB)"; fi
fi

echo "2. Bluetooth link to the car"
if $BT "$CAR_ADAPTER" "$CAR" connected 2>/dev/null; then ok "car connected"
else bad "car not connected"; echo; exit 1; fi
in_call && warn "a call is in progress: the car pauses music on purpose"

echo "3. Music profile"
prof=$(timeout 5 pactl list cards | sed -n "/Name: $CARD/,/Active Profile/p" | awk -F': ' '/Active Profile/ {print $2}')
if [[ "$prof" == a2dp* ]]; then ok "profile $prof"
else bad "profile is '${prof:-none}', not a2dp-sink / a2dp-sink-sbc_xq"
     [ $FIX = yes ] && { echo "        fixing: opening the music channel"
       timeout 25 $BT "$CAR_ADAPTER" "$CAR" connect "$A2DP_SINK_UUID" >/dev/null 2>&1
       timeout 5 pactl set-card-profile "$CARD" a2dp-sink 2>/dev/null; sleep 3; }; fi

echo "4. Car output"
line=$(car_sink_line); SINK=$(echo "$line" | cut -f2); state=$(echo "$line" | awk '{print $NF}')
if [ -z "$SINK" ]; then bad "no car output exists"; echo; exit 1
elif [ "$state" = RUNNING ]; then ok "$SINK is RUNNING"
else warn "$SINK is $state"; fi
if [ "$(timeout 5 pactl get-sink-mute "$SINK" | awk '{print $2}')" = yes ]; then bad "car output is MUTED"
     [ $FIX = yes ] && timeout 5 pactl set-sink-mute "$SINK" 0
else ok "volume $(timeout 5 pactl get-sink-volume "$SINK" | grep -o '[0-9]*%' | head -1) (follows the car)"; fi

echo "5. Links inside the Pi"
links=$(timeout 5 pw-link -l 2>/dev/null); in_ok=no; out_ok=no
echo "$links" | grep -A2 "^$I2S:capture_FL" | grep -q "smo_capture:" &&
  echo "$links" | grep -A2 "^$I2S:capture_FR" | grep -q "smo_capture:" && in_ok=yes
echo "$links" | grep -A2 "^to_tesla:output_FL" | grep -q "bluez_output" &&
  echo "$links" | grep -A2 "^to_tesla:output_FR" | grep -q "bluez_output" && out_ok=yes
[ $in_ok = yes ] && ok "music input -> loopback" || bad "music input not linked to the loopback"
[ $out_ok = yes ] && ok "loopback -> car" || bad "loopback not linked to the car"
if [ $FIX = yes ] && { [ $in_ok = no ] || [ $out_ok = no ]; }; then
  echo "        fixing: restarting auxlink-audio"; systemctl --user restart auxlink-audio; sleep 6; fi

echo "6. Bluetooth music stream"
ts=$(car_transport_state)
if [ -z "$ts" ]; then bad "no music stream to the car"
elif [ "$ts" = active ]; then ok "stream active"
else warn "stream is '$ts' (car not taking audio)"; fi

if [ $FIX = yes ]; then
  echo "7. Nudging the stream (pause/resume)"
  timeout 5 pactl suspend-sink "$SINK" 1; sleep 0.5; timeout 5 pactl suspend-sink "$SINK" 0
  # A suspend silences the loopback's right channel: have auxlink-audio start a fresh one.
  pkill -f "[n]ode.name=smo_capture"; sleep 3
  ok "done; listen now"
fi
echo
[ $PROBLEM = no ] && echo "Pi side healthy. Still silent? Car source = Bluetooth/auxlink, car volume, then: audio-check.sh --fix"
