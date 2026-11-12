# Environment Baseline — Shipment Events Service

> Captured: 2026-11-12 (Phase 0).
> Rule: record exactly what each command returned. For missing tools, paste the original error message — never write "available" or "install later."

---

## Required runtimes

| Tool | Version / Status |
|------|------------------|
| `ruby` | **Not found.** The term 'ruby' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. |
| `bundle` | **Not found.** The term 'bundle' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. |
| `docker` | Docker version 29.9.3, build 5457199 |
| `docker compose` | Docker Compose version v5.7.0 |
| `psql` | **Not found.** The term 'psql' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. |

## Auxiliary tooling

| Tool | Version / Status |
|------|------------------|
| `python` | **Not found.** The program 'python.exe' cannot run: the system cannot access the file. |
| `node` | v20.17.0 |
| `git` | git version 2.56.0.windows.4 |
| `rails` | **Not found.** The term 'rails' is not recognized as the name of a cmdlet, function, script file, or operable program. |
| `rg` | Available (bundled with VS Code extension at `c:\Users\Admin\.vscode\extensions\openai.chatgpt-*\bin\windows-x86_64\rg.exe`) |

---

## Platform

| Item | Value |
|------|-------|
| OS | Windows |
| Shell | PowerShell |
| Architecture | x86_64 |
| Workspace | `E:\transvisual2026` |

---

## Notes

- **Ruby toolchain is entirely absent.** The project will run via Docker (official Ruby image) or the reviewer must install Ruby locally. A local Ruby install is not assumed.
- **`psql` is absent** but PostgreSQL will be provided via Docker Compose. All `psql` commands in verification scripts will be executed inside the container (`docker compose exec db psql`).
- **`python` is installed but inaccessible** from the current shell session. Python is not required for this project.
