# Logos

Logos is a dictation app for the Mac menu bar. Hold Option, speak, and let go: Logos transcribes what you said, has a language model clean it up with a prompt you write, and pastes the result wherever you're typing. You choose the speech model and the language model, and you can read and edit the cleanup prompt.

There is no Logos server. The app calls each provider's API directly from your Mac with your own API keys, which it keeps in a config file on your machine. It has no third-party dependencies, only Apple frameworks.

## Get started

You need macOS 26 or later. Setup takes about five minutes.

To have a coding agent such as Claude Code, Cursor, or Codex do it for you, give it https://logosvoice.dev/install.md, or use the **Copy prompt** button on [logosvoice.dev](https://logosvoice.dev).

1. Install Apple's free Command Line Tools, which Logos builds with. Skip this step if you already have Xcode.

   ```sh
   xcode-select --install
   ```

2. Install Logos:

   ```sh
   curl -fsSL https://logosvoice.dev/install.sh | bash
   ```

   The installer builds Logos from source on your Mac, so you need no developer account. It installs `/Applications/Logos.app`, links the `logos` command into `~/.local/bin`, and starts the app. A waveform icon appears in the menu bar.

3. Allow the two permissions macOS asks for:
   - **Microphone**, so Logos can record while you hold the key. Click **Allow**.
   - **Accessibility**, so Logos can notice the hotkey in other apps and press ⌘V for you. Open System Settings → Privacy & Security → Accessibility and turn on **Logos**. Until you do, holding Option does nothing, because Logos can't see the key. Logos notices the change within a few seconds, so you don't need to restart it.

