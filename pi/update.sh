#!/bin/bash
# auxlink quick update: copy the programs and service files from this
# folder and restart the auxlink services. Run from this folder:
#   sudo ./update.sh
# No packages, no internet, no reboot, Bluetooth stays up (the car and phone
# links survive). Use install.sh for a first install or if a release says so.
set -e
[ "$(id -u)" = 0 ] || { echo "Run with sudo: sudo ./update.sh"; exit 1; }
[ -f /etc/auxlink.conf ] || { echo "Not installed yet: run sudo ./install.sh first"; exit 1; }

U=${SUDO_USER:-$(getent passwd 1000 | cut -d: -f1)}
H=$(getent passwd "$U" | cut -d: -f6)
UID_U=$(id -u "$U")
HERE=$(cd "$(dirname "$0")" && pwd)
asuser() { runuser -u "$U" -- env XDG_RUNTIME_DIR=/run/user/$UID_U "$@"; }

# Settings: keep every value, add any this release introduced.
added=""
while IFS= read -r line; do
  case "$line" in ''|\#*) continue ;; esac
  k=${line%%=*}
  grep -q "^$k=" /etc/auxlink.conf || { echo "$line" >> /etc/auxlink.conf; added="$added $k"; }
done < "$HERE/etc/auxlink.conf"
echo "Settings kept${added:+; added:$added}"

install -D -m 644 "$HERE/lib/common.sh" /usr/local/lib/auxlink/common.sh
install -D -m 644 "$HERE/lib/auxconf.py" /usr/local/lib/auxlink/auxconf.py
install -D -m 644 "$HERE/share/index.html" /usr/local/share/auxlink/index.html
# The version shown on the setup page (an update zip without one keeps the old).
[ -f "$HERE/VERSION" ] && install -D -m 644 "$HERE/VERSION" /usr/local/share/auxlink/VERSION
install -D -m 644 "$HERE/share/cover-test.jpg" /usr/local/share/auxlink/cover-test.jpg
printf 'd /run/auxlink 0755 root root -\nf /run/auxlink/events.log 0666 root root -\nd /run/auxlink/outbox 1777 root root -\n' > /etc/tmpfiles.d/auxlink.conf
systemd-tmpfiles --create /etc/tmpfiles.d/auxlink.conf 2>/dev/null || true
chmod 666 /run/auxlink/events.log 2>/dev/null || true   # user services add to Recent events
install -d /usr/local/share/auxlink/xterm   # the setup page's development terminal
install -m 644 "$HERE"/share/xterm/* /usr/local/share/auxlink/xterm/
# The XIAO firmware this release came with (setup page → XIAO firmware).
# Optional: never let a missing firmware file stop the install.
if [ -f "$HERE/share/auxlink-xiao.uf2" ]; then
  install -D -m 644 "$HERE/share/auxlink-xiao.uf2" /usr/local/share/auxlink/auxlink-xiao.uf2
  install -D -m 644 "$HERE/share/auxlink-xiao.version" /usr/local/share/auxlink/auxlink-xiao.version
fi
rm -f /etc/udev/rules.d/99-auxlink-xiao.rules /etc/systemd/system/auxlink-xiao-flash@.service   # 1.0.40 flashed by itself
MAP_BEFORE=$(md5sum /usr/local/bin/auxlink-map.py 2>/dev/null | cut -d' ' -f1)
install -m 755 "$HERE"/bin/* /usr/local/bin/
install -o "$U" -g "$U" -m 755 "$HERE"/user-bin/* "$H/.local/bin/"
install -m 644 "$HERE"/systemd/system/*.service /etc/systemd/system/
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=persistent\nSystemMaxUse=50M\n' > /etc/systemd/journald.conf.d/auxlink.conf
# Keep logs across reboots (capped above), so a boot that went wrong can be
# looked at afterwards (journalctl -b -1).
mkdir -p /var/log/journal && systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1 || true
systemctl restart systemd-journald 2>/dev/null || true
# The login user needs a real shell (Raspberry Pi OS's placeholder "pi"
# has none), or SSH says "This account is currently not available".
case "$(getent passwd "$U" | cut -d: -f7)" in
  */nologin|*/false|"") usermod -s /bin/bash "$U" ;;
