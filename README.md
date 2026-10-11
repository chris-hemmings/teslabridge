# AuxLink

Bluetooth music, calls and voice for **any car with Bluetooth**, from an
**Android music device**: a Screenmate/SMO-style head unit, an old phone or a
tablet. A Raspberry Pi 4 sits between your **car**, your **phone** and that
music device:

- **Music** from the Android device plays in the car over Bluetooth, with
  track title, artist, album, progress, **album art** and the car's
  play/pause/skip buttons and steering-wheel controls working.
- **Calls** from your real phone are relayed through the Pi to the car (the
  car's mic and speakers), with **contacts, favourites and recent calls**
  copied to the car's screen.
- **Voice search** on the Android device can use the **car's microphone**,
  with every music source.
- Everything is set up from a **web page** on the Pi. Nothing is hard-coded,
  and it reconnects by itself after the car sleeps or the Pi reboots.

```
                 Bluetooth (Pi = "phone")              Bluetooth (Pi = "car kit")
   Car    <------------------------------>  Pi 4  <------------------------------>  your phone
                                             ^
                                             |  music in: one of
                                             |   - USB-C (recommended): the Pi itself is a USB
                                             |     sound card, one cable from the Android device
                                             |   - Wired (backup): XIAO RP2040 (USB sound card for
                                             |     the Android device) -> I2S + serial to the Pi
                                             |   - Bluetooth (last resort): the device pairs with the Pi
                                       Android music device
                                       (+ "AuxLink" app)
```

### Downloads

Everything is on the [Releases page](https://github.com/chris-hemmings/auxlink/releases),
as three separate kinds of release:

| Release | File | What it is |
|---|---|---|
| **AuxLink Pi image** | `auxlink-pi-X.img.xz` | The whole Pi: Raspberry Pi OS Lite with AuxLink installed. One file, flashed with Raspberry Pi Imager. |
| | `auxlink-pi-update-X.zip` | Updates a running Pi from its setup page. |
| **AuxLink app** | `auxlink-v1.0.N.apk` | The Android app (now playing, album art, Fix sound and Setup buttons). Install with Obtainium. |
| **AuxLink XIAO firmware** | `auxlink-xiao-X.uf2` | Firmware for the Seeed XIAO RP2040 (wired backup source only). |

### Source

| Folder | What it is |
|---|---|
| `pi/` | Everything that runs on the Pi (installer, services, setup page), and `pi/image/`, which builds the SD-card image. See also `pi/README.md`. |
| `android/` | The **AuxLink** Android app. |
| `firmware/rp2040/` | The XIAO firmware (Rust, based on [TeslAux](https://github.com/jbschooley/TeslAux), MIT). |

---

## 1. What you need

### Required
| Item | Notes |
|---|---|
| **Raspberry Pi 4** (2 GB or more) | Built and tested on a Pi 4. |
| **microSD card**, 16 GB or more | A good brand (Samsung/SanDisk). |
| **Power for the Pi in the car** | 5 V / 3 A. A good USB-C car charger or a 12 V to 5 V 3 A converter. Weak supplies cause Bluetooth drop-outs. For the USB-C music source, power the Pi through its GPIO pins or a splitter for reliable use (see 5.1). |
| **2 × USB Bluetooth dongles** (recommended) | **TP-Link UB500** (Realtek RTL8761BU) is what this was built and tested on. Two identical ones are fine. One is for the car, one for your phone. See [Bluetooth dongles](#bluetooth-dongles). |
| **An Android music device** | Android 8.0 or newer. For the wired source it needs **USB host (OTG)**, which any head unit with a USB port has. |
| **A car with Bluetooth** | Any car with Bluetooth hands-free calling and Bluetooth music. Track info and the car's buttons need AVRCP, which almost every car has. Album art needs a car that shows cover art for phones (AVRCP 1.6). Built and tested on a Tesla; see [Other cars](#other-cars). |

### Needed for the USB-C music source (recommended)
| Item | Notes |
|---|---|
| **USB-C data cable** | From the Android device's USB port to the **Pi's USB-C port**. Nothing else to buy or wire. |
| **Separate power for the Pi** (strongly advised) | 5 V into the GPIO pins, or a USB-C power/data splitter (section 5.1). The music device alone can't reliably power the Pi. |

### Needed for the wired music source (backup)
| Item | Notes |
|---|---|
| **Seeed Studio XIAO RP2040** | The small board that the Android device sees as a USB sound card. |
| **USB-C cable** | From the Android device's USB port to the XIAO. It also powers the XIAO. |
| **7 jumper wires** (female-female) or solder | XIAO to the Pi's GPIO header: D0, D1, D2, D3, D6, D7 and GND (section 3.2). Keep the I2S wires short (under ~15 cm). |

### Optional
- **Push button** between GPIO26 (pin 37) and GND (pin 34). Hold it 3 s to
  turn the setup Wi-Fi on.
- **Short USB extension lead** for one dongle, to keep the two dongles apart.

### Bluetooth dongles
Any USB dongle with Linux support for **Bluetooth Classic (BR/EDR)** works.
Known good:
- **TP-Link UB500** (RTL8761BU). Recommended.
- Other Realtek **RTL8761B/BU** "BT 5.0" dongles (many UGREEN, ASUS and Edimax models).
- CSR8510 A10 "BT 4.0" dongles (cheap clones are hit and miss).

Avoid:
- "Windows only" or "driver CD" dongles;
- most "BT 5.3/5.4" dongles on Barrot or Actions (ATS2851) chips;
- LE-only dongles;
- "Bluetooth audio transmitter" boxes.

Use the Pi's **black USB 2.0 ports**, because USB 3.0 interferes with
Bluetooth.

The Pi's **built-in Bluetooth** can be used as well. It works well for a
Bluetooth music source, or for the car side if you only have one dongle.
It is not reliable for **calls**: the built-in chip crashed mid-call in
testing.

---

## 2. Install the Pi

### 2.1 Flash the AuxLink image (recommended)
1. Download the latest **`auxlink-pi-X.img.xz`** from the
   [Releases page](https://github.com/chris-hemmings/auxlink/releases)
   (the "AuxLink Pi image" release).
2. Open **Raspberry Pi Imager** on your PC:
   - **Device:** Raspberry Pi 4.
   - **OS:** scroll to the bottom → **Use custom** → choose the
     `.img.xz` file. There's no need to unzip it.
   - **Storage:** your microSD card.
3. Write the card. There are no settings to fill in: Imager doesn't offer
   customisation for custom images, and the image doesn't need it. It
   comes ready with:
   - hostname **`auxlink`**;
   - user **`auxlink`**, password **`auxlink`**.
4. Put the card in the Pi and power it on. The first boot takes **a few
   minutes** and reboots once by itself. No internet, keyboard or screen is
   needed. A log is written to `auxlink-install.log` on the card's boot
   drive.
5. Then carry on with **section 4**: join the Wi-Fi **AuxLink-setup**.

**Password and SSH:** on the setup page, the **Pi login** tab sets your
own login password (the page warns while the default one is still set) and
turns **SSH** on or off. SSH is off by default and can only be turned on once
the password has been changed. Then log in with `ssh auxlink@auxlink.local`.

### 2.2 Or install onto Raspberry Pi OS yourself
Use this if you already have Raspberry Pi OS Lite (64-bit) running. It
needs internet and takes about 45 minutes, because the two BlueZ extras are
compiled on the Pi. Over SSH:

```bash
sudo apt update && sudo apt -y full-upgrade && sudo apt install -y git
git clone https://github.com/chris-hemmings/auxlink.git
cd auxlink/pi
sudo ./install.sh                       # packages, services, I2S + serial setup (~5 min)
./extras/build-obexd-dummy.sh           # contacts/recent calls server for the car (~20 min)
sudo ./install.sh                       # again, so it picks up the contacts server
sudo ./extras/build-bluetoothd-cover.sh # album art in the car (~15-20 min)
sudo reboot
```

- Run `build-obexd-dummy.sh` **without** sudo. It asks for your password when
  it needs it.
- Both builds are optional. Without the first, there are no contacts or recent
  calls on the car's screen. Without the second, there is no album art.
  Everything else works.
- To undo the album-art build: `sudo ./extras/build-bluetoothd-cover.sh --undo`.

### 2.3 What gets set up
- It installs PipeWire, WirePlumber, BlueZ, NetworkManager, Avahi, sox and a
  few Python modules.
- It adds the following to `/boot/firmware/config.txt`:
  - `dtparam=i2s=on`
  - `dtoverlay=xiao-i2s-in` (the XIAO's I2S input)
  - `enable_uart=1` and `core_freq=250` (a stable serial link while the
    built-in Bluetooth stays on)
- It creates `/etc/auxlink.conf`. Settings are normally changed on the
  setup page.
- It turns on a hardware watchdog (the Pi reboots itself if it ever freezes)
  and caps the logs at 50 MB.

---

## 3. Wire the XIAO RP2040 (wired backup source only; skip for USB-C)

### 3.1 Flash the firmware
1. Download the latest **`auxlink-xiao-X.uf2`** from the
   [Releases page](https://github.com/chris-hemmings/auxlink/releases)
   (the "AuxLink XIAO firmware" release).
2. Hold the XIAO's **B (BOOT)** button while plugging it into a PC. A drive
   called **RPI-RP2** appears.
3. Copy the `.uf2` file onto that drive. The XIAO restarts by itself, and
   its RGB LED lights up.

**Easier, once the Pi is set up:** update it from the setup page's **XIAO
firmware** (Updates tab), without a computer and without updating the Pi. Unplug the
XIAO's USB-C from the Android device, hold **B** and plug it into one of the
**Pi's** USB ports (USB-A to USB-C cable; the wires to the Pi can stay
connected). The card shows "XIAO in update mode". Choose the new `.uf2` and
tap **Flash this file** (or **Flash built-in firmware**, the version that
came with the Pi's AuxLink). Plug the XIAO back into the Android device;
Android asks once whether AuxLink should open it (tick **Always**).

This firmware makes the XIAO appear to the Android device as:
- a **USB sound card** (48 kHz stereo speaker) whose audio goes to the Pi
  over I2S;
- a **USB microphone** carrying the car's cabin mic, for voice search;
- **USB media keys**, so the car's buttons control the player;
- a **data link** that the AuxLink app uses for track info and album art.

### 3.2 Pinout

**Do not connect 5 V or 3.3 V between the boards.** The XIAO is powered by
the Android device's USB port.

The XIAO uses **D0, D1, D2, D3, D6, D7 and GND**:

| XIAO pad | Signal | Pi 4 header pin | Pi GPIO |
|---|---|---|---|
| **D0** | I2S LRCLK (word clock) | **35** | GPIO19 (PCM_FS) |
| **D1** | Shield (held low) | any **GND** pin, e.g. **39** | – |
| **D2** | I2S BCLK (bit clock) | **12** | GPIO18 (PCM_CLK) |
| **D3** | I2S DATA | **38** | GPIO20 (PCM_DIN) |
| **D6** | Serial XIAO → Pi (TX) | **10** | GPIO15 (RXD) |
| **D7** | Serial Pi → XIAO (RX) | **8** | GPIO14 (TXD) |
| **GND** | Ground | **6** (or 9, 14, 20, 25, 30, 34) | – |

Where the pads are on the **XIAO** (USB-C at the top, looking at the
components):
- **Left edge, top to bottom:** D0, D1, D2, D3, D4, D5, D6.
- **Right edge, top to bottom:** 5V, GND, 3V3, D10, D9, D8, D7.

Where the pins are on the **Pi 4 header** (pin 1 is the corner nearest the
SD card, on the inside row):
- Odd pins (1, 3, 5 …) are on the inside row and even pins (2, 4, 6 …) on
  the outside edge.
- Pins **6, 8, 10 and 12** are near that end of the outside row.
- Pins **35, 38 and 39** are at the far end (USB end).

- **D1, the shield:** the firmware holds it low all the time, so a quiet,
  grounded wire can run between the two clock wires. In a ribbon or cable,
  put it **between BCLK (D2) and LRCLK (D0)**, so the order is D0, D1, D2,
  and connect it to a **GND pin** at the Pi end (pin 39 is next to 35/38).
  Leaving it unconnected also works, but the shield helps against a
  corrupted right channel on longer wires.
- Keep the I2S wires (D0–D3) short and together. Long or loose I2S wires show
  up as crackles or a corrupted right channel.
- The serial link runs at 115200 baud 8N1 on the Pi's `/dev/serial0`.

### 3.3 Connect it
- Plug the XIAO's USB-C into the Android device's USB port, using an OTG
  adapter if needed.
- In the device's sound settings, the output should switch to the USB device
  (it shows as **AuxLink**; firmware before 1.0.1 called it "TeslAux
  Bridge"). Android does this by itself when a USB sound card is plugged in.
- Android then asks whether **AuxLink** should open it: tick **Always** (see
  6.3). From firmware 1.0.2, if the device boots with the XIAO already
  plugged in and the app doesn't get its link within 15 s, the XIAO briefly
  re-plugs itself so Android hands the app the link without a prompt.

---

## 4. First setup on the web page

### Passwords and names at a glance
| What | Name | Password |
|---|---|---|
| Setup Wi-Fi (made by the Pi) | `AuxLink-setup` | `auxlink-setup` |
| Setup page | http://10.42.0.1 (or http://auxlink.local on your home Wi-Fi) | none, unless you set a page password |
| Pi login (SSH or keyboard) | user `auxlink` | `auxlink`. Change it on the **Pi login** tab |
| Bluetooth: what the **car** pairs with | **AuxLink** | code shown on the car |
| Bluetooth: what your **phone** pairs with | **AuxLink-phone** | code shown on the phone |
| Bluetooth: a **Bluetooth music source** | **AuxLink-music** (or AuxLink-phone if it shares that adapter) | code shown on the device |

Only one of these Bluetooth names is visible at a time:
- **AuxLink** shows by itself until a car is paired.
- **AuxLink-phone** and **AuxLink-music** show only for 2 minutes after you
  tap **Pair a phone** or **Pair a music source**.

There is no "AuxLink-car": **AuxLink** is the car side.

### Re-installing or replacing the SD card
Pairings are stored on the SD card, not in the dongles. After flashing a new
card, the car, phone and music device still remember the dongles with the
old keys, so remove the old entries first:
- **In the car:** Bluetooth → remove **AuxLink**.
- **On the phone:** forget **AuxLink-phone**.
- **On the music device:** forget **AuxLink-music**.

Then pair them again as below.

### Steps
1. **Join the setup Wi-Fi.** After the first boot, the Pi turns on its own
   Wi-Fi, **`AuxLink-setup`** (password **`auxlink-setup`**). Join it from a
   phone or the Android device.
   - The setup page opens **by itself**, like a hotel Wi-Fi sign-in page. If
     it doesn't, tap the "Sign in to network" notification or open
     **http://10.42.0.1**.
   - If the phone says "No internet", choose **stay connected**.
   - The setup Wi-Fi is on whenever no car is paired, for 10 minutes after
     each boot, and for 15 minutes after holding the setup button. You can
     change the times and password on the page.
The page has tabs: **Status** (music check, recent events), **Devices**
(pairing, Bluetooth adapters, music source), **Settings**, **Wi-Fi**, **Pi
login** (password, SSH), **Updates** (Pi update; XIAO firmware with the wired
source) and **Development** (services, logs, terminal). With nothing paired
yet it opens on **Devices**; a dot marks a tab that needs attention.

2. **Pi login** tab: set your own login password. Only after that can you turn
   **SSH** on, if you want it. You don't need SSH for anything else here.
3. **Devices** tab, **Bluetooth adapters:** choose which adapter is the **car** side and which
   is the **phone** side. With two dongles, use one each and leave the
   built-in unused. Then tap **Save adapters**.
4. **Pair the car:** in the car's Bluetooth settings, add a new device,
   choose **AuxLink** and confirm the code. The Pi accepts it by itself.
   With no car paired, this side is already visible; otherwise tap
   **Pair a car** first.
   - Your real phone should **not** stay paired directly with the car.
     Remove it from the car's Bluetooth list; it connects through the Pi
     instead.
5. **Pair your phone:** tap **Pair a phone**. Within 2 minutes, go to the
   phone's Bluetooth settings, add **AuxLink-phone** and confirm the code.
   Allow **contacts and call history** access when the phone asks. That is
   what fills the car's contacts and recent calls.
6. **Music source** (Devices tab): choose how music gets into the Pi (see section 5; USB-C is recommended), then
   tap **Save music source**.
   - **Bluetooth:** also tap **Pair a music source** and pair the device with
     **AuxLink-music**.
   - **Wired or USB-C:** also set up the app (section 6).
7. **Wi-Fi** tab (optional): add your home network so that you can open
   http://auxlink.local and install updates from home.
8. **Settings** tab: a page password, whether to pause music for calls, contacts
   sync, the Bluetooth names, turning the music device's volume to 100% when
   it connects (wired/USB-C, on by default), and the car settings in
   [Other cars](#other-cars). The defaults are fine.
9. Use **Check audio** / **Check and fix** on the **Status** tab any time the
   music is not coming through.
10. **Text messages in the car** (Settings tab, test, off by default): the Pi
    reads your phone's texts over Bluetooth (the phone asks once to allow
    message access for AuxLink-phone), offers them to the car like a phone
    does, and tells the car about each new one, so it pops up and can be
    read aloud. Replies from the car are sent by your phone (they appear in
    its sent messages; Recent events says "Reply to ...: sent"; the texts themselves only go to the service's log). If the car
    then hangs on "Connecting..." and resets its Bluetooth, turn it off again.
11. **Development** tab (optional): services, logs, and a terminal on the Pi
    inside the setup page, the same as SSH, with one-tap buttons for the main
    logs. Turn on **Development terminal** in the Settings tab (it needs your own Pi login
    password; set a page password too, since anyone on the setup Wi-Fi can
    open the page). It logs in as the Pi user, so `sudo` asks for that
    password, and it closes after 15 minutes idle.

---

## 5. Music sources

Pick one on the setup page's **Devices** tab (**Music source**). Calls and the car
connection are not affected when you switch.

### 5.1 USB-C (Pi as a USB sound card) (recommended)
The Android device plugs straight into the **Pi's USB-C port**, and the Pi
shows up as a USB sound card (plus a data link and media keys).
- **Tested and working well in the car:** one cable, no XIAO and no wiring,
  with clean audio, track info, album art and the car's buttons. This is the
  recommended source.
- **Power warning: it may not work reliably powered by the music device.**
  Power the Pi externally if you can: 5 V into GPIO **pin 2 or 4**
  plus **GND (pin 6)**, from a solid 5 V / 3 A supply, or through a **USB-C
  power/data splitter**. Its USB-C port is now a data port. Powered by the
  music device alone it may run, but expect drop-outs or restarts (a USB
  host gives 0.5-1.5 A; the Pi needs up to 3 A).
- **Keep the music device's 5 V off the Pi:** the Pi's USB-C 5 V and its
  GPIO 5 V are the same wire, and the device (as USB host) puts 5 V on the
  cable. Use a splitter whose device side is data-only, or a USB
  "power blocker" (data-only) adapter between the device and the Pi.
- After saving, **reboot once**; the page says when this is needed. Saving
  adds `dtoverlay=dwc2,dr_mode=peripheral` to `/boot/firmware/config.txt`
  (and the Pi adds it at boot if it's ever missing, then asks for one more
  reboot). Pi updates leave the USB-C connection up, so the music device
  stays connected.
- **Track info and album art:** from the AuxLink app (v1.0.5 or
  newer), over the same cable.
- **Car buttons:** reach the device as USB media keys.
- **Voice search:** the Pi's USB sound card has a mic too, carrying the
  **car's cabin mic**, the same as the XIAO's.
- **App link after a reboot:** as with the XIAO, if the app hasn't got its
  USB link 15 s after the device connects, the Pi briefly re-plugs its USB-C
  side so Android hands it over (up to three tries). Android asks once for
  this device too: tick **Always**.

### 5.2 Wired: XIAO RP2040 (I2S) (backup)
Proven and reliable, and a good fallback if USB-C doesn't suit your setup
(for example, you can't power the Pi separately).
- **Uses:** the XIAO wired as in section 3.
- **Sound:** the Android device plays into the XIAO, which passes it to the
  Pi over I2S, and the Pi sends it to the car.
- **Track info and album art:** from the **AuxLink** app (section 6),
  over the XIAO's data link.
- **Car buttons:** reach the device as USB media keys.
- **Voice search:** the device's mic input is the **car's cabin mic**. By default
  the car shows a call while it listens, and its hang-up button ends it (see
  [Other cars](#other-cars)).

### 5.3 Bluetooth (phone or player) (last resort)
Works with no cables, but it is the least reliable: it shares the Pi's
Bluetooth radios with the car and phone links, so expect occasional skips.
No XIAO and no wiring.
1. Choose **Bluetooth**, then pick the **adapter** for it. It can't be the
   car's adapter; it can share the phone's, or use the built-in one.
2. Tap **Save music source**, then **Pair a music source**.
3. On the Android device, pair with the name in the banner,
   **AuxLink-music** (or **AuxLink-phone** if it shares the phone's
   adapter).

- **Track info, play state and car buttons:** go over Bluetooth, so the app
  is optional.
- **Album art:** passed straight through from the device over Bluetooth
  (AVRCP cover art, Android 12+ players that publish artwork), so no app is
  needed. It shows from the second track after connecting. Not every device
  keeps offering it (one stopped sending picture numbers after a voice
  search and never resumed). For dependable art install the AuxLink app
  (section 6) and allow it **Nearby devices / Bluetooth**: it then sends the
  art to the Pi over Bluetooth instead, and takes over whenever it is
  connected.
- **Stutter:** the Pi's **built-in** Bluetooth shares its radio with the Pi's
  Wi-Fi, so music on it can skip while the Wi-Fi is busy. Give this source a
  USB dongle if you can.
- **Voice search:** the Pi is also a **Bluetooth headset** to the device, and
  its mic is the **car's cabin mic**. By default the car shows a call while it
  listens, and its hang-up button ends it. Anything the device says back (the
  assistant's answer) plays through the car.
  - In the device's Bluetooth settings for AuxLink-music, leave
    **Phone calls** (or "Headset") **on** as well as **Media audio**.
  - In the Google app: **Settings → Voice → "Record audio through Bluetooth
    devices"** on. Google Assistant uses it anyway.
  - Use a **USB dongle** for this source if you can: the Pi's built-in
    Bluetooth carries this audio over the same path that was unreliable for
    calls.
- **If it connects but is silent:**
  - restart playback on the device, or toggle its Bluetooth;
  - unplug any USB sound card (such as the XIAO) from it, because Android
    sends audio to USB ahead of Bluetooth;
  - check that **Media audio** is on for AuxLink-music in the device's
    Bluetooth settings.

---

## 6. The Android music device and the AuxLink app

The app reads what is playing on the device and sends it to the Pi, which
shows it in the car:
- title, artist, album, length, position, play/pause state;
- album art, from any player that publishes artwork (Spotify, YouTube Music,
  YouTube, Poweramp, ...).

It is needed for the **wired** and **USB-C** sources (over USB). With the
**Bluetooth** source it is optional and only adds album art; it then talks to
the Pi over Bluetooth. Whenever a USB link is plugged in, it uses that.

### 6.1 Install with Obtainium (recommended: automatic updates)
[Obtainium](https://github.com/ImranR98/Obtainium) installs and updates apps
straight from GitHub releases.

1. Install Obtainium on the Android device. Get the APK from its
   [GitHub releases](https://github.com/ImranR98/Obtainium/releases), or from
   F-Droid / IzzyOnDroid.
2. Open Obtainium, tap **Add App** and paste
   `https://github.com/chris-hemmings/auxlink`. Leave the source as
   **GitHub** and tap **Add**.
   - Before tapping **Add**, open the additional options and set
     **Filter release titles by regular expression** to `AuxLink app`. The
     same Releases page also has the Pi image and XIAO firmware, and this
     makes Obtainium look only at the app's releases.
3. Tap **Install**. Allow Obtainium to install apps when Android asks
   ("Install unknown apps").
4. New app releases appear in Obtainium as updates. You can turn on
   background update checks in Obtainium's settings.

### 6.2 Or install by hand
Download the latest `auxlink-v1.0.N.apk` (an "AuxLink app" release) from the
[Releases page](https://github.com/chris-hemmings/auxlink/releases) on
the device and open it. To update, install the newer APK over the top; it is
signed with the same key.

### 6.3 Set the app up (once)
1. Open **AuxLink** and tap **Open notification access settings**.
   Turn on **AuxLink**. This is how Android lets it see what is
   playing; it does not read your notifications' content.
   - If the switch is **greyed out** ("restricted setting"), go to
     **Settings → Apps → AuxLink → ⋮ (top right) → Allow restricted
     settings**, then try again. Android 13+ does this for apps installed
     outside the Play Store.
   Allow **Nearby devices / Bluetooth** if the app asks: that's only used for
   the Bluetooth music source. Allow **Microphone** too: nothing is recorded,
   but without it Android's USB prompt (the XIAO is also a USB sound card)
   has no **Always** option and comes back at every plug-in.
2. Plug in the XIAO (or connect the device to the Pi's USB-C). Android asks
   **"Open AuxLink (USB) when this device is connected?"** Tick
   **Always** and tap **OK**.
   - This is the USB permission. Nothing visible opens on later plug-ins,
     and the app never asks again by itself. If you missed **Always**, the
     app screen shows "USB access: NOT allowed": tap **Allow USB**, or
     re-plug the XIAO and tick **Always**.
   - No **Always** tick box, only a warning about recording audio? Allow the
     app's **Microphone** permission (step 1) and re-plug.
   - After the device restarts with the XIAO still plugged in, Android
     doesn't count that as a plug-in. The XIAO (firmware 1.0.2+) and the
     Pi's USB-C mode notice the app has no link and re-plug themselves once,
     about 15 s in, so nothing needs tapping.
3. Go back to the app. Its status should show:
   - Notification access: **granted**
   - XIAO plugged in: **yes**
   - Data link open: **yes - USB** (or **yes - Bluetooth** for the Bluetooth source)
4. Tap **Let AuxLink run in the background** and allow it (the status line
   "Background running" then says **allowed**), so battery saving never stops
   it. Allow notifications too: the app keeps a quiet "AuxLink connected"
   notification, which keeps Android (and head units' app killers) from
   closing it.
5. Play something. The car shows the track and, after a second or two, the
   album art. Each time the SMO connects, the Pi turns its media volume up to
   100% (Android starts USB audio low); use the car's volume. Turn this off
   on the setup page (Settings) if you prefer.

The app runs in the background by itself. You don't need to keep it open.
If the car ever shows an old track, play/pause once; the app re-checks every
5 seconds which player is playing.

The app's screen shows what it needs (notification access, microphone,
background running, USB access, the data link) and what it last sent. Its
buttons:
- **Open notification access settings**, **Let AuxLink run in the
  background** and **Allow USB**: the one-time permissions above.
- **Fix sound** (needs the data link): the car shows music playing but it's
  silent. The Pi restarts the music stream to the car, like **Check and
  fix**. Pausing and pressing play again in the car within a few seconds does
  the same.
- **Setup: turn on the setup Wi-Fi** (needs the data link): the Pi turns on
  its setup Wi-Fi for 15 minutes. Connect the device to **AuxLink-setup**
  (password `auxlink-setup` unless changed). If the Pi is on your home Wi-Fi
  it doesn't start the setup Wi-Fi; its page is then on the home network.
- **Open setup page**: finds the Pi on its setup Wi-Fi (10.42.0.1) or on the
  same network as the device (auxlink.local) and opens its page in the
  browser.

While the app is connected it also sends a small "still here" message every
5 seconds, so the Pi and the XIAO know it has its link.

**Calls and texts on the music device** (Settings tab, on by default; USB-C
or Bluetooth source, not the XIAO yet): an incoming call pops up with the
caller's name (from the synced contacts) and **Answer** / **Decline**
buttons that answer or decline it on your phone; new texts show as
notifications (with **Text messages in the car** on). Allow the app's
notifications; each kind can be turned off in Android's settings for the app.

### 6.4 Other requirements for the device
- **Android 8.0 or newer.**
- **USB host / OTG** for the wired source (the XIAO).
- For the **USB-C source**, the device must be able to output audio to a USB
  sound card. Almost all Android 8+ devices can.
- The **Google app / Assistant** (or the head unit's own voice search) uses
  the USB mic automatically when the XIAO or the Pi's USB-C is plugged in. For
  the Bluetooth source it needs a Bluetooth-headset-aware voice app (see 5.3).

---

## 7. Updating

- **The Pi:**
  - **From the web page:** go to the **Updates** tab, choose `auxlink-pi-update-X.zip`
    from the latest "AuxLink Pi image" release (or GitHub's "Download ZIP" of
    this repository) and tap **Install update**.
    No reboot is needed, and the car and phone stay connected.
  - **Over SSH:** `git clone` (or `git pull`) this repository, then
    `cd auxlink/pi && sudo ./update.sh`.
  - Or flash the newest image again (it starts unpaired).
- **The app:** Obtainium (or install the newer APK).
- **The XIAO:** only when there's a new "AuxLink XIAO firmware" release.
  Easiest: the setup page's **Updates** tab (**XIAO firmware**). Hold **B**, plug the
  XIAO into one of the Pi's USB ports, choose the `.uf2` and tap **Flash
  this file** (no Pi update needed). Or flash it from a computer or an
  Android device's Files app with BOOT held, as in 3.1. Afterwards Android
  asks once more (tick **Always**).

---

## Other cars

AuxLink uses only standard Bluetooth profiles, so it works with any car that
supports Bluetooth calls and music:
- **Calls:** HFP.
- **Music:** A2DP.
- **Track info and buttons:** AVRCP.
- **Album art:** AVRCP 1.6 cover art.
- **Contacts and recent calls:** PBAP.

Its defaults were tuned on a Tesla. Three settings on the setup page
(**Settings** tab) let you adjust it for other cars:

| Setting | Default (Tesla) | Try this if... |
|---|---|---|
| **Pi reconnects the car itself** | off: the Pi waits for the car to connect | the car doesn't reconnect by itself after it starts. The Tesla dropped (or ignored) connections the Pi started. |
| **Car mic for voice search** | *Shown as a call* | the car shows a call you'd rather not see: try *Voice recognition*, the standard way. The Tesla ignores it, but many cars support it. |
| **Higher-quality music (SBC-XQ)** | off | you want better sound and the car supports it. The Tesla disconnected when it was switched on. |

Album art only shows on cars that display cover art for phones. Everything
else works without it.

**Pi powered by the car:** the Pi takes 30-40 s to start, and a car that
looks for its phone as soon as it wakes may have given up by then (the Tesla
does, and ignores the Pi calling it). Keep the Pi powered while the car is
awake (Tesla: **Controls → Electrical → Keep Accessory Power On**), or tap
**AuxLink** in the car's Bluetooth list once the Pi is up.

---

## 8. Troubleshooting

| Problem | Try |
|---|---|
| Can't find the setup page | Join `AuxLink-setup` and open http://10.42.0.1. If the setup Wi-Fi is off, hold the setup button 3 s, or reboot (it is on for 10 minutes after boot). |
| No music in the car | Setup page → Music → **Check audio**, then **Check and fix**. Check that the car's media source is **Bluetooth / AuxLink**. |
| Silent or only one side | **Check and fix** recreates the audio path. With the wired source, check the three I2S wires and their ground. |
| No track info (wired) | App status: notification access granted, XIAO plugged in, data link open. Re-plug the XIAO. Check the serial wires (D6 → pin 10, D7 ← pin 8). |
| No album art | With the image it is built in; on a manual install run `build-bluetoothd-cover.sh` (2.2). Test with `sudo cover-test.sh` on the Pi, then turn the car's Bluetooth off and on once. |
| No contacts / recent calls in the car | With a manual install, build the contacts server (2.2). Allow contacts and call history on the phone, then on the setup page restart the services. |
| Car doesn't reconnect | It reconnects by itself when it wakes. After a fresh start of the Pi it may already have given up: see "Pi powered by the car" in [Other cars](#other-cars). Otherwise open **Recent events / Logs** on the setup page. |
| Car pairs, then shows "Connecting..." for a minute and restarts its Bluetooth | Update the Pi (1.0.44+): older versions offered the car an empty text-messages service that some cars wait on. If **Text messages in the car** is on (Settings), turn it off. |
| Music shows as playing but is silent (e.g. the car connected after the music started) | Pause and play again in the car within a few seconds, or the app's **Fix sound**, or **Check and fix**. |
| USB-C source: the music device lost its connection to the Pi | **Check and fix**, or pause and play again in the car within a few seconds: both re-plug the USB-C connection in software when it's broken (never a working one). If it reports "stuck", reboot the Pi. |
| The app asks for USB access at every plug-in | Allow the app's **Microphone** permission, re-plug the XIAO and tick **Always**. |
| After a restart of the music device the app has no data link | Update the XIAO to firmware 1.0.2+ (it re-plugs itself); meanwhile tap **Allow USB** in the app. |
| The app stops sending after a while | In the app tap **Let AuxLink run in the background**, allow notifications, and allow AuxLink in any app-killer / auto-start list on the device. |
| Music device volume low | The Pi turns it to 100% when the device connects (Settings, wired/USB-C, needs the app). Check the setting is on. |
| Music skips with the Bluetooth source | The built-in Bluetooth shares the Wi-Fi radio: use a USB dongle for the source. |
| Logs over SSH | `journalctl -u auxlink-media -u hfp-relay -u auxlink-pairing -f` and `journalctl --user -u auxlink-audio -f` |

---

## 9. Building from source (optional)

**XIAO firmware**: Rust; the pinned toolchain installs itself.
```bash
cd firmware/rp2040
cargo build --release --bin source --features rp2040-zero,smo-mic,ultra-low
python3 uf2.py target/thumbv6m-none-eabi/release/source auxlink-xiao.uf2
```
The Pi carries a copy (the setup page's "Flash built-in firmware"): after a
firmware change, also copy the new `.uf2` to `pi/share/auxlink-xiao.uf2` and
put its version in `pi/share/auxlink-xiao.version`.
`smo-mic` includes `media-keys`, and `ultra-low` includes `clock-steered`,
which is the build the pinout above is for. `rp2040-zero` selects the
RGB-LED status code that the XIAO also uses.

**Releases** are built by GitHub Actions (Actions tab → workflow → **Run
workflow**):
- **Build AuxLink Pi image** (`pi-image.yml`, asks for a version): builds
  the SD-card image on a native ARM runner (`pi/image/build-image.sh`, about
  an hour) and publishes it with the update zip.
- **Build AuxLink XIAO firmware** (`xiao-firmware.yml`, asks for a version).
- **Build AuxLink app** (`release.yml`): runs by itself on every push to
  `main` that changes `android/`.
- **Remove old releases** (`cleanup-releases.yml`): runs after each
  successful build and keeps only the newest app, Pi image and XIAO firmware
  release.

**Android app**: open `android/` in Android Studio, or run
`gradle assembleRelease`. The GitHub Actions workflow
(`.github/workflows/release.yml`) builds and signs it on every push to `main`
and publishes the release that Obtainium follows. It needs the
`SIGNING_KEYSTORE_BASE64`, `SIGNING_STORE_PASSWORD`, `SIGNING_KEY_ALIAS` and
`SIGNING_KEY_PASSWORD` repository secrets.

---

## Credits
The XIAO firmware is based on [TeslAux](https://github.com/jbschooley/TeslAux)
by jbschooley (MIT, see `firmware/rp2040/LICENSE-TeslAux`).
