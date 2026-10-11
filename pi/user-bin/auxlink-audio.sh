#!/bin/bash
# Keeps music flowing to the car:
#   music input --pw-loopback--> car's Bluetooth (A2DP) output
# The music input is whatever MUSIC_SOURCE selects: the XIAO over I2S
# (wired), a phone/player streaming to the Pi over Bluetooth, or the Pi's
# USB-C port as a USB sound card.
#
# It behaves like a phone: the car only plays a Bluetooth stream it sees START
# (AVDTP start) while it is ready and the source says "Playing". A stream that
# started too early - mid-reconnect, or one that simply ran on through a call -
# is accepted but stays silent. So the stream runs only while the car is
# ready AND the SMO is playing AND there is no call, and every start is a
# fresh one (new loopback) with music in it:
#   * car (re)connects  -> wait until it is ready (HFP set up, or 12 s),
#                          then start it like after a call (see below)
#   * SMO plays         -> start (auxlink-media has already told the car
#                          "Playing" when it writes PLAY_FILE)
#   * SMO pauses / call -> stop, and suspend the car output (car sees pause)
# While streaming, both channels are checked every 60 s: a suspend/resume of
# the car's output (the car can do that too) leaves a running pw-loopback
# with a silent RIGHT channel until it is recreated.
#
# A car can also accept a stream and play SILENCE with everything on the Pi
# looking healthy, which nothing here can detect: the Tesla does that to a
# stream started after a call (seen at 1 s and at 5 s, SBC and SBC-XQ), and
# plays it after a restart with music flowing. So after a call, music waits
# call_settle and the stream is then restarted once, 1 s after it starts
# (the quick version: the mono moment it causes is ~0.3 s). If it is ever silent anyway, pressing play in the car while we stream
# (auxlink-media writes KICK_FILE) restarts the stream - what "Check and fix"
# does.
. /usr/local/lib/auxlink/common.sh
while [ -z "$CAR" ] || [ -z "$CAR_ADAPTER" ]; do sleep 5; . /etc/auxlink.conf; done

