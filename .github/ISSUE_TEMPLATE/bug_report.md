---
name: Bug report
about: Something in Remarc is broken
title: ''
labels: bug
assignees: ''
---

**macOS version**


**Remarc version** (menu bar icon -> About, or Preferences -> About)


**Steps to reproduce**

1.
2.
3.

**Expected behavior**


**Actual behavior**


**Logs**

Release builds write no debug log by default. If you can, enable logging, relaunch Remarc, reproduce the issue, and attach the tail of the log:

```
defaults write com.metepolat.Remarc debugFileLoggingEnabled -bool YES
# relaunch Remarc, reproduce the issue, then:
tail -100 ~/Library/Logs/Remarc/remarc_debug.log
```

While enabled, the log can include fragments of selected text and dictation transcripts. Scrub anything you consider private before posting. If the issue involves restarting Remarc, the previous launch's log is kept at `remarc_debug.log.old`. Afterwards, turn logging back off with `-bool NO`; Remarc deletes the files on its next launch.

(If you built the app yourself in Debug configuration, the log is always at `/tmp/remarc_debug.log`.)
