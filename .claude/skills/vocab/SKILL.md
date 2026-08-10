---
name: vocab
description: >
  Add or remove words from the speech recognition vocabulary hints.
  Use when the user wants to add a word to the dictionary or fix
  a speech recognition misrecognition.
argument-hint: <word or phrase to add>
---

## Manage Vocabulary Hints

Words to add/remove: **$ARGUMENTS**

### Steps

1. Read `app/RemarcPackage/Sources/RemarcFeature/Services/VocabularyHints.swift`
2. Check if the word/phrase is already in the `words` array
3. Add or remove the entry as requested
4. Confirm the change to the user
