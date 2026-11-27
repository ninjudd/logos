# Logos

Logos is a dictation app for the Mac menu bar. Hold Option, speak, and let go: Logos transcribes what you said, has a language model clean it up with a prompt you write, and pastes the result wherever you're typing. You choose the speech model and the language model, and you can see and edit the cleanup prompt.

There is no Logos server. The app calls each provider's API directly from your Mac with your own API keys, which it keeps in a config file on your machine. It has no third-party dependencies, only Apple frameworks.

## Install

Logos needs macOS 26 or later and Apple's free Command Line Tools, which `xcode-select --install` installs. It builds from source on your Mac, so you need no developer account. To install the latest release:

```sh
curl -fsSL https://logosvoice.dev/install.sh | bash
```

From a checkout of this repository, run `./install.sh` instead.

The installer builds Logos, installs `/Applications/Logos.app`, links the `logos` command into `~/.local/bin`, and starts the app. A waveform icon appears in the menu bar. On first launch, macOS asks for two permissions:

- **Microphone**, to record while you hold the key.
- **Accessibility**, to notice the Option key in other apps and to press ⌘V for you. Turn Logos on under System Settings → Privacy & Security → Accessibility. Until you do, Logos copies each dictation to the clipboard instead of pasting it.

macOS keeps these permissions only while each build is signed by the same certificate. The build signs with your Apple Development or Developer ID certificate when you have one. Otherwise it creates a self-signed "Logos Local Signing" certificate once, in its own keychain in `~/Library/Application Support/Logos`, and signs every later build with it. Set `CODESIGN_IDENTITY` to pick a certificate yourself.

While `ninjudd/logos` is private, the installer and `logos update` download with your `gh` login, or with `GH_TOKEN`.

## Update

```sh
logos update
```

This builds and installs the newest release, then restarts the app. `logos update --check` only reports whether there is one. Logos checks GitHub at most once a day, and when a newer release exists, the menu bar menu shows **Update to vX.Y.Z…** and `logos transcribe` prints a warning. Set `LOGOS_OFFLINE` to turn the check off.

## Use it

Hold Option, talk, and release. A small pill at the bottom of the screen shows the frequencies in your voice while you hold the key, with low pitches on the left and high on the right. Each bar jumps up with sound in its range and fades when the sound stops. Then a spinner shows while Logos transcribes and cleans up. Taps shorter than `minHoldSeconds` are ignored. Pressing any other key or clicking while you hold Option cancels the recording, so Option shortcuts and Option-typed characters keep working.

When nothing focused takes text, for example the desktop or a button, Logos shows the dictation in a card instead of pasting it into nothing. Click the copy icon beside the text, or select part of the text. Press Esc or click the X at the top right to dismiss the card. Starting a new dictation also dismisses it. Logos asks macOS's Accessibility API what has keyboard focus, and when the API can't tell, Logos pastes as usual. If an app's text view isn't recognized and you get the card where you expected a paste, add the app's bundle ID to `alwaysPasteApps`. `osascript -e 'id of app "Ghostty"'` prints an app's bundle ID.

The menu bar icon has **Edit Prompt…**, **Edit Config…**, **Open History**, **Copy Last Dictation**, and **Launch at Login**.

## Configure it

Logos keeps three files in `~/.config/logos/`:

- `config.json` holds settings and API keys. Logos creates it on first launch, readable only by you, and rereads it whenever it changes.
- `prompt.md` is the cleanup prompt. Logos rereads it on every dictation.
- `history.jsonl` logs each dictation's raw transcript, cleaned text, models, and timings. Comparing raw and cleaned text here is the quickest way to tune the prompt.

You name each model as `provider/model`, and put each provider's key under `keys`:

```json
{
  "transcription": { "model": "apple", "locale": "en-US" },
  "cleanup": { "model": "anthropic/claude-opus-5-5", "effort": "low" },
  "keys": { "anthropic": "sk-ant-...", "openai": "", "groq": "" }
}
```