esac
rm -f /etc/ssh/sshd_config.d/rename_user.conf
# The XIAO link uses the serial pins (8/10): no Linux login console on them.
# A fresh Raspberry Pi OS has one, and its text and echo reach the XIAO as
# key presses (volume up, play/pause...) on the music device.
sed -i -E 's/console=(serial0|ttyS0|ttyAMA0),[0-9]+ ?//g' /boot/firmware/cmdline.txt
for t in serial0 ttyS0 ttyAMA0; do systemctl mask --now "serial-getty@$t.service" >/dev/null 2>&1 || true; done
# Setup Wi-Fi as a captive portal: phones open the setup page by themselves.
install -D -m 644 "$HERE/etc/captive-portal.conf" /etc/NetworkManager/dnsmasq-shared.d/auxlink-captive.conf
install -o "$U" -g "$U" -m 644 "$HERE"/systemd/user/*.service "$H/.config/systemd/user/"
install -o "$U" -g "$U" -m 644 "$HERE"/wireplumber/*.conf "$H/.config/wireplumber/wireplumber.conf.d/"
# Undo 1.0.66's "never idle-suspend the car" rule (taken back out): remove it
# and reload WirePlumber once so the running one forgets it.
if [ -f "$H/.config/wireplumber/wireplumber.conf.d/81-a2dp-keep.conf" ]; then
  rm -f "$H/.config/wireplumber/wireplumber.conf.d/81-a2dp-keep.conf" \
        "$H/.config/wireplumber/wireplumber.conf.d/83-auxlink-music-source.conf" \
        "$H/.local/state/auxlink/a2dp-nosuspend"
  asuser systemctl --user restart wireplumber >/dev/null 2>&1 || true
fi
# Onto the SD card now: a power cut right after an update otherwise leaves
# freshly written files EMPTY (empty unit files then show as "masked").
sync
echo "Programs and services copied"

systemctl daemon-reload
systemctl enable auxlink-cover auxlink-usb-gadget auxlink-map >/dev/null 2>&1 || true
# USB-C source in use: leave its gadget up (taking it down cuts the music
# device off). Otherwise restart, which removes a gadget left from before.
if grep -q '^MUSIC_SOURCE=usbc' /etc/auxlink.conf; then
  systemctl start auxlink-usb-gadget
else
  systemctl restart auxlink-usb-gadget
fi
systemctl restart auxlink-pairing auxlink-reconnect hfp-relay auxlink-media auxlink-web auxlink-cover
# The car's messages service only when it changed: while it is gone the car
# switches "Sync Messages" off.
if [ "$(md5sum /usr/local/bin/auxlink-map.py | cut -d' ' -f1)" != "$MAP_BEFORE" ]; then
  systemctl restart auxlink-map
else
  systemctl start auxlink-map
fi
# Contacts server: contacts and recent calls only, no messages server (a car
# that opened the empty one hung on "Connecting..." and reset its Bluetooth).
OBEX_DROPIN="$H/.config/systemd/user/obex.service.d/dummy-phonebook.conf"
OBEX_P=mas,mns; grep -q '^MESSAGES=1' /etc/auxlink.conf && OBEX_P=mas   # mns: text messages (auxlink-messages)
OBEX_WANT="[Service]
ExecStart=
ExecStart=/usr/local/libexec/obexd-dummy -P $OBEX_P"
OBEX_RESTART=0
if [ -x /usr/local/libexec/obexd-dummy ] && [ "$(cat "$OBEX_DROPIN" 2>/dev/null)" != "$OBEX_WANT" ]; then
  install -d -o "$U" -g "$U" "$(dirname "$OBEX_DROPIN")"
  printf '%s\n' "$OBEX_WANT" > "$OBEX_DROPIN"
  chown "$U:$U" "$OBEX_DROPIN"
  OBEX_RESTART=1
fi
asuser systemctl --user daemon-reload
asuser systemctl --user enable auxlink-messages >/dev/null 2>&1 || true
asuser systemctl --user restart auxlink-audio pbap-sync auxlink-messages
[ "$OBEX_RESTART" = 1 ] && asuser systemctl --user restart obex && echo "Contacts server: messages part turned off"
sync
echo "Services restarted. Done (no reboot needed)."