PLAY_FILE=/run/auxlink/play          # "1"/"0" from auxlink-media (missing = play)
# Not every app reports its play state to the SMO app (YouTube often does
# not), so sound actually arriving on the music input also counts as playing.
# Published for auxlink-media, which then tells the car "Playing".
PRESENT_FILE=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/auxlink-audio-present
# Touched once the car's stream runs again after a call: auxlink-media holds
# the music source's "play" until then, so no music is missed.
READY_FILE=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/auxlink-stream-ready
PRESENT=0; LAST_SOUND=0; NEXT_LEVEL=0
CAR_SLC_FILE=/run/auxlink/car-slc    # "1" once hfp-relay has the car's HFP set up
KICK_FILE=/run/auxlink/audio-kick    # touched by auxlink-media when the car presses play
KICK_SEEN=$(stat -c %Y "$KICK_FILE" 2>/dev/null || echo 0)
RECHECK=""        # why the stream is restarted (play pressed in the car)
RECHECK_AT=0      # when to do it (0 = not pending)
CALL_ENDED_AT=0; WAS_CALL=0
# s after a call before the car's stream restarts (the car leaves call
# mode; the silent restart that follows covers the rest). Separate from the
# page's "Resume music after a call", which is when the SOURCE is played
# again (wired: auxlink-media holds it until this stream runs anyway).
call_settle() { echo 2; }
LOOP=""; LOOP_SINK_ID=""; LOOP_INPUT=""; LOOP_STARTED=0; UNLINKED=0; GONE=2; NO_CARD=0; NOT_ACTIVE=0; LAST_NUDGE=0
CONNECTED_AT=0; WAITING_SAID=""; NEXT_STEREO=0; STEREO_BAD=0; STOPPED_FOR=""
XQ_FAILS=0   # SBC-XQ attempts since this script started (never reset by a disconnect)
INPUT=""; INPUT_SAID=""
# A Bluetooth music source must become an INPUT (not a stream WirePlumber
# plays straight to the default speaker, which may be the car - that would
# bypass this loopback and play twice). Only that one device: other phones'
# media (e.g. the Oppo's) still mixes into the car's audio as before.
WP_RULE=${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/wireplumber.conf.d/83-auxlink-music-source.conf
wp_rule() {
  local want=""
  if [ "${MUSIC_SOURCE:-wired}" = bluetooth ] && [ -n "$SOURCE" ]; then
    want="# Written by auxlink-audio: the music source is an input, not a playback stream.
monitor.bluez.rules = [
  {
    matches = [ { node.name = \"~bluez_input.${SOURCE//:/_}.*\" } ]
    actions = { update-props = { bluez5.media-source-role = \"input\", node.autoconnect = false } }
  }
]"
  fi
  local have; have=$(cat "$WP_RULE" 2>/dev/null)
  [ "$have" = "$want" ] && return
  if [ -n "$want" ]; then mkdir -p "$(dirname "$WP_RULE")"; printf '%s\n' "$want" > "$WP_RULE"
  else rm -f "$WP_RULE"; fi
  [ -z "$have" ] && [ -z "$want" ] && return
  echo "Music source changed: restarting WirePlumber to apply it"
  stop_loop
  systemctl --user restart wireplumber
  sleep 3
}

# A phone call, or the car's mic borrowed for voice search (the car is in
# call mode for that too).
car_busy() { in_call || [ "$(cat /run/auxlink/mic-active 2>/dev/null)" = 1 ]; }
stop_loop() { [ -n "$LOOP" ] && kill "$LOOP" 2>/dev/null; LOOP=""; LOOP_SINK_ID=""; }
linked() {
  local links; links=$(timeout 5 pw-link -l 2>/dev/null)
  echo "$links" | grep -A2 "^$INPUT:capture_FL" | grep -q "smo_capture:" &&
  echo "$links" | grep -A2 "^$INPUT:capture_FR" | grep -q "smo_capture:" &&
  echo "$links" | grep -A2 "^to_tesla:output_FL" | grep -q "bluez_output" &&
  echo "$links" | grep -A2 "^to_tesla:output_FR" | grep -q "bluez_output"
}
# Last resort only (rate-limited): pause/resume the car's stream WITH music
# flowing (a car whose stream resumes to silence stays silent), then recreate
# the loopback (the suspend silences its right channel).
nudge() {
  timeout 5 pactl suspend-sink "$1" 1; sleep 0.5; timeout 5 pactl suspend-sink "$1" 0
  sleep 1; stop_loop
}
# The planned restart: the same pause/resume of the car's stream, done with
# the music INPUT muted - the car only needs the stream to stop and start
# again, and the resume's mono side effect (on the old loopback) is then
# silent. The fresh loopback started next unmutes it: stereo straight away.
# (The input, not the car output: muting that would change the car's volume.)
RESTART_MUTED=""
quick_restart() {
  timeout 5 pactl set-source-mute "$INPUT" 1 && RESTART_MUTED=$INPUT
  timeout 5 pactl suspend-sink "$1" 1; sleep 0.2; timeout 5 pactl suspend-sink "$1" 0
  sleep 0.2; stop_loop
}
# Start the loopback (input -> car). The caller has lifted any suspend.
start_loop() {
  [ "$1" = muted ] || unmute_input
  pw-loopback -c 2 -m '[ FL FR ]' \
              --capture-props="target.object=$INPUT node.name=smo_capture audio.position=[ FL FR ]" \
              --playback-props="target.object=$SINK node.name=to_tesla audio.position=[ FL FR ]" &
  LOOP=$!; LOOP_SINK_ID=$SINK_ID; LOOP_INPUT=$INPUT; LOOP_STARTED=$(date +%s); UNLINKED=0; NOT_ACTIVE=0; STEREO_BAD=0
  NEXT_STEREO=$((LOOP_STARTED + 3))
  echo "Streaming to $SINK"
}
unmute_input() {
  [ -n "$RESTART_MUTED" ] && timeout 5 pactl set-source-mute "$RESTART_MUTED" 0
  RESTART_MUTED=""
}
smo_playing() { [ "$(cat "$PLAY_FILE" 2>/dev/null || echo 1)" != 0 ]; }
# Is sound arriving from the XIAO? 0.4 s sample; the SMO sends digital
# silence when nothing plays, so a very low threshold is enough.
sound_now() {
  local f=/tmp/auxlink-level.wav rms
  rm -f "$f"
  pw-record --target "$INPUT" --channels 2 --format s16 "$f" &
  local p=$!; sleep 0.4; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
  rms=$(sox "$f" -n stat 2>&1 | awk '/RMS +amplitude/ {print $3}')
  [ -n "$rms" ] && awk "BEGIN{exit !($rms > 0.0003)}"
}
# Updates PRESENT (sound seen within the last 6 s) and its file.
check_sound() {
  local now; now=$(date +%s)
  [ "$now" -lt "$NEXT_LEVEL" ] && return
  if sound_now; then LAST_SOUND=$now; fi
  local was=$PRESENT
  if [ $((now - LAST_SOUND)) -lt 6 ]; then PRESENT=1; else PRESENT=0; fi
  if [ "$PRESENT" != "$was" ] || [ ! -f "$PRESENT_FILE" ]; then
    echo "$PRESENT" > "$PRESENT_FILE"
    [ "$PRESENT" = 1 ] && echo "Sound arriving from the SMO" || echo "No sound from the SMO"
  fi
  # Quick to notice music starting; relaxed while it plays.
  if [ -n "$LOOP" ]; then NEXT_LEVEL=$((now + 3)); else NEXT_LEVEL=$now; fi
}
car_ready() {
  local up=$(( $(date +%s) - CONNECTED_AT ))
  [ "$up" -ge 3 ] && { [ "$(cat "$CAR_SLC_FILE" 2>/dev/null)" = 1 ] || [ "$up" -ge 12 ]; }
}
# What the car is actually sent, 1 s of it: false if the right channel is
# silent while the left carries music (can't judge quiet passages: true).
stereo_ok() {
  local f=/tmp/auxlink-stereo-check.wav l r
  rm -f "$f"
  pw-record --target "$1" -P stream.capture.sink=true --channels 2 --format s16 "$f" &
  local p=$!; sleep 1.2; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
  l=$(sox "$f" -n remix 1 stat 2>&1 | awk '/RMS +amplitude/ {print $3}')
  r=$(sox "$f" -n remix 2 stat 2>&1 | awk '/RMS +amplitude/ {print $3}')
  [ -z "$l" ] || [ -z "$r" ] && return 0
  awk "BEGIN{exit !($l < 0.005 || $r > $l / 20)}"
}
trap 'stop_loop; unmute_input' EXIT

while true; do
  . /etc/auxlink.conf; CARD=bluez_card.${CAR//:/_}; CAR_RE=${CAR//:/[:_]}
  wp_rule
  # Track the call here, first: a Bluetooth source's stream is closed during
  # a call, and the end must be timed from the call, not from its return.
  if car_busy; then WAS_CALL=1
  elif [ "$WAS_CALL" = 1 ]; then WAS_CALL=0; CALL_ENDED_AT=$(date +%s)
    RECHECK="the call ended"
  fi
  # Note: the "xiaoi2s" ALSA device is the Pi<->XIAO hardware I2S link (fixed
  # by the device-tree overlay) and stays present whether or not the SMO
  # itself is plugged into the XIAO's USB-C port - so it is not a reliable
  # signal for "SMO disconnected". A Bluetooth source's input only exists
  # while it is connected, and the USB-C one only once the port is in
  # gadget mode.
  INPUT=$(music_input)
  if [ -z "$INPUT" ]; then
    case "${MUSIC_SOURCE:-wired}" in
      bluetooth) why="Waiting for the Bluetooth music source${SOURCE:+ ($SOURCE)} to connect" ;;
      usbc) why="USB-C music input not found (gadget mode needs a reboot after selecting USB-C)" ;;
      *) why="XIAO I2S input not found (is the xiao-i2s-in overlay loaded? check: arecord -l)" ;;
    esac
    [ "$why" != "$INPUT_SAID" ] && echo "$why"; INPUT_SAID=$why
    # No input = no sound: say so (a Bluetooth source closes its stream on
    # pause - left at "1", the car would keep showing Playing).
    if [ "$PRESENT" = 1 ]; then
      PRESENT=0; LAST_SOUND=0; echo 0 > "$PRESENT_FILE"; echo "No sound from the SMO"
    fi
    stop_loop
    # A Bluetooth source closes its stream on pause: look again quickly, so
    # play is heard at once.
    if [ "${MUSIC_SOURCE:-wired}" = bluetooth ]; then sleep 0.5; else sleep 3; fi
    continue
  fi
  INPUT_SAID=""
  if [ -n "$LOOP" ] && [ "$INPUT" != "$LOOP_INPUT" ]; then
    echo "Music input is now $INPUT; restarting the stream"
    stop_loop
  fi

  if ! $BT "$CAR_ADAPTER" "$CAR" connected 2>/dev/null; then
    GONE=$((GONE + 1))
    if [ "$GONE" -eq 2 ]; then
      [ -n "$LOOP" ] && echo "Car disconnected"
      stop_loop
    fi
    sleep 2; continue
  fi
  if [ "$GONE" -ge 2 ]; then
    CONNECTED_AT=$(date +%s); WAITING_SAID=""
    echo "Car connected; waiting until it is ready before starting music"
    # A car that connects while music already plays can take the first
    # stream silently, like after a call: start it the same way (a muted
    # first start, then the real one), so it plays either way.
    RECHECK="the car just connected"; RECHECK_AT=0
  fi
  GONE=0

  # PipeWire only creates the car's card once the music channel is open.
  if ! timeout 5 pactl list cards short 2>/dev/null | grep -q "$CARD"; then
    NO_CARD=$((NO_CARD + 1))
    if [ "$NO_CARD" -ge 3 ]; then
      echo "Car connected without music; opening the A2DP channel"
      timeout 25 $BT "$CAR_ADAPTER" "$CAR" connect "$A2DP_SINK_UUID" >/dev/null 2>&1
      NO_CARD=0
    fi
    sleep 2; continue
  fi
  NO_CARD=0

  # Music profile: plain SBC unless SBC_XQ=1. SBC-XQ (high-rate dual
  # channel) keeps the stereo width that plain SBC loses under radio
  # pressure, but the Tesla DISCONNECTS when the profile is switched to it,
  # so it is opt-in and tried at most twice per Pi boot, not per connection
  # (a per-connection retry would knock the car off again on every connect).
  CARDINFO=$(timeout 5 pactl list cards | sed -n "/Name: $CARD/,/^Card #/p")
  ACTIVE=$(echo "$CARDINFO" | awk -F': ' '/Active Profile/ {print $2; exit}')
  WANT=a2dp-sink
  if [ "${SBC_XQ:-0}" = 1 ] && [ "$XQ_FAILS" -lt 2 ] &&
     echo "$CARDINFO" | grep -q "a2dp-sink-sbc_xq:.*available: yes"; then
    WANT=a2dp-sink-sbc_xq
  fi
  if [ "$ACTIVE" != "$WANT" ] && { [[ "$ACTIVE" != a2dp* ]] || ! in_call; }; then
    echo "Switching the car to $WANT"
    # Count every SBC-XQ attempt (per boot): a car that refuses it, or
    # quietly stays on SBC, gets plain SBC after two tries.
    [ "$WANT" = a2dp-sink-sbc_xq ] && XQ_FAILS=$((XQ_FAILS + 1))
    timeout 5 pactl set-card-profile "$CARD" "$WANT" 2>/dev/null
    sleep 2; continue
  fi

  LINE=$(car_sink_line)
  SINK=$(echo "$LINE" | cut -f2)
  SINK_ID=$(echo "$LINE" | cut -f1)
  if [ -z "$SINK" ]; then
    stop_loop; sleep 2; continue
  fi

  if [ -n "$LOOP_SINK_ID" ] && [ "$SINK_ID" != "$LOOP_SINK_ID" ]; then
    echo "Car output was recreated; restarting the stream"
    stop_loop; continue
  fi

  # ---- should music be streaming right now? ----
  check_sound
  # Play pressed in the car while we are already streaming: the person hears
  # nothing, so restart the stream. (Play after a pause starts a fresh
  # stream anyway - nothing extra then.)
  kick=$(stat -c %Y "$KICK_FILE" 2>/dev/null || echo 0)
  if [ "$kick" != "$KICK_SEEN" ]; then
    KICK_SEEN=$kick
    [ -n "$LOOP" ] && [ $(( $(date +%s) - LOOP_STARTED )) -ge 3 ] &&
      { RECHECK="play was pressed in the car"; RECHECK_AT=$(date +%s); }
  fi
  WHY=""
  if car_busy; then WHY="a call"
  elif [ $(( $(date +%s) - CALL_ENDED_AT )) -lt "$(call_settle)" ]; then WHY="the call just ended"
  elif ! smo_playing && [ "$PRESENT" != 1 ]; then WHY="the SMO is paused"
  elif ! car_ready; then WHY="the car is still connecting"
  fi

  if [ -n "$WHY" ]; then
    unmute_input
    if [ -n "$LOOP" ]; then
      echo "Stopping the music stream: $WHY"
      stop_loop
      # A phone suspends its stream on pause; the car sees it stop.
      case "$WHY" in "the car is still connecting"|"the call just ended") ;;
        *) timeout 5 pactl suspend-sink "$SINK" 1 ;; esac
    fi
    if [ "$WHY" != "$WAITING_SAID" ]; then
      case "$WHY" in "the car is still connecting"|"the call just ended") ;;
        *) echo "Not streaming: $WHY" ;; esac
      WAITING_SAID=$WHY
    fi
    sleep 0.5; continue
  fi
  WAITING_SAID=""

  if [ -z "$LOOP" ] || ! kill -0 "$LOOP" 2>/dev/null; then
    # A fresh start every time. Channel layout spelled out on both sides
    # (left unspecified, the right channel was dropped inside the loopback).
    # Only ever one loopback: strays (e.g. one started by hand for a test)
    # feed the car the same music on their own timing - a skip every few s.
    pkill -f "[n]ode.name=smo_capture" && sleep 0.5
    if [ "$(timeout 5 pactl get-sink-mute "$SINK" | awk '{print $2}')" = yes ]; then
      echo "Car output was muted; unmuting"
      timeout 5 pactl set-sink-mute "$SINK" 0
    fi
    # Lift a pause-time suspend BEFORE the loopback exists: resuming under a
    # running loopback is what silences its right channel. With nothing
    # playing yet this starts nothing; the car sees START when the loopback
    # links, with music in it.
    timeout 5 pactl suspend-sink "$SINK" 0
    if [ -n "$RECHECK" ] && [ "$RECHECK_AT" = 0 ]; then
      # After a call the car sometimes ignores this first start and
      # sometimes plays it. So it carries silence (input muted), is restarted
      # as soon as it is linked, and only the fresh stream carries the
      # music: one start heard, in stereo, either way.
      timeout 5 pactl set-source-mute "$INPUT" 1 && RESTART_MUTED=$INPUT
      start_loop muted
      for _ in $(seq 20); do linked && break; sleep 0.1; done
      echo "Restarting the car's stream once ($RECHECK), so a car that ignored the first start plays it"
      RECHECK=""
      quick_restart "$SINK"
      start_loop
      for _ in $(seq 20); do linked && break; sleep 0.1; done
      date +%s > "$READY_FILE"     # auxlink-media now plays the source
    else
      start_loop
    fi
    sleep 1; continue
  fi

  if ! linked; then
    UNLINKED=$((UNLINKED + 1))
    if [ "$UNLINKED" -ge 2 ]; then
      echo "Link to the car dropped; restarting it"
      UNLINKED=0; stop_loop; continue
    fi
    sleep 1; continue
  fi
  UNLINKED=0

  now=$(date +%s)
  if [ "$RECHECK_AT" -gt 0 ] && [ "$now" -ge "$RECHECK_AT" ]; then
    if [ "$PRESENT" = 1 ] || smo_playing; then
      echo "Restarting the car's stream once ($RECHECK), so a car that took it silently plays it"
      RECHECK=""; RECHECK_AT=0
      quick_restart "$SINK"; continue
    fi
    RECHECK_AT=$now               # wait for music before restarting
  fi
  # Both channels really reaching the car? (two bad checks in a row = act)
  if [ "$now" -ge "$NEXT_STEREO" ]; then
    NEXT_STEREO=$((now + 60))
    if stereo_ok "$SINK"; then
      STEREO_BAD=0
    else
      STEREO_BAD=$((STEREO_BAD + 1))
      if [ "$STEREO_BAD" -ge 2 ]; then
        echo "Right channel silent at the car; recreating the loopback"
        stop_loop; continue
      fi
      NEXT_STEREO=$((now + 3))
    fi
  fi

  # Last resort: the car's stream is not taking audio at all.
  ts=$(car_transport_state)
  if [ -n "$ts" ] && [ "$ts" != active ]; then
    NOT_ACTIVE=$((NOT_ACTIVE + 1))
  else
    NOT_ACTIVE=0
  fi
  if [ "$NOT_ACTIVE" -ge 3 ] && [ $((now - LAST_NUDGE)) -ge 60 ]; then
    echo "Car stream is '$ts' while we are sending audio; nudging it (last resort)"
    nudge "$SINK"; LAST_NUDGE=$now; NOT_ACTIVE=0
    continue
  fi
  sleep 2
done
