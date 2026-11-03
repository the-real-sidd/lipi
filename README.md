<p align="center"><img src="Support/icon.png" width="128" alt="Lipi icon"></p>

<h1 align="center">Lipi</h1>
<p align="center"><b>Speak Hindi. Type English.</b> Fast, private voice typing for Mac. Everything runs on your Mac.</p>

---

Lipi (लिपि, "script") is a menu-bar dictation app in the spirit of Wispr Flow, built for people who think and speak in Hindi or Hinglish but need to write in English. Hold a key, speak, let go: the text appears wherever your cursor is, already translated.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/the-real-sidd/lipi/main/install.sh | bash
```

Needs an Apple Silicon Mac on **macOS 26 or newer**. The app is about 1.5 MB. On first launch Lipi asks macOS to download the speech and translation languages you pick. macOS manages those files, shares them with other apps, and keeps them updated.

## What it does

| | |
|---|---|
| **Hold Right ⌥, speak** | Lipi types what you said, cleaned up, in the language you spoke (Hinglish stays Hinglish) |
| **Hold Right ⌘, speak** | Speak Hindi, Hinglish or English, and Lipi types it in English (or any language you pick) |
| **Double-tap either key** | Hands-free: keep talking, tap again to finish, Esc to cancel |
| **Double-tap ⌥ on selected text** | Translate it: auto-detect, Hindi → English, English → Hindi, or any pair |
| **AI mode** | Free Gemini key from Google AI Studio (two clicks): removes fillers, handles "no wait, Monday", fixes misheard words, natural Hinglish → English |
| **Notes** | Notices Zoom / Meet / Teams / FaceTime / Slack calls, offers to take notes, transcribes you ("Me") and the call ("Others"), summarises, stops when the call ends |
| **Style** | Formal / Casual / very casual, per app type: personal chats, work chat, email, other |
| **Learns from you** | Fix a word Lipi typed and it remembers: spellings and names go into your dictionary, translation fixes are reused for the same topic |
| **Voice commands** | "new line" (blank line), "scratch that", "heart emoji", "… send" to press Return |

All three shortcut keys can be changed in **Settings → General** (Right ⌥, Left ⌥, Right ⌘, Right ⌃ or fn). Lipi never lets two actions share a key.

### Mixed Hindi and English

When Hindi is your language, Lipi runs Apple's Hindi and Indian-English recognizers on the same audio at once and keeps whichever matches what you actually said. So English sentences come out as English instead of being forced through Hindi.

### Headphones stay in music mode

Lipi records from the Mac's built-in mic by default, and only while you dictate. Bluetooth headphones therefore never drop into low-quality "call mode", so music doesn't get muffled. The mic starts in about 40–60 ms.

## How it's fast and small

Murmur, the app Lipi was modelled on, needs a 9 GB install (Ollama + two 4B LLMs + Whisper) and transcribes only after you stop talking. Lipi uses the models built into macOS and streams everything:

| | Murmur | Lipi |
|---|---|---|
| Install size | ~9 GB | **~1.5 MB** app + OS-managed language packs |
| Speech-to-text | Parakeet / Whisper, after you let go | Apple `SpeechAnalyzer`, **while you speak** |
| Translation | 4B LLM via Ollama | Apple `Translation` on-device, or Gemini in AI mode |
| Cleanup | 4B LLM on every dictation | Instant rules on-device; Gemini in AI mode |

Measured on an M1 with 8 GB, from releasing the key to text on screen (automated tests, real audio at speaking speed):

| | On-device | AI mode |
|---|---|---|
| Median | **~180 ms** | **~0.9 s** |
| Worst case | ~260 ms | ~1.9 s |

## Privacy

There's no account and no analytics. Audio is never saved or sent anywhere. In AI mode, the text of each dictation is sent to Google Gemini with your own key (Google may review it on the free plan); turn AI mode off for private chats. Locally stored:
- `~/Library/Application Support/Lipi/`: dictionary, history, meeting notes, your Gemini key (file readable only by your user)
- `~/Library/Logs/Lipi.log`: timings and lengths only, never what you said

## Build from source

```bash
git clone https://github.com/the-real-sidd/lipi && cd lipi
scripts/build.sh          # -> build/Lipi.app
scripts/build.sh --zip    # -> build/Lipi.zip for a release
```

Only the Xcode Command Line Tools are needed (Swift 6). The SwiftUI `@State` macro isn't available without full Xcode, so views use `@ViewState`, an alias for the same property wrapper.

Test suites (run before every release):

```bash
L=build/Lipi.app/Contents/MacOS/Lipi
$L --test-gestures      # every shortcut sequence: hold, tap, double-tap hands-free, Esc, clashes
$L --test-text          # fillers, numbers, commands, emoji, send, styles, learning
$L --test-audio         # spoken clips through the live pipeline at speaking speed (add --ai-only for AI mode)
$L --test-e2e           # the running app (defaults write app.lipi.mac testHooks -bool YES) pastes into TextEdit;
                        # also checks the mic is closed when idle and headphones keep music quality
```

## Known limits

- **Not notarized.** Releases are signed with a self-made "Lipi Signing" certificate, not an Apple Developer ID. Permissions survive updates, and the curl installer isn't blocked by Gatekeeper.
- **On-device Hinglish → English is decent, not perfect.** Apple's translator struggles with some Hinglish idioms. AI mode fixes this.
- **Notes on a real call:** capturing the other side needs macOS's one-time *System Audio Recording* permission. This hasn't been tested on a live call yet.
- **Shortcut clashes:** the Claude and ChatGPT desktop apps also react to a double-tap of ⌥. If that's a problem, use Right ⌘ or fn for Lipi.

## Layout

```
Sources/Lipi/
  AppDelegate.swift        hotkeys → record → pipeline → insert; meeting flow; menu bar
  SpeechEngine.swift       SpeechAnalyzer sessions, standby pre-warming, asset installs
  Audio.swift              Core Audio HAL mic capture (built-in mic, never the default device)
  Pipeline.swift           cleanup → translate → smart cleanup → style → dictionary
  Translator.swift         Apple Translation sessions, batching, warm-up
  TextCleanup.swift        fillers, stutters, voice commands
  NumberWords.swift        spoken numbers → digits
  Learning.swift           learns from your corrections (dictionary + translation memory)
  StyleEngine.swift        per-app style detection + formal/casual/very casual rules
  Hotkey.swift             gesture state machine (hold, hands-free double-tap, Esc) + key monitor
  AIService.swift          Gemini client: model auto-pick, retired-model recovery, warm connection
  AIWriter.swift           cleanup / translation / summary prompts
  Inserter.swift           paste with clipboard restore, read selection, cursor spacing
  Meetings/                detector (Core Audio), system-audio tap, recorder, summarizer, store
  UI/                      SwiftUI main window: Home, Notes, Style, Dictionary, Settings
```
