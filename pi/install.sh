#!/bin/bash
# auxlink installer (release 2: web setup). Run from this folder:   sudo ./install.sh
# Safe to run again after updating any file; it only (re)installs and enables.
set -e
[ "$(id -u)" = 0 ] || { echo "Run with sudo: sudo ./install.sh"; exit 1; }

# The user who owns the audio: whoever ran sudo, else the first normal user
# (the one Raspberry Pi Imager created) when run automatically at first boot.
U=${SUDO_USER:-$(getent passwd 1000 | cut -d: -f1)}
U=${U:-chris}
H=$(getent passwd "$U" | cut -d: -f6)
UID_U=$(id -u "$U")
HERE=$(cd "$(dirname "$0")" && pwd)
asuser() { runuser -u "$U" -- env XDG_RUNTIME_DIR=/run/user/$UID_U "$@"; }
step() { echo; echo "== $*"; }

step "Packages"
# (packages.txt is also what the prebuilt SD-card image installs)
missing=""
for p in $(grep -v '^#' "$HERE/packages.txt"); do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || missing="$missing $p"
done
# Nothing missing (e.g. the prebuilt image) = no apt, so no internet needed.
[ -z "$missing" ] || apt-get install -y $missing >/dev/null
echo "ok"

step "Wi-Fi manager (NetworkManager)"
systemctl enable --now NetworkManager >/dev/null 2>&1 || true
if nmcli -t -f DEVICE,STATE device 2>/dev/null | grep -q '^wlan0:\(connected\|disconnected\|unavailable\)'; then
  echo "ok: NetworkManager is managing wlan0"
else
  echo "WARNING: NetworkManager is not managing wlan0 (setup Wi-Fi / home Wi-Fi won't work):"
  nmcli device 2>&1 | sed 's/^/  /'
fi
rfkill unblock wifi 2>/dev/null || true
if iw reg get 2>/dev/null | grep -q 'country 00'; then
  echo "NOTE: Wi-Fi country not set; the setup Wi-Fi will fall back to 2.4 GHz."
  echo "      Set it with:  sudo raspi-config nonint do_wifi_country AU   (your country code)"
fi

step "Old teslabridge install"
# AuxLink was called teslabridge. On a Pi that still has it, switch the old
# services off so the two never run side by side (its files are left alone).
old=""
for u in teslabridge-keys tesla-reconnect tb-pairing tb-web tb-cover tb-usb-gadget; do
  if systemctl list-unit-files "$u.service" 2>/dev/null | grep -q "^$u"; then
    systemctl disable --now "$u" >/dev/null 2>&1; old="$old $u"
  fi
done
asuser systemctl --user disable --now tesla-audio >/dev/null 2>&1 || true
echo "${old:+switched off:$old}${old:-none found}"

step "Config (/etc/auxlink.conf)"
if [ -f /etc/auxlink.conf ]; then
  # Keep every existing value; add any settings this release introduced.
  added=""
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    k=${line%%=*}
    grep -q "^$k=" /etc/auxlink.conf || { echo "$line" >> /etc/auxlink.conf; added="$added $k"; }
  done < "$HERE/etc/auxlink.conf"
  echo "kept your settings${added:+; added:$added}"
else
  install -m 644 "$HERE/etc/auxlink.conf" /etc/auxlink.conf; echo "installed (nothing paired yet: use the setup page)"
fi
sed -i "s/^AUDIO_USER=.*/AUDIO_USER=$U/" /etc/auxlink.conf
# The login user needs a real shell (Raspberry Pi OS's placeholder "pi"
# has none), or SSH says "This account is currently not available".
case "$(getent passwd "$U" | cut -d: -f7)" in
  */nologin|*/false|"") usermod -s /bin/bash "$U" ;;
esac
rm -f /etc/ssh/sshd_config.d/rename_user.conf
# Re-write values so anything with spaces is quoted (bash must be able to source it).
PYTHONPATH="$HERE/lib" python3 -c 'import auxconf; auxconf.save(auxconf.load())'

step "Programs"
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
install -m 755 "$HERE"/bin/* /usr/local/bin/
install -d -o "$U" -g "$U" "$H/.local/bin"
install -o "$U" -g "$U" -m 755 "$HERE"/user-bin/* "$H/.local/bin/"
echo "ok"

step "System services"
install -m 644 "$HERE"/systemd/system/*.service /etc/systemd/system/
rm -f /etc/systemd/system/auxlink-reconnect.service.d/car-only.conf   # PHONE_ENABLED lives in the config now
systemctl daemon-reload
# The built-in Bluetooth stays available so the setup page can use it for
# either side; this routes its call audio over HCI (harmless if unused).
systemctl enable sco-route-hci >/dev/null
systemctl enable auxlink-reconnect hfp-relay auxlink-media auxlink-pairing auxlink-web auxlink-cover auxlink-usb-gadget auxlink-map bt-dongle-off avahi-daemon >/dev/null
echo "ok"

step "Bluetooth: power on at boot, no USB power-saving on the dongles"
sed -i 's/^#\?AutoEnable=.*/AutoEnable=true/' /etc/bluetooth/main.conf
grep -q '^AutoEnable=true' /etc/bluetooth/main.conf || printf '\n[Policy]\nAutoEnable=true\n' >> /etc/bluetooth/main.conf
install -m 644 "$HERE/modprobe/btusb.conf" /etc/modprobe.d/btusb.conf
# Setup Wi-Fi as a captive portal: phones open the setup page by themselves.
install -D -m 644 "$HERE/etc/captive-portal.conf" /etc/NetworkManager/dnsmasq-shared.d/auxlink-captive.conf
echo "ok"

