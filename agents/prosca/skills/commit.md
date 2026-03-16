---
name: commit
description: Create a well-structured git commit with a clear message
---

When asked to commit changes, follow these steps:

1. Use run_command to check `git status` and `git diff --staged`
2. Review what changed and why
3. Write a concise commit message: imperative mood, <72 chars subject
4. Use run_command to stage and commit
5. Report what was committed
