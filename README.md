# Squirrel Voice

Lightweight native macOS speech-to-text runtime for Squirrel/Rime, using
NetEase Youdao **Confucius4-R2T2** GGUF weights and `llama.cpp`/Metal.

The distributable input method is an independent product named **Squirrel Voice**
with bundle/input-source ID `im.rime.inputmethod.SquirrelVoice`. It installs at
`/Library/Input Methods/Squirrel Voice.app` and does not replace the official
`Squirrel.app`. It deliberately keeps using `~/Library/Rime` so existing Rime
schemas and user configuration can be reused.

The design intentionally has no Python, Ollama, LM Studio service, browser,
HTTP server, or cloud dependency. LM Studio is only one optional place where
the GGUF files may already exist.

## Current milestone

This first native milestone provides:

- pinned `llama.cpp` source (`ad6c66839af3c5646fba8c6c2e2087a1e4e38948`), matching the upstream R2T2 llama backend;
- in-process GGUF + `mmproj` loading with Metal;
- R2T2-style 160 ms streaming with rollback and append-only stable deltas;
- direct WAV testing;
- direct macOS default-microphone capture through AudioQueue;
- persistent `--stdio` helper mode for a tiny Squirrel bridge (model loads once);
- a compact non-activating voice HUD beside the current input caret;
- a static SF Symbol plus five discrete microphone-level bars (no continuous animation loop);
- a clickable `xmark.circle` cancel control that uses the same hard-stop path;
- a compact `cpu` SF Symbol in the HUD that opens model settings without showing a model name;
- Squirrel menu entries for start/stop voice input, the active voice model, and voice settings;
- a native AppKit model settings window that scans the default LM Studio model directory,
  Squirrel Voice's own model directory, and one user-selected custom directory;
- persistent model selection; the selected GGUF + mmproj paths are passed directly to
  the bundled helper on the next voice session;
- hard stop semantics that discard queued audio and never emit stale text after stop;
- automatic stop when Squirrel's input session is deactivated or its text client becomes invalid;
- automatic reuse of an existing LM Studio model directory, without starting LM Studio.
- a reproducible Squirrel 1.1.2 patch that binds **Command+Shift+Space** to the
  helper and commits stable deltas through Squirrel's existing `IMKTextInput`
  `insertText` path.

## Models

By default the runtime checks:

1. `R2T2_MODEL_DIR`
2. `~/.lmstudio/models/netease-youdao/Confucius4-R2T2-GGUF`
3. `~/Library/Application Support/Squirrel Voice/Models`
4. `~/Models/Confucius4-R2T2-GGUF`

You can also pass `--model-dir`, or explicit `--model` + `--mmproj` paths.

When more than one official checkpoint exists in the same directory, the
runtime prefers `Q4_K_M` over `Q8_0` over `f16` for the language model, and
prefers the `Q8_0` audio projector over `f16`. Explicit `--model` / `--mmproj`
always override this policy. This keeps the input-method helper lightweight on
machines where the quantized files have been downloaded.

### Model settings

Open **Voice Input Settings…** from the Squirrel menu, or click the current
model name in the voice HUD. The window shows the current model, scans
`~/.lmstudio/models`, lets the user add a custom model directory, and lists
compatible local model/model-projector pairs with their variant, source and
combined size. Selecting **Use Selected Model** updates the saved model paths;
LM Studio itself never needs to be running.

The default family is NetEase Youdao **Confucius4-R2T2-GGUF**. If no explicit
selection has been saved, Squirrel Voice auto-discovers that family under the
standard LM Studio path and prefers `Q4_K_M`, then `Q8_0`, then `F16` when those
variants are present. The recommended model page is:

`https://huggingface.co/netease-youdao/Confucius4-R2T2-GGUF`

The settings model record already includes an `engine` field. v0.1 only marks
the R2T2/llama.cpp path as automatically compatible because that is the engine
validated by this project. Additional speech engines can be added later
without redesigning the HUD or settings window.

Squirrel Voice deliberately does not add a language-correction, terminology,
prompting, punctuation-rewrite, or second-pass LLM layer. The runtime stays a
small local speech-to-text path: microphone -> ASR model -> stable text ->
Squirrel.

## Build

```bash
./build.sh
```

The bootstrap script fetches only the pinned llama.cpp source needed for a
reproducible build. Model weights are never copied into this repository.

## Smoke test

Load the model only:

```bash
./build/squirrel-voice --probe
```

Transcribe a WAV file:

```bash
./build/squirrel-voice --wav /path/to/test.wav --language Chinese
```

Use the default microphone:

```bash
./build/squirrel-voice --mic --language Chinese
```

Persistent helper protocol (intended for Squirrel):

```bash
./build/squirrel-voice --stdio
# helper prints READY after the model is resident
# stdin commands: START, STOP, PING, QUIT
# stdout events: READY, STARTED, L<TAB>mic-level,
#                D<TAB>stable-delta, STOPPED, ERROR<TAB>message
```

