from pathlib import Path

path = Path(
    r"C:\Abutron\TradingPlatformV4\mt5_bridge\app.py"
)

src = path.read_text(encoding="utf-8")

# ------------------------------------------------------------
# Broker clock helper
# ------------------------------------------------------------

if "def _broker_now():" not in src:
    marker = '''def _position_dict(p):
'''

    helper = '''def _broker_now():
    """
    Return a datetime aligned to the broker/MT5 clock.

    Some MT5 brokers expose tick/deal timestamps using a broker
    wall-clock offset relative to the Windows/Python system clock.
    History queries therefore must not rely solely on datetime.now().
    """
    local_now=datetime.now()
    best_ts=0

    try:
        symbols=mt5.symbols_get() or []
        names=[s.name for s in symbols]

        clean=lambda x:"".join(
            ch for ch in x.upper()
            if ch.isalnum()
        )

        preferred=(
            "BTCUSD",
            "EURUSD",
            "GBPUSD",
            "USDJPY",
            "XAUUSD",
            "US100",
            "US30",
            "SP500",
            "GER40",
            "USOIL",
        )

        for canonical in preferred:
            aliases=ALIASES.get(canonical,())

            matched=None

            for alias in aliases:
                a=clean(alias)

                for name in names:
                    n=clean(name)

                    if n==a or n.startswith(a):
                        matched=name
                        break

                if matched:
                    break

            if not matched:
                continue

            try:
                mt5.symbol_select(matched,True)
                tick=mt5.symbol_info_tick(matched)

                ts=int(
                    getattr(tick,"time",0)
                    or 0
                )

                if ts>best_ts:
                    best_ts=ts

            except Exception:
                continue

    except Exception:
        return local_now

    if best_ts<=0:
        return local_now

    offset=float(best_ts)-time.time()

    # Fail closed to local clock if broker offset is implausible.
    if abs(offset) > 36*60*60:
        return local_now

    return local_now+timedelta(
        seconds=offset
    )


'''

    if marker not in src:
        raise SystemExit(
            "PATCH ABORTED: _position_dict marker not found"
        )

    src = src.replace(
        marker,
        helper + marker,
        1,
    )

# ------------------------------------------------------------
# Daily P&L: broker-day clock
# ------------------------------------------------------------

old = '''    now=datetime.now(); start=now.replace(hour=0,minute=0,second=0,microsecond=0)
    deals=mt5.history_deals_get(start,now) or []
'''

new = '''    now=_broker_now()
    start=now.replace(
        hour=0,
        minute=0,
        second=0,
        microsecond=0
    )
    deals=mt5.history_deals_get(
        start,
        now+timedelta(minutes=5)
    ) or []
'''

if old in src:
    src = src.replace(
        old,
        new,
        1,
    )
elif "now=_broker_now()" not in src:
    raise SystemExit(
        "PATCH ABORTED: account history block not found"
    )

# ------------------------------------------------------------
# Replace /v1/history with broker-clock-aware implementation.
#
# Adds optional exact:
#   ?ticket=<deal>
#   ?position=<position>
#
# Existing ?days=N behavior remains backward compatible.
# ------------------------------------------------------------

start_marker = '@app.get("/v1/history")'
end_marker = '@app.get("/v1/context/{symbol}")'

start = src.find(start_marker)
end = src.find(end_marker)

if start < 0 or end < 0 or end <= start:
    raise SystemExit(
        "PATCH ABORTED: history route boundaries not found"
    )

new_history = '''@app.get("/v1/history")
def history(
    days:int=30,
    ticket:int|None=None,
    position:int|None=None,
    authorization:str|None=Header(default=None)
):
    auth(authorization)
    ready()

    if ticket is not None and position is not None:
        raise HTTPException(
            400,
            "Use ticket or position, not both"
        )

    if ticket is not None:
        deals=mt5.history_deals_get(
            ticket=int(ticket)
        ) or []

    elif position is not None:
        deals=mt5.history_deals_get(
            position=int(position)
        ) or []

    else:
        days=max(
            1,
            min(days,365)
        )

        end=_broker_now()+timedelta(
            minutes=5
        )

        start=end-timedelta(
            days=days
        )

        deals=mt5.history_deals_get(
            start,
            end
        ) or []

    out=[]

    for d in deals:
        magic=int(
            getattr(d,"magic",0)
            or 0
        )

        comment=str(
            getattr(d,"comment","")
            or ""
        )

        if (
            magic!=settings.magic
            and not comment.upper().startswith(
                "ABUTRON"
            )
        ):
            continue

        out.append({
            "ticket":
                int(
                    getattr(d,"ticket",0)
                    or 0
                ),

            "order":
                int(
                    getattr(d,"order",0)
                    or 0
                ),

            "position_id":
                int(
                    getattr(d,"position_id",0)
                    or 0
                ),

            "time":
                int(
                    getattr(d,"time",0)
                    or 0
                ),

            "time_msc":
                int(
                    getattr(d,"time_msc",0)
                    or 0
                ),

            "symbol":
                str(
                    getattr(d,"symbol","")
                    or ""
                ),

            "type":
                int(
                    getattr(d,"type",0)
                    or 0
                ),

            "entry":
                int(
                    getattr(d,"entry",0)
                    or 0
                ),

            "magic":
                magic,

            "volume":
                float(
                    getattr(d,"volume",0)
                    or 0
                ),

            "price":
                float(
                    getattr(d,"price",0)
                    or 0
                ),

            "profit":
                float(
                    getattr(d,"profit",0)
                    or 0
                ),

            "commission":
                float(
                    getattr(d,"commission",0)
                    or 0
                ),

            "swap":
                float(
                    getattr(d,"swap",0)
                    or 0
                ),

            "fee":
                float(
                    getattr(d,"fee",0)
                    or 0
                ),

            "comment":
                comment,
        })

    return out


'''

src = (
    src[:start]
    + new_history
    + src[end:]
)

path.write_text(
    src,
    encoding="utf-8"
)

print("HISTORY CLOCK FIX: APPLIED")
print("Added broker-clock-aware history")
print("Added exact deal/position reconciliation")
print("Updated daily P&L clock")