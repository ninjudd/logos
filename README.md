# Logos

Logos is a dictation app for the Mac menu bar. Hold Option, speak, and let go: Logos transcribes what you said, has a language model clean it up with a prompt you write, and pastes the result wherever you're typing. You choose the speech model and the language model, and you can see and edit the cleanup prompt.

There is no Logos server. The app calls each provider's API directly from your Mac with your own API keys, which it keeps in a config file on your machine. It has no third-party dependencies, only Apple frameworks.

## Install

Logos needs macOS 26 or later and Xcode's command-line tools.

```sh
./scripts/build.sh --install
```

This builds `build/Logos.app`, copies it to `/Applications`, and launches it. A waveform icon appears in the menu bar. On first launch, macOS asks for two permissions:

- **Microphone**, to record while you hold the key.
- **Accessibility**, to notice the Option key in other apps and to press ⌘V for you. Turn Logos on under System Settings → Privacy & Security → Accessibility. Until you do, Logos copies each dictation to the clipboard instead of pasting it.

The build script signs the app with your Apple Development certificate when you have one, so permissions survive rebuilds. Set `CODESIGN_IDENTITY` to pick a different certificate.

## Use it

Hold Option, talk, and release. A small pill at the bottom of the screen shows the frequencies in your voice while you hold the key, with low pitches on the left and high on the right. Each bar jumps up with sound in its range and fades when the sound stops. Then a spinner shows while Logos transcribes and cleans up. Taps shorter than `minHoldSeconds` are ignored. Pressing any other key or clicking while you hold Option cancels the recording, so Option shortcuts and Option-typed characters keep working.

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
- `saveHistory` turns `history.jsonl` on or off (default `true`).

## The prompt

`prompt.md` is sent as the system prompt, and the transcript follows as the user message inside `<transcript>` tags. `{{app}}` in the prompt becomes the name of the app you're dictating into, so the prompt can say, for example, to keep commands exact in a terminal. If the prompt contains `{{transcript}}`, Logos sends the whole prompt as the user message with the transcript in that spot, and no system prompt.

## Try a change without dictating

The app binary can run one audio file through the same pipeline and print the result without pasting anything:

```sh
say -o /tmp/test.wav --data-format=LEI16@16000 "um so I think we should meet at three, no wait, at four"
/Applications/Logos.app/Contents/MacOS/Logos --transcribe /tmp/test.wav --app Slack
```

It prints the raw and cleaned text and how long they took. Add `--no-cleanup` to stop after transcription. Set `LOGOS_CONFIG_DIR` to try a config folder other than `~/.config/logos`.

## Develop

Run the tests with `swift test`. Build the app with `./scripts/build.sh`, which leaves it in `build/Logos.app` without installing it.