step "PipeWire (music only; calls belong to hfp-relay)"
install -d -o "$U" -g "$U" "$H/.config/wireplumber/wireplumber.conf.d"
install -o "$U" -g "$U" -m 644 "$HERE"/wireplumber/*.conf "$H/.config/wireplumber/wireplumber.conf.d/"
loginctl enable-linger "$U"
echo "ok"

step "User services (music link, contacts, phonebook server)"
install -d -o "$U" -g "$U" "$H/.config/systemd/user/default.target.wants"
install -o "$U" -g "$U" -m 644 "$HERE"/systemd/user/*.service "$H/.config/systemd/user/"
ln -sf /usr/lib/systemd/user/obex.service "$H/.config/systemd/user/default.target.wants/obex.service"
chown -h "$U:$U" "$H/.config/systemd/user/default.target.wants/obex.service"
if [ -x /usr/local/libexec/obexd-dummy ]; then
  install -d -o "$U" -g "$U" "$H/.config/systemd/user/obex.service.d"
  # Contacts and recent calls only: no messages server (-P mas,mns). AuxLink
  # relays no texts, and a car that opened the empty one waited a minute on
  # "Connecting..." and then reset its Bluetooth.
  # (mns too while text messages are off; auxlink-messages keeps it in step.)
  OBEX_P=mas,mns; grep -q '^MESSAGES=1' /etc/auxlink.conf && OBEX_P=mas
  printf '[Service]\nExecStart=\nExecStart=/usr/local/libexec/obexd-dummy -P %s\n' "$OBEX_P" > "$H/.config/systemd/user/obex.service.d/dummy-phonebook.conf"
  chown -R "$U:$U" "$H/.config/systemd/user/obex.service.d"
  echo "contacts server: file-based obexd found"
else
  echo "NOTE: file-based obexd not built yet; run extras/build-obexd-dummy.sh as $U for contacts in the car"
fi
asuser systemctl --user daemon-reload 2>/dev/null || true
asuser systemctl --user enable auxlink-audio pbap-sync auxlink-messages >/dev/null 2>&1 || true
# At first boot the user's systemd may not be running yet: enable by hand.
for u in auxlink-audio pbap-sync auxlink-messages; do
  ln -sf "$H/.config/systemd/user/$u.service" "$H/.config/systemd/user/default.target.wants/$u.service"
done
chown -R "$U:$U" "$H/.config"
echo "ok"

step "I2S input overlay"
dtc -@ -q -I dts -O dtb -o /boot/firmware/overlays/xiao-i2s-in.dtbo "$HERE/overlay/xiao-i2s-in.dts"
CFG=/boot/firmware/config.txt
# Keep the built-in Bluetooth on (it may be chosen for the car or phone on
# the setup page). With it on, the XIAO's /dev/serial0 link moves onto the
# mini-UART, whose baud rate is derived from the GPU core clock and DRIFTS
# unless that clock is pinned (core_freq=250) - without this the XIAO link
# still "works" but every byte is garbled, which looks exactly like the SMO
# app never sending anything. enable_uart=1 keeps the mini-UART itself on.
sed -i 's/^dtoverlay=disable-bt/#dtoverlay=disable-bt/' $CFG
want="dtparam=i2s=on dtoverlay=xiao-i2s-in enable_uart=1 core_freq=250"
need=""
for l in $want; do
  grep -qx "$l" $CFG || need="$need$l\n"
done
[ -n "$need" ] && printf "\n[all]\n$need" >> $CFG
echo "ok ($CFG)"

step "Boot and reliability"
# The XIAO link uses the serial pins (8/10): no Linux login console on them.
# A fresh Raspberry Pi OS has one, and its text and echo reach the XIAO as
# key presses (volume up, play/pause...) on the music device.
sed -i -E 's/console=(serial0|ttyS0|ttyAMA0),[0-9]+ ?//g' /boot/firmware/cmdline.txt
for t in serial0 ttyS0 ttyAMA0; do systemctl mask --now "serial-getty@$t.service" >/dev/null 2>&1 || true; done
grep -q 'systemd.zram=0' /boot/firmware/cmdline.txt || sed -i '1 s/$/ systemd.zram=0/' /boot/firmware/cmdline.txt
mkdir -p /etc/systemd/system.conf.d /etc/systemd/journald.conf.d
printf '[Manager]\nRuntimeWatchdogSec=15s\nRebootWatchdogSec=2min\n' > /etc/systemd/system.conf.d/auxlink-watchdog.conf
printf '[Journal]\nStorage=persistent\nSystemMaxUse=50M\n' > /etc/systemd/journald.conf.d/auxlink.conf
# Keep logs across reboots (capped above), so a boot that went wrong can be
# looked at afterwards (journalctl -b -1).
mkdir -p /var/log/journal && systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1 || true
echo "ok (hardware watchdog reboots the Pi if it ever freezes; logs capped at 50 MB)"

echo
hostnamectl set-hostname "$(hostname)" >/dev/null 2>&1 || true
sync   # everything onto the SD card before anyone pulls the power
echo "All installed. Reboot now:  sudo reboot"
echo "Setup page: http://$(hostname).local  (on your Wi-Fi)  or join the setup Wi-Fi and open http://10.42.0.1"
echo "Setup Wi-Fi: $(grep ^SETUP_WIFI_SSID= /etc/auxlink.conf | cut -d= -f2) / password $(grep ^SETUP_WIFI_PASS= /etc/auxlink.conf | cut -d= -f2)"