4. Add an Anthropic API key for cleanup. Without one, Logos pastes the raw transcript and shows `Cleanup failed, pasted raw text: No anthropic key under "keys" in config.json` after every dictation. To dictate without cleanup and without the message, turn off **Clean up transcripts** under **Cleanup** in **Settings… → Config**.
   1. Sign in at [console.anthropic.com](https://console.anthropic.com), open **API Keys**, and create a key. The page shows the key only once, so copy it now.
   2. Click the waveform icon in the menu bar, choose **Settings…**, and paste the key into **anthropic** under **API keys** on the **Config** tab. Logos saves it as you type.

5. Click into any text field, hold Option, say a sentence with an "um" in it, and let go. The cleaned-up text appears where you clicked.

Transcription starts on Apple's on-device speech model, which needs no key and keeps your audio on your Mac. For faster and more accurate transcription, switch to Groq. The next section shows how, and Groq's free tier covers everyday dictation.

## Choose a speech model

The speech model turns your recording into a raw transcript. Pick it from the **Model** menu under **Transcription** in **Settings… → Config**, or type any `provider/model` name there. The change applies to your next dictation.

| Model | Runs | Key | Speed | Hears your dictionary |
| --- | --- | --- | --- | --- |
| `apple` (default) | On your Mac | None | Fast | No |
| `apple/dictation` | On your Mac | None | Fast | Yes |
| `groq/whisper-large-v3-turbo` | Groq's servers | Groq, free tier | About 0.3 seconds | Yes |
| `openai/gpt-4o-transcribe` | OpenAI's servers | OpenAI, paid | About 1–2 seconds | Yes |
| `openai/gpt-4o-mini-transcribe` | OpenAI's servers | OpenAI, paid | Faster than `gpt-4o-transcribe` | Yes |

- **`apple`** keeps your audio on your Mac and works offline. It misses more names and technical words than the server models, and it ignores your dictionary. The first dictation downloads the model for your language.
- **`apple/dictation`** is the model behind macOS keyboard dictation. It also runs on your Mac, and it listens for the words in your dictionary.
- **`groq/whisper-large-v3-turbo`** is the recommended upgrade. It runs OpenAI's Whisper model on Groq's servers, returns a short dictation in about a third of a second, and spells names better than Apple's models.
- **`openai/gpt-4o-transcribe`** is often the most accurate with accents, jargon, and fast speech, and it costs a fraction of a cent per dictation.

### Set up Groq

1. Sign in at [console.groq.com](https://console.groq.com), open **API Keys**, and create a key. Copy it, because the page shows it only once.
2. In **Settings… → Config**, paste the key into **groq** under **API keys**.
3. Under **Transcription**, choose `groq/whisper-large-v3-turbo` from the **Model** menu.

Groq's free tier has no credits to run out. It's rate-limited instead: about 2,000 transcriptions a day, plus caps per minute and on audio per hour. A busy day of dictation uses a small fraction of that. If you hit a limit, Logos shows Groq's error instead of pasting. Switch back to `apple` in the same menu until the limit resets.

### Set up OpenAI

Create a key at [platform.openai.com](https://platform.openai.com) under **API keys**, paste it into **openai** under **API keys**, and choose an `openai/` model under **Transcription**. OpenAI bills per minute of audio, so add a payment method to your OpenAI account first.

### Compare models on your own voice

Each line of `~/.config/logos/history.jsonl` records a dictation's model, its `raw` transcript before cleanup, and `transcribeSeconds`. Dictate with one model for a while, switch, and compare the two in that file.

## Choose a cleanup model

The cleanup model rewrites the raw transcript with your prompt: it removes filler words, applies your corrections, fixes punctuation, and spells your dictionary's words right. Pick it from the **Model** menu under **Cleanup** in **Settings… → Config**.

- **`anthropic/claude-opus-5-5`** is the default.
- **`anthropic/claude-haiku-5-5`** answers faster and costs less, and it handles most dictation well.
- **Effort**, Anthropic models only, trades speed for care. `low` is the default and suits dictation.
- **Other providers** work too: `openai/<model>`, `groq/<model>`, `openrouter/<vendor>/<model>`, or `ollama/<model>` for a model running on your Mac in [Ollama](https://ollama.com), which needs no key.

Turn off **Clean up transcripts** to paste the raw transcript. When cleanup fails, Logos pastes the raw transcript and shows why.

## Teach Logos your words

Logos gets names, product names, and jargon right when they're in your dictionary. Open **Settings… → Dictionary** and add one word or phrase per line:

```
Ninjudd
Ghostty
logos: "Logos" for the app or project, "logos" for the command
```

An entry sets the spelling, not the capitalization: the cleanup model picks the letter case from context. To say how, add a note after `: `, as in the last line. Lines that start with `#` are ignored. Every model except `apple` listens for these words, and the cleanup model spells them as written.

## Use your contacts

Logos can spell the people you mention the way your contacts list them. In **Settings… → Config**, turn on **Use my contacts for names** and allow Contacts access when macOS asks.

Logos reads your contacts on your Mac and keeps up with them, so a contact you add or change works on your next dictation. It matches each transcript against them there, and only the names of the people the transcript seems to mention, at most five, go to the cleanup model:

- **A name counts** when the transcript capitalizes it, as speech models do for names. A capitalized word that starts a sentence counts alone only as an exact name of five letters or more, so "Will you…" doesn't bring in Will.
- **A full name ranks first**: a first name or nickname followed directly by the last name, such as "Jon Grub". Ordinary words in a row can sound like a name, as "will write" sounds like William Wright, so a pair counts only when the transcript capitalizes one of its words as a name, or when both words are spelled exactly as the contact's are. At most two of the five people may rest on a single name.
- **Close matches count**: names that sound alike, such as "Grub" for Grubb or "Kirsten" for Kristin, typos, and short forms of first names, such as "Jon" for Jonathan.
- **Other people's email addresses never go.** Logos doesn't read them, since those people didn't agree to share them with your cleanup provider.

To have Logos fill in your own email address, turn on **Include my email addresses**. When a dictation mentions mail or an address, as in "send it to my email", the cleanup model gets the addresses on your own card in Contacts, if contacts are on, plus any you type under **Other email addresses**. The typed addresses work without Contacts access.

## Tune the prompt

**Settings… → Prompt** holds the cleanup prompt, which Logos sends to the cleanup model with every dictation. Change it to match how you write: keep your own punctuation habits, format lists a certain way, or leave your phrasing alone. Logos rereads it on every dictation. The [prompt reference](#prompt-reference) lists the placeholders it can use.

To try a prompt change without dictating, run a recording through it with `logos transcribe`:

```sh
say -o /tmp/test.wav --data-format=LEI16@16000 "um so I think we should meet at three, no wait, at four"
logos transcribe /tmp/test.wav --app Slack
```

It prints the raw and cleaned text and how long the whole run took.

## Pick the hotkey and the microphone

- **Hotkey.** In **Settings… → Config**, click the hotkey button and press the key you want to hold. A modifier counts when you press and release it alone, such as Right Option or Fn. Any other key works too, alone or with modifiers, such as F13 or ⌃Space. Logos keeps that key from reaching other apps, so pick one you don't otherwise use.
- **Microphone.** Logos records from your Mac's built-in microphone, even when macOS switches its default input to an audio interface or a display. To use another microphone, choose it from the **Microphone** menu. Logos falls back to the built-in microphone while the one you chose isn't connected.

## Use it

Hold the hotkey, talk, and let go.

- **While you hold the key**, a pill at the bottom of the screen shows the frequencies in your voice, low pitches on the left. A spinner follows while Logos transcribes and cleans up.
- **A hold with nothing said** shows "No speech detected" and pastes nothing. Logos measures how loud each recording is before it transcribes it, and a recording quieter than `silenceThresholdDB` goes to no model. Given silence, Whisper models can answer with made-up text, often a word from your dictionary.
- **A quick tap** shorter than `minHoldSeconds` is ignored. Pressing another key or clicking while you hold a modifier hotkey cancels the recording, so the modifier's shortcuts keep working.
- **With no text field focused**, such as on the desktop, Logos shows the dictation in a card instead of pasting it into nothing. Click the copy icon beside the text, and press Esc or click the X to dismiss the card.
- **The menu bar icon** has **Settings…**, **Open History**, **Copy Last Dictation**, and **Launch at Login**.

## Update

```sh
logos update
```

This builds and installs the newest release, then restarts the app. Logos checks for releases at most once a day. When one is out, the menu bar menu shows **Update to vX.Y.Z…**, which does the same thing. `logos update --check` only reports whether there is one.

## Troubleshooting

- **Nothing happens when you hold the hotkey.** Check that **Logos** is on in System Settings → Privacy & Security → Accessibility. If it is, turn it off and on again.
- **The text lands on the clipboard instead of in the app.** The same Accessibility permission is missing.
- **Another app opens when you double-tap Option**, such as the Claude desktop app's Quick Entry. That app is listening for the same key. Turn off or change its shortcut, or choose another Logos hotkey.
- **"No speech detected" on every dictation.** Logos is recording from a device with no microphone attached. Choose **Built-in microphone (recommended)** from the **Microphone** menu in **Settings… → Config**.
- **"No speech detected" when you spoke softly.** Your recording was quieter than `silenceThresholdDB`, so Logos didn't transcribe it. Each line of `history.jsonl` gives the dictation's `peakDB`, the level of its loudest 50 milliseconds. Speak closer to the microphone, or set `silenceThresholdDB` below the `peakDB` of your soft speech, such as `-55`.
- **"The microphone didn't respond."** The audio system was busy, usually because a display or an audio interface was connecting. Dictate again.
- **"Cleanup failed, pasted raw text."** The message names the cause, usually a missing or mistyped API key. Check the key under **API keys** in **Settings… → Config**.
- **A card appears where you expected a paste.** Logos didn't recognize that app's text field. Add the app's bundle ID to `alwaysPasteApps` in `config.json`. `osascript -e 'id of app "Ghostty"'` prints an app's bundle ID.
- **macOS asks for permissions again after an update.** macOS keeps them only while every build is signed by the same certificate. The build uses your Apple Development or Developer ID certificate when you have one. Otherwise it creates a "Logos Local Signing" certificate once, in its own keychain in `~/Library/Application Support/Logos`, and reuses it. Set `CODESIGN_IDENTITY` to pick a certificate yourself.

## Configuration reference

Logos keeps its files in `~/.config/logos/` and rereads each one when it changes:

- **`config.json`** holds settings and API keys, readable only by you. The **Config** tab writes only the setting you change, so settings you add by hand are kept.
- **`prompt.md`** is the cleanup prompt.
- **`dictionary.txt`** is your dictionary.
- **`history.jsonl`** logs each dictation's raw and cleaned text, models, timings, and loudness.
- **`context.d/`** holds files other apps write to tell Logos what to listen for.

Models are named `provider/model`, and each provider's key goes under `keys`. You can leave out any setting you don't change:

```json
{
  "transcription": { "model": "groq/whisper-large-v3-turbo", "locale": "en-US" },
  "cleanup": { "model": "anthropic/claude-haiku-5-5", "effort": "low" },
  "keys": { "anthropic": "sk-ant-...", "groq": "gsk_..." }
}
```

A key you leave empty falls back to the `<PROVIDER>_API_KEY` environment variable, such as `ANTHROPIC_API_KEY`, but apps opened from Finder don't see your shell's environment.

| Setting | Default | What it does |
| --- | --- | --- |
| `hotkey` | `option` | The key to hold. A modifier alone, either side or one side (`option`, `rightOption`, `leftCommand`, `fn`), or any key with optional modifiers (`f13`, `ctrl+space`, `cmd+shift+d`). |
| `minHoldSeconds` | `0.3` | The shortest hold that counts as a dictation. |
| `silenceThresholdDB` | `-45` | The level below which a recording counts as silence, in decibels below the loudest sound a recording can hold (dBFS). Logos measures the recording's loudest 50 milliseconds. Below this level, the recording goes to no model and nothing is pasted. Speech usually measures between -30 and -10, and a quiet room between -60 and -50. `-100` sends every recording. |
| `inputDevice` | `builtIn` | The microphone: `builtIn`, `system` for macOS's default input, or a device's UID from the **Microphone** menu. |
| `transcription.model` | `apple` | The speech model. |
| `transcription.locale` | `en-US` | The language you speak. |
| `transcription.prompt` | empty | A hint for server speech models, sent before your dictionary's words. |
| `cleanup.enabled` | `true` | Clean up transcripts, or paste them raw. |
| `cleanup.model` | `anthropic/claude-opus-5-5` | The cleanup model. |
| `cleanup.effort` | `low` | Anthropic models' effort level. Empty uses the model's default. |
| `cleanup.maxTokens` | `4096` | The longest reply from Anthropic models. |
| `cleanup.extraBody` | empty | Merged into the cleanup request last, to set any API parameter, such as `{"temperature": 0}`. |
| `providers` | empty | Extra providers, described below. |
| `trailingSpace` | `true` | Add a space after each paste so dictations don't run together. |
| `restoreClipboard` | `true` | Put your previous clipboard back after pasting. |
| `showWhenNoTextField` | `true` | Show a card to copy from when nothing focused takes text. |
| `alwaysPasteApps` | empty | Bundle IDs of apps that always get a paste. |
| `readCursorContext` | `true` | Send the text around the cursor, the field's placeholder, the window title, and a browser's page URL to the cleanup model. Password fields are never read, and speech models never see any of it. |
| `useContacts` | `false` | Match each transcript against your contacts, and send the names of the people it mentions to the cleanup model. Never their email addresses. |
| `includeMyEmails` | `false` | When a dictation mentions mail or an address, send your own addresses to the cleanup model: those on your card in Contacts, with `useContacts`, and `myEmails`. |
| `myEmails` | `[]` | More email addresses of yours, sent with `includeMyEmails`. |
| `saveHistory` | `true` | Keep `history.jsonl`. |

To add a provider, give it a name, an API style, and a base URL. `api` is `anthropic` for the Anthropic Messages API, or `openai` for anything OpenAI-compatible:

```json
{
  "providers": { "lmstudio": { "api": "openai", "baseURL": "http://localhost:1234/v1" } },
  "cleanup": { "model": "lmstudio/qwen3-8b" }
}
```

## Prompt reference

`prompt.md` is the system prompt, and the transcript follows as the user message inside `<transcript>` tags. Logos fills in these placeholders, in one pass, so text from a field or an app is never read as a placeholder:

| Placeholder | Becomes |
| --- | --- |
| `{{app}}` | The name of the app you're dictating into, so the prompt can say, for example, to keep commands exact in a terminal. |
| `{{dictionary}}` | Your dictionary as a bulleted list, notes included, or `(none)`. Leave it out and the cleanup model doesn't see your dictionary. |
| `{{context}}` | The text around the cursor, hints from other apps, and, when their settings are on, the names of contacts the transcript mentions and your own email addresses, or `(none)`. Leave it out and none of them reach the cleanup model. The default prompt tells the model to use it only as context and never to repeat it. |
| `{{transcript}}` | The transcript. When the prompt contains it, Logos sends the whole prompt as the user message, with no system prompt. |

## Context from other apps

Apps and tools can tell Logos what to listen for by writing JSON files to `~/.config/logos/context.d/`. At every dictation, Logos reads each file that applies, adds its words to your dictionary, and gives its prompt to the cleanup model in `{{context}}`. Nothing needs to be running or registered: write the file, and update or delete it when the context changes.

```json
{
  "apps": ["com.mitchellh.ghostty", "com.googlecode.iterm2"],
  "words": ["fix-pr", "review-repo", "logos: \"Logos\" for the app, \"logos\" for the command"],
  "prompt": "The user is talking to a coding agent about pull requests.",
  "expires": "2026-11-28T00:00:00Z"
}
```

Every field is optional:

- **`apps`** lists the bundle IDs of the apps the file applies to. Without it, the file applies to every app. A tool that runs in a terminal should list terminal apps, since the terminal is the app in front.
- **`words`** uses the same format as dictionary lines, notes included. Your own dictionary wins when both list a word.
- **`prompt`** is a hint for the cleanup model, labeled with the file's name, such as `From projector:`. Logos uses the first 2,000 characters.
- **`expires`** is an ISO 8601 time after which Logos ignores the file, so context from a closed session doesn't linger.

Name the file after your tool, such as `projector.json`, and write it atomically: write a temporary file, then rename it. Logos skips files that aren't valid JSON.

## The logos command

`logos` is the app's own binary, so it's always the same version as the app. `logos help` lists its commands:

- **`logos transcribe <file>`** runs an audio file through transcription and cleanup and prints the result. Add `--no-cleanup` to stop after transcription, and `--app <name>` to fill in `{{app}}`. Set `LOGOS_CONFIG_DIR` to use a config folder other than `~/.config/logos`.
- **`logos update`** builds and installs the newest release. `--check` only reports whether one is out.
- **`logos version`** prints the installed version.

Set `LOGOS_OFFLINE` to any value to stop the daily check for a new release. With it set, the waveform menu shows no **Update to** item, and `logos transcribe` never warns that a newer release is out. It doesn't affect `logos update`, which always asks GitHub for the newest release.

The app sees `LOGOS_OFFLINE` only when launchd passes it on, because an app that Finder or `open` starts doesn't get your shell's environment. Set it for launchd, then quit and reopen Logos:

```sh
launchctl setenv LOGOS_OFFLINE 1
```

The setting lasts until you log out. A shell variable, such as one set in `~/.zshrc`, reaches only the `logos` command.

## Develop

Clone this repository and run the tests with `swift test`. `./scripts/build.sh` builds `build/Logos.app` without installing it, and `./install.sh` builds and installs your checkout. `./scripts/artwork.sh` redraws the app icon and the site's images from the glyph in `Sources/Logos/Glyph.swift`.

## Release

The version lives in one place: `CFBundleShortVersionString` in `Resources/Info.plist`. A release is a tag, `vX.Y.Z`, with no built files, because each Mac builds the source itself.

1. Run the **Release** workflow from `main` under Actions, choosing patch, minor, or major. It opens a "Release X.Y.Z" pull request that bumps the version.
2. Merge that pull request. The workflow tags `vX.Y.Z` and publishes a GitHub release with generated notes, and `logos update` installs it everywhere.

The workflow needs **Allow GitHub Actions to create and approve pull requests** turned on under Settings → Actions → General.

## License

Logos is open source under the [MIT License](LICENSE).
