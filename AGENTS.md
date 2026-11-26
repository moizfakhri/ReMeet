# ReMeet Repository Guidelines

This is a **public** repository. Never commit or push personal, school, lab, client, or private environment data.

## Privacy Rules for Contributors & AI Agents
- **Never copy real data from `~/ReMeet/`:** Never put real contact names, email addresses, meeting titles, transcript excerpts, folder names, `.ics` URLs, or Apple Reminders list names into tests, comments, fixtures, UI strings, docs, or commit messages.
- **Use synthetic placeholders only:** Reuse generic fixtures such as `Priya Patel` (`priya@acme.io`), `Tom Chen` (`tom@acme.io`), `Alex Morgan` (`alex@example.edu`), `Product team`, `Projects`, and `Work`.
- **Keep Apple Reminders behavior generic:** Never hardcode personal list names in first-run selection or Settings presets.
- **Snapshots (`--snapshots`):** Always clear temporary sample storage (`rm -rf "${TMPDIR%/}/remeet-sample" /tmp/remeet-sample`) and pass `-defaultRemindersListID "" -defaultRemindersListName "Work"` so local macOS `UserDefaults` do not leak into documentation screenshots.
- **Commit email privacy:** Keep `git config user.email` set to a GitHub noreply address (`*@users.noreply.github.com`).
- **Pre-commit & pre-push checks:** Enable the repository hooks (`git config core.hooksPath .githooks`) and run `scripts/privacy-check.sh --all` before pushing.
