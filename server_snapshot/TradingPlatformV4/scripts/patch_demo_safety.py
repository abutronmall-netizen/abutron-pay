from pathlib import Path

root = Path(r"C:\Abutron\TradingPlatformV4")

settings_path = root / "mt5_bridge" / "settings.py"
app_path = root / "mt5_bridge" / "app.py"
env_path = root / ".env"

# ------------------------------------------------------------
# 1. settings.py -- add demo-only execution protection
# ------------------------------------------------------------

s = settings_path.read_text(encoding="utf-8")

if "demo_only:bool=True" not in s:
    needle = '    live_trading:bool=False\n'

    if needle not in s:
        raise SystemExit(
            "PATCH ABORTED: settings live_trading field not found"
        )

    s = s.replace(
        needle,
        needle + '    demo_only:bool=True\n',
        1
    )

settings_path.write_text(s, encoding="utf-8")

# ------------------------------------------------------------
# 2. app.py -- centralized demo/account ownership guards
# ------------------------------------------------------------

a = app_path.read_text(encoding="utf-8")

if "def _require_demo_if_configured():" not in a:
    needle = '''def ready():
    if mt5 is None: raise HTTPException(503,"MetaTrader5 package unavailable")
    if not mt5.initialize(): raise HTTPException(503,f"MT5 initialize failed: {mt5.last_error()}")
'''

    insert = needle + '''

def _require_demo_if_configured():
    ready()
    account=mt5.account_info()

    if account is None:
        raise HTTPException(503,"MT5 account unavailable")

    server=str(getattr(account,"server","") or "")

    if settings.demo_only and "DEMO" not in server.upper():
        raise HTTPException(
            403,
            f"MT5_DEMO_ONLY blocked execution on server: {server or 'UNKNOWN'}"
        )

    return account


def _is_abutron_position(position):
    magic=int(getattr(position,"magic",0) or 0)
    comment=str(getattr(position,"comment","") or "").upper()

    return (
        magic==settings.magic
        or comment.startswith("ABUTRON")
    )
'''

    if needle not in a:
        raise SystemExit(
            "PATCH ABORTED: ready() block not found"
        )

    a = a.replace(needle, insert, 1)

# ------------------------------------------------------------
# 3. Order endpoint -- require demo account before order_send
# ------------------------------------------------------------

old = '''    if not settings.live_trading:
        out={"accepted":False,"mode":"DRY_RUN","reason":"MT5_LIVE_TRADING_FALSE","plan":plan.model_dump(mode="json")}
        store.put(plan.idempotency_key,out); return out
    rs,desired_buy,request,info=_build_order_request(plan)
'''

new = '''    if not settings.live_trading:
        out={"accepted":False,"mode":"DRY_RUN","reason":"MT5_LIVE_TRADING_FALSE","plan":plan.model_dump(mode="json")}
        store.put(plan.idempotency_key,out); return out

    _require_demo_if_configured()

    rs,desired_buy,request,info=_build_order_request(plan)
'''

if old in a:
    a = a.replace(old, new, 1)
elif "_require_demo_if_configured()\n\n    rs,desired_buy" not in a:
    raise SystemExit(
        "PATCH ABORTED: /v1/order execution block did not match"
    )

# ------------------------------------------------------------
# 4. Management endpoint -- demo guard + ownership helper
# ------------------------------------------------------------

old = '''    if not settings.management_enabled:
        return {"managed":False,"reason":"MT5_MANAGEMENT_ENABLED_FALSE","actions":[]}
    actions=[]
'''

new = '''    if not settings.management_enabled:
        return {"managed":False,"reason":"MT5_MANAGEMENT_ENABLED_FALSE","actions":[]}

    _require_demo_if_configured()

    actions=[]
'''

if old in a:
    a = a.replace(old, new, 1)

old_filter = '''        if int(getattr(p,"magic",0))!=settings.magic and not str(getattr(p,"comment","")).upper().startswith("ABUTRON"):
            continue
'''

new_filter = '''        if not _is_abutron_position(p):
            continue
'''

if old_filter in a:
    a = a.replace(old_filter, new_filter, 1)

# ------------------------------------------------------------
# 5. Close endpoint -- demo guard + ownership enforcement
# ------------------------------------------------------------

old = '''    if not settings.live_trading: return {"closed":False,"reason":"MT5_LIVE_TRADING_FALSE","ticket":ticket}
    rows=mt5.positions_get(ticket=ticket) or []
'''

new = '''    if not settings.live_trading:
        return {"closed":False,"reason":"MT5_LIVE_TRADING_FALSE","ticket":ticket}

    _require_demo_if_configured()

    rows=mt5.positions_get(ticket=ticket) or []
'''

if old in a:
    a = a.replace(old, new, 1)

old = '''    p=rows[0]; tick=mt5.symbol_info_tick(p.symbol)
'''

new = '''    p=rows[0]

    if not _is_abutron_position(p):
        raise HTTPException(
            403,
            "Refusing to close position not owned by Abutron"
        )

    tick=mt5.symbol_info_tick(p.symbol)
'''

if old in a:
    a = a.replace(old, new, 1)

app_path.write_text(a, encoding="utf-8")

# ------------------------------------------------------------
# 6. .env -- enforce DEMO ONLY by default
# ------------------------------------------------------------

e = env_path.read_text(encoding="utf-8")

lines = e.splitlines()

found = False
out = []

for line in lines:
    if line.startswith("MT5_DEMO_ONLY="):
        out.append("MT5_DEMO_ONLY=true")
        found = True
    else:
        out.append(line)

if not found:
    out.append("MT5_DEMO_ONLY=true")

env_path.write_text(
    "\n".join(out) + "\n",
    encoding="utf-8"
)

print("DEMO SAFETY PATCH: APPLIED")
print("MT5_DEMO_ONLY=true")