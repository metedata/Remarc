---
title: Transcription engines & models
description: Compare Apple Speech, WhisperKit, and Parakeet, the three on-device engines behind Remarc's voice features, and manage their models.
---

All voice features - [dictation](/voice/dictation/) and [voice comments and Crit Mode](/voice/voice-comments-and-crit-mode/) - share one transcription engine, chosen with the **Engine** picker in Settings > Voice. Everything is transcribed locally on your Mac; no audio or text ever leaves it.

:::note
All voice features require macOS 26 (Tahoe) or later.
:::

## Engines

The **Engine** picker offers three on-device engines:

| Engine | Download | Notes |
| --- | --- | --- |
| Apple Speech | None | Built-in macOS transcription. Good accuracy, works immediately. |
| WhisperKit | 75 MB - 954 MB | OpenAI Whisper via CoreML. High accuracy, multiple model sizes. |
| Parakeet | ~1.2 GB | NVIDIA Parakeet via CoreML. Fastest inference, excellent accuracy. |

### WhisperKit models

WhisperKit offers three model sizes; larger models are more accurate but use more memory.

| Model | Download size |
| --- | --- |
| Fast | 75 MB |
| Balanced | 217 MB |
| Max | 954 MB |

### Parakeet models

Parakeet comes in two versions, **English** and **Multilingual**, each about 1.2 GB.

## Download models

WhisperKit and Parakeet models download inside Settings > Voice: click **Download** next to the model, watch the progress percentage, and use **Cancel** to abort or **Delete** to remove a downloaded model later. If a download fails, a Retry button appears.

Voice features keep working while a model downloads: Remarc falls back to Apple Speech until the model is ready. If you switch WhisperKit model sizes, transcription falls back to the previous model while it is still loaded, or to Apple Speech, until the new one finishes.

## Memory options

Two toggles appear in Settings > Voice when WhisperKit or Parakeet is selected:

- **Keep model in memory** prevents the model from being unloaded after use. Responses come faster, at the cost of roughly 200-500 MB of RAM depending on the model. Recommended if you have 16 GB or more of RAM.
- **Load model on launch** loads the model into memory when Remarc starts so dictation is instant on first use. Available only when keep-in-memory is on.
