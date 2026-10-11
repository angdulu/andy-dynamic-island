# Bundled Whisper Runtime

whisper.cpp v1.9.5, commit `d1be6fde11ac6e0407606b4e42fe72d34add8037`.

Built for arm64 macOS 14.6+ with Accelerate and embedded Metal kernels.
The executables and dynamic libraries are rebuilt together; loader paths are
relative to their containing directory. The upstream MIT license is included.

Rebuild from the repository root:

```sh
bash scripts/update-whisper.sh
```

The script verifies the pinned source commit, builds in a temporary directory,
and checks both executables before replacing the bundled runtime. The existing
Silero v5.1.2 VAD model is preserved.