You can leave out any setting you don't change. A key you leave empty falls back to the `<PROVIDER>_API_KEY` environment variable, such as `ANTHROPIC_API_KEY`, but apps opened from Finder don't see your shell's environment.

Transcription models:

- `apple` runs on your Mac with Apple's speech model. It needs no key and is the default. The first dictation downloads the model for your `locale`.
- `openai/gpt-4o-transcribe`, `openai/gpt-4o-mini-transcribe`, `groq/whisper-large-v3-turbo`, or any other model behind an OpenAI-compatible `/audio/transcriptions` endpoint. `transcription.prompt` passes those models a vocabulary hint.

Cleanup models:

- `anthropic/<model>`, such as `anthropic/claude-opus-5-5` (the default) or `anthropic/claude-haiku-5-5` for lower latency and cost. `effort` sets the model's effort level (`low` by default), and `maxTokens` caps the reply.
- `openai/<model>`, `groq/<model>`, `openrouter/<vendor>/<model>`, or `ollama/<model>` for a model running locally in Ollama, which needs no key.

Set `cleanup.enabled` to `false` to paste the raw transcript. If cleanup fails, Logos pastes the raw transcript and shows why.

To add a provider, give it a name, an API style, and a base URL. `api` is `anthropic` for the Anthropic Messages API, or `openai` for anything OpenAI-compatible:

```json
{
  "providers": { "lmstudio": { "api": "openai", "baseURL": "http://localhost:1234/v1" } },
  "cleanup": { "model": "lmstudio/qwen3-8b" }
}
```

`cleanup.extraBody` is merged into the request body last, so it can set or override any API parameter, such as `{"temperature": 0}` for a model that accepts it.

Other settings:

- `hotkey` is `option` (either key), `leftOption`, or `rightOption`.
- `minHoldSeconds` is the shortest hold that counts as a dictation (default `0.3`).
- `trailingSpace` adds a space after each paste so dictations don't run together (default `true`).
- `restoreClipboard` puts your previous clipboard back after pasting (default `true`).
- `showWhenNoTextField` shows the dictation in a card to copy from when nothing focused takes text (default `true`). Set it to `false` to always paste.
- `alwaysPasteApps` lists bundle IDs of apps that always get a paste, such as `["com.mitchellh.ghostty"]` (default empty).
- `saveHistory` turns `history.jsonl` on or off (default `true`).

## The prompt

`prompt.md` is sent as the system prompt, and the transcript follows as the user message inside `<transcript>` tags. `{{app}}` in the prompt becomes the name of the app you're dictating into, so the prompt can say, for example, to keep commands exact in a terminal. If the prompt contains `{{transcript}}`, Logos sends the whole prompt as the user message with the transcript in that spot, and no system prompt.

## The logos command

`logos` is the app's own binary, so it's always the same version as the app. `logos help` lists its commands.

`logos transcribe` runs an audio file through the same pipeline as a dictation and prints the result instead of pasting it, which makes prompt and model changes quick to try:

```sh
say -o /tmp/test.wav --data-format=LEI16@16000 "um so I think we should meet at three, no wait, at four"
logos transcribe /tmp/test.wav --app Slack
```

It prints the raw and cleaned text and how long they took. Add `--no-cleanup` to stop after transcription. Set `LOGOS_CONFIG_DIR` to try a config folder other than `~/.config/logos`.

## Develop

Run the tests with `swift test`. `./scripts/build.sh` builds `build/Logos.app` without installing it, and `./install.sh` builds and installs your checkout.

## Release

The version lives in one place: `CFBundleShortVersionString` in `Resources/Info.plist`. A release is a tag, `vX.Y.Z`, with no built files, because each Mac builds the source itself.

1. Run the **Release** workflow from `main` under Actions, choosing patch, minor, or major. It opens a "Release X.Y.Z" pull request that bumps the version.
2. Merge that pull request. The workflow then tags `vX.Y.Z` and publishes a GitHub release with generated notes, and `logos update` installs it everywhere.

The workflow needs **Allow GitHub Actions to create and approve pull requests** turned on under Settings → Actions → General.
