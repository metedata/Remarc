---
name: merge
description: Merge a worktree feature branch into main with build verification and cleanup
user_invocable: true
---

## Merge Worktree Branch to Main

1. Run `git worktree list` to identify the active worktree and its branch
2. Build in the worktree to confirm it compiles cleanly:
   ```
   cd <worktree>/app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"
   ```
3. From the main repo root, merge:
   ```
   git merge --no-ff <branch>
   ```
4. Rebuild on main to verify the merge:
   ```
   cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"
   ```
5. Relaunch: `pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app`
6. Clean up the worktree and branch:
   ```
   git worktree remove .worktrees/<name>
   git branch -d <branch>
   ```
7. Ask the user if they want to push to origin. Do NOT push without confirmation.
