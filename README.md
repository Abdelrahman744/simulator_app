# Resilient App Lab

A teaching-lab Flutter app that demonstrates connectivity checks, request timeouts, exponential-backoff retries, and friendly user feedback — all in one screen, zero extra state-management packages.

---

## Prerequisites

| Tool | Version |
|---|---|
| Flutter | 3.x (stable) |
| Dart | bundled with Flutter |
| Node.js | 18 or newer |
| Android SDK | cmdline-tools installed in `ANDROID_HOME/cmdline-tools/latest` |

> [!IMPORTANT]
> **No Android Studio needed.** Everything runs from the command line.

---

## One-time emulator setup

Run these once; skip if you already have a working AVD.

```powershell
# 1. Set ANDROID_HOME (PowerShell – adjust path if needed)
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\sdk"
$env:PATH = "$env:ANDROID_HOME\cmdline-tools\latest\bin;" +
            "$env:ANDROID_HOME\platform-tools;" +
            "$env:ANDROID_HOME\emulator;$env:PATH"

# 2. Install required SDK components
sdkmanager "platform-tools" "emulator" `
            "platforms;android-34" `
            "system-images;android-34;google_apis;x86_64"

# 3. Accept licenses
flutter doctor --android-licenses

# 4. Create the AVD
avdmanager create avd -n lab_avd `
            -k "system-images;android-34;google_apis;x86_64" `
            -d pixel_6
```

> [!NOTE]
> On Apple Silicon use `arm64-v8a` instead of `x86_64`.
> Hardware acceleration (WHPX / Hyper-V on Windows) must be available; if not, use a real phone with USB debugging.

---

## Running the lab

### Terminal 1 — start the simulated server

```bash
node server/server.js
```

The server listens on `http://0.0.0.0:8080`.

### Terminal 2 — start the emulator

```powershell
# Set PATH as above, then:
emulator -avd lab_avd

# Wait for boot, then confirm:
adb devices
flutter devices
```

### Terminal 3 — run the Flutter app

```bash
# Emulator (default):
flutter run

# Multiple devices — pick one:
flutter run -d lab_avd

# Real phone on the same LAN:
flutter run --dart-define=SERVER_URL=http://<PC-LAN-IP>:8080
```

---

## Changing server modes

Use the in-app dropdown **or** curl directly:

```bash
curl -X POST "http://localhost:8080/mode?set=normal"
curl -X POST "http://localhost:8080/mode?set=slow"
curl -X POST "http://localhost:8080/mode?set=flaky"
curl -X POST "http://localhost:8080/mode?set=hangs"

# Check current mode:
curl http://localhost:8080/mode
```

| Mode | Behaviour |
|---|---|
| `normal` | Instant 200 response |
| `slow` | 2-second delay, then 200 |
| `flaky` | 503 × 2, then 200 (counter resets; demo is repeatable) |
| `hangs` | Never replies — connection held open for 60 s |

---

## Toggling airplane mode on the emulator

```bash
# Enable
adb shell cmd connectivity airplane-mode enable

# Disable
adb shell cmd connectivity airplane-mode disable

# Fallback (if the above doesn't work on your API level)
adb shell svc wifi disable && adb shell svc data disable
adb shell svc wifi enable  && adb shell svc data enable
```

---

## Expected scenarios

| # | Scenario | Expected |
|---|---|---|
| 1 | Normal → Load | Data appears immediately |
| 2 | Slow → Load | Spinner ~2 s, then data (no "Still working...", no error) |
| 3 | Airplane mode ON → Load | "You're offline. Turn off airplane mode and try again." |
| 4 | Airplane mode OFF | App retries by itself, shows data — no tap needed |
| 5 | Flaky → Load | "Retrying in 1s (attempt 2 of 3)...", then "Retrying in 2s (attempt 3 of 3)...", then data. Server log shows 503, 503, 200 |
| 6 | Hangs → Load | "Still working..." after 3 s; times out × 3 attempts (~18 s total); "The server is taking too long." + Try again |
| 7 | Cancel during Hangs | Stops immediately, "Cancelled.", Load re-enables |
| 8 | Load Normal, then Hangs → Load | Old data stays + "Showing earlier data (couldn't refresh)" note |

---

## Project structure

```
simulator_app/
├── lib/
│   └── main.dart          ← entire Flutter app (single file)
├── server/
│   └── server.js          ← simulated server (plain Node.js, no npm)
├── android/
│   └── app/src/main/
│       └── AndroidManifest.xml   ← INTERNET + cleartext traffic permissions
├── pubspec.yaml           ← http + connectivity_plus dependencies
└── README.md
```
