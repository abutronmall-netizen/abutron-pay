from pathlib import Path

ROOT = Path(r"C:\Abutron\TradingPlatformV4")

settings_path = ROOT / "mt5_bridge" / "settings.py"
app_path = ROOT / "mt5_bridge" / "app.py"
env_path = ROOT / ".env"

# ============================================================
# SETTINGS
# ============================================================

src = settings_path.read_text(encoding="utf-8")

if "expected_login:" not in src:
    needle = '''    demo_only:bool=True
'''

    replacement = '''    demo_only:bool=True
    expected_login:int|None=None
    expected_server:str|None=None
'''

    if needle not in src:
        raise SystemExit(
            "PATCH ABORTED: demo_only setting not found"
        )

    src = src.replace(
        needle,
        replacement,
        1
    )

settings_path.write_text(
    src,
    encoding="utf-8"
)

# ============================================================
# EXACT MT5 ACCOUNT GUARD
# ============================================================

src = app_path.read_text(encoding="utf-8")

start_marker = "def _require_demo_if_configured():"
end_marker = "def _is_abutron_position(position):"

start = src.find(start_marker)
end = src.find(end_marker)

if start < 0 or end < 0 or end <= start:
    raise SystemExit(
        "PATCH ABORTED: account guard boundaries not found"
    )

new_guard = '''def _require_demo_if_configured():
    """
    Fail closed unless the connected MT5 terminal satisfies every
    configured execution identity requirement.

    This guard protects all broker-mutating endpoints that call it:
    order, manage and close.
    """
    ready()

    account=mt5.account_info()

    if account is None:
        raise HTTPException(
            503,
            "MT5 account unavailable"
        )

    server=str(
        getattr(
            account,
            "server",
            ""
        )
        or ""
    )

    login=int(
        getattr(
            account,
            "login",
            0
        )
        or 0
    )

    # --------------------------------------------------------
    # DEMO-ONLY SAFETY
    # --------------------------------------------------------

    if (
        settings.demo_only
        and "DEMO" not in server.upper()
    ):
        raise HTTPException(
            403,
            detail={
                "error":"MT5_DEMO_ONLY_BLOCK",
                "server":server
            }
        )

    # --------------------------------------------------------
    # EXACT ACCOUNT LOCK
    # --------------------------------------------------------

    if (
        settings.expected_login
        is not None
        and login
        != int(settings.expected_login)
    ):
        raise HTTPException(
            403,
            detail={
                "error":
                    "MT5_EXPECTED_LOGIN_MISMATCH",

                "connected_login":
                    login
            }
        )

    # --------------------------------------------------------
    # EXACT SERVER LOCK
    # --------------------------------------------------------

    if (
        settings.expected_server
        is not None
        and server.strip()
        != str(
            settings.expected_server
        ).strip()
    ):
        raise HTTPException(
            403,
            detail={
                "error":
                    "MT5_EXPECTED_SERVER_MISMATCH",

                "connected_server":
                    server
            }
        )

    return account


'''

src = (
    src[:start]
    + new_guard
    + src[end:]
)

app_path.write_text(
    src,
    encoding="utf-8"
)

# ============================================================
# .ENV
# ============================================================

env = env_path.read_text(
    encoding="utf-8"
)

required = {
    "MT5_EXPECTED_LOGIN":
        "53054439",

    "MT5_EXPECTED_SERVER":
        "ICMarketsSC-Demo",
}

lines = env.splitlines()

seen = set()
out = []

for line in lines:
    stripped = line.strip()

    matched = False

    for key,value in required.items():
        if stripped.startswith(
            key + "="
        ):
            out.append(
                f"{key}={value}"
            )
            seen.add(key)
            matched = True
            break

    if not matched:
        out.append(line)

for key,value in required.items():
    if key not in seen:
        out.append(
            f"{key}={value}"
        )

env_path.write_text(
    "\n".join(out) + "\n",
    encoding="utf-8"
)

print("MT5 ACCOUNT LOCK: APPLIED")
print("Expected login: 53054439")
print("Expected server: ICMarketsSC-Demo")
print("Demo-only guard remains enabled")