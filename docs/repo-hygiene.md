# Repository Hygiene

## Goal

The public repository should look like a professional engineering project: intentional structure, clear naming, tested behavior, focused commits, and no chat residue or tool-specific planning artifacts.

## Public Repo Rules

- Keep public docs product-facing or engineering-facing.
- Do not commit internal planning identifiers, tool names, scratch notes, or planning transcripts.
- Do not commit generated dead code, unused files, commented-out experiments, or one-off scaffolding.
- Do not use chatty comments. Comments should explain risk, intent, or non-obvious Windows behavior.
- Do not add process-narration comments, generated-by headers, tool signatures, or notes about how code was produced.
- Do not add obvious comments for self-explanatory code. Prefer clear names and small functions.
- Do not leave placeholder comments such as `TODO: implement this later` unless there is a tracked issue or launch-plan reference.
- Do not commit local runtime data, logs, machine-specific outputs, or benchmark captures unless they are curated fixtures.
- Keep large third-party archives out of Git unless the release packaging plan explicitly requires them.
- Use neutral ownership language such as `backend owner`, `frontend owner`, `runtime service`, and `UI shell`.
- Keep tool-specific coordination in ignored internal notes only.

## Code Quality Rules

- Small modules with clear responsibilities.
- Structured models instead of loose string parsing where practical.
- Versioned contracts between frontend and backend.
- Tests or validation scripts for every risky backend area.
- Preview/apply/rollback path for dangerous actions.
- Consistent formatting before commits.
- No broad refactors mixed with feature work.

## Commit Hygiene

- One logical change per commit.
- Commit messages should describe product or engineering behavior, not the tool used to create it.
- Before pushing, run a public-surface scan:

```powershell
rg -n -e "Cod[e]x" -e "Cl[a]ude" -e "Chat[G]PT" -e "generated b[y]" -e "AI assist[a]nt" . --glob "!docs/internal/**"
```

Review matches manually. Product-domain matches such as Windows AI/Copilot settings are allowed when they describe app functionality.

## Public Release Checklist

- `README.md` reads like a product repo, not a planning conversation.
- Internal planning files live under `docs/` and are ignored unless deliberately curated for public release.
- Large local archives are ignored or replaced with fetch/package instructions.
- All JSON manifests validate.
- Backend contracts have sample fixtures.
- Dangerous flows have documented safety behavior.
- Screenshots and release notes are curated.
