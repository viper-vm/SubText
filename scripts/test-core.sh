#!/bin/zsh
# Compiles the app's core logic (lyrics parsing, title cleaning, Claude reply parsing,
# language detection and romanization) for macOS and runs the checks in Tests/CoreTests.
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)/coretests"
xcrun --sdk macosx swiftc -o "$out" \
  Subtext/Models/Models.swift \
  Subtext/Lyrics/LRCParser.swift \
  Subtext/Lyrics/LyricsService.swift \
  Subtext/Translate/ClaudeAPI.swift \
  Subtext/Translate/ClaudeTranslator.swift \
  Subtext/Translate/LinePrompt.swift \
  Subtext/Translate/LanguageTools.swift \
  Subtext/Storage/Prefs.swift \
  Subtext/Storage/Keychain.swift \
  Tests/CoreTests/main.swift
"$out"
