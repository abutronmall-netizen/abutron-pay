# OpenHands Worker
Workspace MUST be C:\Abutron\Kronos-Dev. Production C:\Abutron\Kronos must not be writable/mounted.
No production secrets. Worker creates branches, edits code and runs tests only. It never deploys production.
Prefer ephemeral Docker/VM workspaces.