When Squirrel uses the helper, the model stays resident across short dictation
bursts and the helper exits after 5 minutes of idle time to release memory.
Set `SQUIRREL_VOICE_IDLE_SECONDS` to override that timeout for development.

`STOP` is deliberately immediate. Once it is received, microphone capture is
stopped, pending audio is discarded, and no additional recognition delta is
allowed to reach Squirrel. This prevents delayed text from appearing after the
user has already stopped dictation or moved away from the input field.

Dictation does not stop just because the user pauses or stays silent. Normal
stop is user-controlled via `Command+Shift+Space` or the HUD cancel button.
Squirrel still stops capture when the active input session/client disappears,
so microphone capture cannot continue after leaving the input context.

The HUD is deliberately low-cost: it uses a plain rounded `CALayer` instead of
continuous blur/animation, quantizes microphone level into five visual bands,
and redraws at most about 8 times per second. The SF Symbol itself is static.

## Build the patched Squirrel app

The integration is kept as `patches/squirrel-1.1.2.patch`; the upstream
Squirrel tree is not vendored into this repository.

```bash
./scripts/build-squirrel.sh
```

This prepares a clean Squirrel 1.1.2 source tree under `build/Squirrel-src`,
applies the patch, reuses the already-installed Squirrel 1.1.2 native
dependencies when available, builds the Swift/InputMethodKit frontend, copies
the 7–8 MB native voice helper into
`Squirrel.app/Contents/Helpers`, and locally signs the resulting development
app. Model files remain external and are not copied into the input method.

Set `SQUIRREL_REBUILD_DEPS=1` only when you explicitly want to rebuild the
entire upstream librime/Sparkle dependency graph from source.

For a local installation (after reviewing the build), run:

```bash
./scripts/install-local.sh
```

The installer validates the built bundle first, then uses the native macOS
administrator-authentication dialog to replace `/Library/Input Methods/Squirrel.app`
with `ditto`. It backs up the previous app, verifies the installed signature and
helper, registers the bundle with LaunchServices, and restarts Squirrel. The
installer never reads or handles the administrator password itself.

## Release and Homebrew

The release version is stored in `VERSION`. A production release uses the
available Developer ID Application/Installer certificates and Apple
notarization credentials:

```bash
./scripts/release-local.sh
```

This builds and Developer-ID-signs `Squirrel Voice.app`, notarizes and staples
the app, creates a stapled ZIP, and then attempts to build a signed installer
package. Model weights are not included in any release artifact.

The Developer ID Application identity and Apple notarization profile are enough
to produce a distributable, Gatekeeper-accepted ZIP. A publishable PKG also
requires a **Developer ID Installer** identity with its private key available in
the current keychain. If that installer identity is unavailable,
`release-local.sh` creates an **unsigned PKG for local testing only** and skips
PKG notarization. Do not publish that unsigned package.

The signed + notarized ZIP is the canonical Homebrew artifact. Homebrew's
`input_method` cask stanza installs `Squirrel Voice.app` into the current
user's `~/Library/Input Methods`, so Homebrew does not require a Developer ID
Installer certificate or a PKG. A signed PKG can still be produced as an
optional system-wide installer when an Installer identity is available.

After a ZIP release is published, generate a cask from
`homebrew/Casks/squirrel-voice.rb.in` with:

```bash
SQUIRREL_VOICE_RELEASE_BASE_URL=https://github.com/iihciyekub/squirrel-voice/releases/download \
SQUIRREL_VOICE_HOMEPAGE=https://github.com/iihciyekub/squirrel-voice \
./scripts/render-cask.sh
```

Users can then install from a tap with `brew install --cask squirrel-voice`.

### GitHub Actions release secrets

The `Release` workflow uses the `production-release` Environment. A signed and
notarized ZIP requires these Environment secrets:

- `MAC_CSC_P12_BASE64`
- `MAC_CSC_KEY_PASSWORD`
- `APPLE_API_KEY_P8_BASE64`
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER`

and the Environment variable `MAC_CSC_NAME` (currently
`Yongjian Li (2NLAH5MYH8)`).

For a signed/notarized PKG and generated Homebrew Cask, add the optional
installer identity separately:

- `MAC_INSTALLER_P12_BASE64`
- `MAC_INSTALLER_P12_PASSWORD`

If the Installer identity is absent, the workflow still publishes the
Developer-ID-signed and Apple-notarized ZIP and simply skips PKG/Cask output.

Only newly stable text is printed to stdout. Diagnostics go to stderr, which
keeps stdout suitable for the upcoming Squirrel IPC bridge.

## Attribution

The native llama.cpp/mtmd inference path is adapted from NetEase Youdao's
Apache-2.0 `Confucius4-R2T2/r2t2_llama/native_ext.cpp`. Model weights remain
subject to the NetEase Model Use License Agreement and are not redistributed
by this project.
