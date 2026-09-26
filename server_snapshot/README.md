# Abutron Step 23Q — Quantitative Mathematics Engine v1.0.0

**Release mode:** SHADOW only.

Installation:
1. Extract this package to `C:\Abutron\Step23Q-Package`.
2. Open Administrator PowerShell.
3. `Set-ExecutionPolicy -Scope Process Bypass`
4. `Set-Location C:\Abutron\Step23Q-Package`
5. `.\scripts\install_step23q.ps1`
6. Restart the Abutron API using the existing platform restart/start procedure.
7. `.\scripts\certify_step23q.ps1`

Step 23Q v1.0.0 does not implement GATE mode. Unknown mode values fall back to SHADOW.
