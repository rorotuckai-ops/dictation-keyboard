# Dictation Keyboard

An iOS keyboard for on-device voice dictation and text cleanup. Everything runs on your iPhone:
no accounts, no servers.

- **Mic button**: records inside the keyboard (hidden WKWebView `getUserMedia`, the approach
  from the MIT-licensed [Hex](https://github.com/anomalyco/hex/blob/dev/ios/README.md) keyboard)
  and transcribes with Apple's on-device `SpeechAnalyzer` (falls back to `SFSpeechRecognizer` with
  `requiresOnDeviceRecognition`). The text goes in at the cursor.
- **Spoken corrections**: "sorry I mean Tuesday", "scratch that", "delete the last sentence" and
  "no wait, make it 5pm" are applied by rules in the keyboard
  ([`SpokenCorrections.swift`](Shared/SpokenCorrections.swift)). Cases the rules can't resolve
  confidently go to Gemma in the host app.
- **Fix text / Rewrite**: send the selected text (or the text around the cursor) to Gemma in the
  host app. Fix cleans up grammar, punctuation and filler words; Rewrite rewrites it. The result
  replaces the original only if the text hasn't changed meanwhile, and **Undo** puts it back.
- **Record in the app**: the app's Dictate tab records too. The result screen shows what each
  spoken correction changed (Monday → Tuesday); tap **Insert** on the keyboard to place it.
- **Gemma, offline**: Gemma 4 E2B (`.litertlm`) runs in the host app with
  [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM). The keyboard and the app talk through
  files in a shared App Group. With **Stay ready in background** on, the app keeps running in the
  background, so Fix works without leaving the app you're typing in. Otherwise the keyboard opens
  the app, and the result is applied when you come back.

The keyboard extension doesn't link the model or LiteRT, so it stays well under the ~60-90 MB
keyboard memory limit. Audio capture runs in WebKit's own process.

## Requirements

- A Mac with Xcode 26 or newer, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`)
- An iPhone on iOS 26 or newer (iPhone 15 Pro or newer recommended for Gemma 4 E2B: it needs
  about 3 GB of free memory and 2.6 GB of storage)
- A free Apple ID

## Sideload with Xcode (free Apple ID)

1. Clone the repo and generate the project:
   ```sh
   git clone https://github.com/rorotuckai-ops/dictation-keyboard.git
   cd dictation-keyboard
   xcodegen generate
   ```
2. Edit [`Config/Base.xcconfig`](Config/Base.xcconfig):
   - set `BUNDLE_ID_PREFIX` to something unique to you, e.g. `com.yourname.dictkb`
     (free accounts can't reuse someone else's bundle ID);
   - set `DEVELOPMENT_TEAM` to your team ID (Xcode › Settings › Accounts › your Apple ID ›
     the Personal Team's ID), or leave it empty and pick the team in step 4.
3. Open `DictationKeyboard.xcodeproj` in Xcode. Under Xcode › Settings › Accounts, add your
   Apple ID if it isn't there yet.
4. If you left `DEVELOPMENT_TEAM` empty: select the project, then for **both** the
   `DictationKeyboard` and `DictationKeyboardExtension` targets go to Signing & Capabilities and
   pick your Personal Team. Xcode registers the App Group (`group.<your prefix>`) for you.
5. Plug in your iPhone, unlock it and tap **Trust**. On the iPhone, turn on
   Settings › Privacy & Security › **Developer Mode** and restart when asked.
6. Pick your iPhone as the run destination and press **Run** (⌘R).
7. On the iPhone, open Settings › General › **VPN & Device Management**, tap your Apple ID and
   tap **Trust**. Then open the app again.
8. Continue with [First run](#first-run).

Free Apple ID apps expire after **7 days**: plug in and press Run again to renew. This app uses
2 of the 3 app IDs a free account may have at once (the app and its keyboard).

## Sideload with SideStore or AltStore

1. Build an `.ipa` on your Mac (no signing needed; SideStore/AltStore re-sign it):
   ```sh
   brew install xcodegen
   xcodegen generate
   scripts/build-ipa.sh            # writes build/DictationKeyboard.ipa
   ```
2. Copy `build/DictationKeyboard.ipa` to your iPhone (AirDrop, iCloud Drive or Files).
3. In SideStore or AltStore, go to **My Apps**, tap **+**, and pick the `.ipa`. Allow it to
   register both App IDs (the app and the keyboard extension) when asked.
4. Continue with [First run](#first-run). Refresh the app in SideStore/AltStore within 7 days.

Use SideStore/AltStore, not **LiveContainer**: LiveContainer runs apps inside its own process and
doesn't register their extensions with iOS, so the keyboard would never appear in Settings.

## First run

1. Open **Dictation Keyboard**.
2. Tap **Download Gemma 4 E2B** (2.6 GB, one time, over Wi-Fi), or **Import .litertlm from Files**
   if you already have the file (from
   [Hugging Face](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm)). You can
   also drop it in the app's folder with Finder (iPhone › Files › Dictation Keyboard). After this,
   everything works offline.
3. Tap **Allow mic and download speech model** and allow both prompts (Apple's speech model
   downloads once).
4. Settings › General › Keyboard › Keyboards › **Add New Keyboard** › **Dictation Keyboard**.
   Tap it and turn on **Allow Full Access** (needed for the mic and for talking to the app; no
   data leaves the phone).
5. Open Notes, tap the globe key and pick Dictation Keyboard. Tap the mic, speak, tap again.

Keep **Stay ready in background** on and leave the app in the app switcher, so Fix and tricky
corrections run without switching apps.

## Develop

```sh
xcodegen generate
xcodebuild -scheme DictationKeyboard -destination 'platform=iOS Simulator,name=iPhone 17' test
```

The simulator has no microphone. In Debug builds the keyboard uses
`<App Group>/fixtures/dictation.wav` in place of the mic when that file exists, which is how the
demo recordings were made.

## Layout

| Path | What |
|---|---|
| `App/` | Host app: setup, Gemma (`ModelService`), request server (`BridgeServer`) |
| `Keyboard/` | Keyboard extension: UI, WebKit mic capture, opening the app |
| `Shared/` | App Group bridge, spoken-correction rules, prompts, on-device transcription |
| `Tests/` | Unit tests for the correction rules, UI test for the host app |
