from __future__ import annotations
import time
from datetime import datetime,timedelta
from fastapi import FastAPI,Header,HTTPException
from abutron.models import OrderPlan
from abutron.symbols import ALIASES,normalize_symbol
from mt5_bridge.settings import settings
from mt5_bridge.store import IdempotencyStore

try:
    import MetaTrader5 as mt5
except Exception:
    mt5=None

app=FastAPI(title="Abutron MT5 Gateway",version="4.0.0")
store=IdempotencyStore()

def auth(authorization):
    if settings.api_token.startswith("CHANGE_ME"): raise HTTPException(503,"Configure MT5_API_TOKEN")
    if authorization!=f"Bearer {settings.api_token}": raise HTTPException(401,"Unauthorized")

def ready():
    if mt5 is None: raise HTTPException(503,"MetaTrader5 package unavailable")
    if not mt5.initialize(): raise HTTPException(503,f"MT5 initialize failed: {mt5.last_error()}")


def _require_demo_if_configured():
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


def _is_abutron_position(position):
    magic=int(getattr(position,"magic",0) or 0)
    comment=str(getattr(position,"comment","") or "").upper()

    return (
        magic==settings.magic
        or comment.startswith("ABUTRON")
    )

def timeframes():
    return {"M1":mt5.TIMEFRAME_M1,"M5":mt5.TIMEFRAME_M5,"M15":mt5.TIMEFRAME_M15,
            "M30":mt5.TIMEFRAME_M30,"H1":mt5.TIMEFRAME_H1,"H4":mt5.TIMEFRAME_H4,"D1":mt5.TIMEFRAME_D1}

def raw_symbol(canonical):
    ready(); c=normalize_symbol(canonical); names=[s.name for s in (mt5.symbols_get() or [])]
    clean=lambda x:"".join(ch for ch in x.upper() if ch.isalnum())
    for alias in ALIASES[c]:
        a=clean(alias)
        for n in names:
            cn=clean(n)
            if cn==a or cn.startswith(a):
                mt5.symbol_select(n,True); return n
    raise HTTPException(404,f"No broker symbol found for {canonical}")

def _broker_now():
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


def _position_dict(p):
    return {"ticket":int(p.ticket),"symbol":p.symbol,"type":"BUY" if p.type==mt5.POSITION_TYPE_BUY else "SELL",
            "volume":float(p.volume),"price_open":float(p.price_open),"price_current":float(p.price_current),
            "sl":float(p.sl),"tp":float(p.tp),"profit":float(p.profit),"comment":str(p.comment),
            "magic":int(p.magic),"time":int(p.time)}

def _position_open_risk(p):
    if not p.sl or p.volume<=0: return 0.0
    info=mt5.symbol_info(p.symbol)
    if not info: return 0.0
    tick_size=float(info.trade_tick_size or info.point or 0)
    tick_value=float(info.trade_tick_value or 0)
    if tick_size<=0 or tick_value<=0: return 0.0
    dist=abs(float(p.price_open)-float(p.sl))
    return (dist/tick_size)*tick_value*float(p.volume)

def _filling():
    return {"FOK":mt5.ORDER_FILLING_FOK,"IOC":mt5.ORDER_FILLING_IOC,"RETURN":mt5.ORDER_FILLING_RETURN}.get(settings.filling_mode.upper(),mt5.ORDER_FILLING_IOC)

@app.get("/health")
def health():
    ok=False; terminal=None; account=None
    if mt5 is not None:
        ok=bool(mt5.initialize())
        if ok:
            t=mt5.terminal_info(); terminal=t.name if t else None
            a=mt5.account_info(); account=int(a.login) if a else None
    return {"status":"ok" if ok else "degraded","version":"4.0.0","mt5_connected":ok,
            "terminal":terminal,"account":account,"live_trading":settings.live_trading,
            "management_enabled":settings.management_enabled}

@app.get("/v1/account")
def account(authorization:str|None=Header(default=None)):
    auth(authorization); ready()
    a=mt5.account_info()
    if a is None: raise HTTPException(503,"MT5 account unavailable")
    now=_broker_now()
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
    pnl=sum(float(getattr(d,"profit",0))+float(getattr(d,"commission",0))+float(getattr(d,"swap",0)) for d in deals)
    pos=mt5.positions_get() or []
    open_risk=sum(_position_open_risk(p) for p in pos if int(getattr(p,"magic",0))==settings.magic or str(getattr(p,"comment","")).upper().startswith("ABUTRON"))
    return {"equity":float(a.equity),"balance":float(a.balance),"daily_pnl":float(pnl),
            "open_risk":float(open_risk),"license_active":True,"positions_total":len(pos),
            "login":str(getattr(a,"login","")),"server":str(getattr(a,"server","")),"currency":str(getattr(a,"currency",""))}

@app.get("/v1/positions")
def positions(authorization:str|None=Header(default=None)):
    auth(authorization); ready()
    return [_position_dict(p) for p in (mt5.positions_get() or [])]

@app.get("/v1/history")
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


@app.get("/v1/context/{symbol}")
def context(symbol:str,authorization:str|None=Header(default=None)):
    auth(authorization); rs=raw_symbol(symbol); info=mt5.symbol_info(rs); tick=mt5.symbol_info_tick(rs)
    if info is None or tick is None: raise HTTPException(503,"Symbol context unavailable")
    point=float(info.point or 0); spread=((tick.ask-tick.bid)/point) if point>0 else float(info.spread)
    pos=mt5.positions_get(symbol=rs) or []
    return {"symbol":normalize_symbol(symbol),"bid":tick.bid,"ask":tick.ask,"point":point,
            "tick_size":float(info.trade_tick_size or point),"tick_value":float(info.trade_tick_value or 0),
            "volume_min":float(info.volume_min),"volume_max":float(info.volume_max),
            "volume_step":float(info.volume_step),"spread_points":float(spread),"positions_on_symbol":len(pos)}

@app.get("/v1/bars/{symbol}")
def bars(symbol:str,timeframe:str="M5",count:int=512,authorization:str|None=Header(default=None)):
    auth(authorization); rs=raw_symbol(symbol); tf=timeframe.upper(); TF=timeframes()
    if tf not in TF: raise HTTPException(400,"Unsupported timeframe")
    count=max(64,min(count,2048)); rates=mt5.copy_rates_from_pos(rs,TF[tf],0,count)
    if rates is None or len(rates)<64: raise HTTPException(503,f"Insufficient bars: {mt5.last_error()}")
    candles=[{"ts":int(r["time"]),"open":float(r["open"]),"high":float(r["high"]),"low":float(r["low"]),
              "close":float(r["close"]),"volume":float(r["tick_volume"])} for r in rates]
    tick=mt5.symbol_info_tick(rs); info=mt5.symbol_info(rs); point=float(info.point or 0)
    spread=((tick.ask-tick.bid)/point) if tick and point>0 else float(info.spread)
    return {"symbol":normalize_symbol(symbol),"timeframe":tf,"candles":candles,
            "spread_points":float(spread),"received_ts":int(time.time())}


def _build_order_request(plan:OrderPlan):
    rs=raw_symbol(plan.symbol)
    tick=mt5.symbol_info_tick(rs)
    info=mt5.symbol_info(rs)

    if tick is None or info is None:
        raise HTTPException(503,"No symbol tick/info")

    positions=mt5.positions_get(symbol=rs) or []
    desired_buy=plan.direction.value=="BUY"

    for p in positions:
        if (p.type==mt5.POSITION_TYPE_BUY)!=desired_buy:
            raise HTTPException(409,"Opposing position exists")

    volume=float(plan.volume)
    volume_min=float(info.volume_min)
    volume_max=float(info.volume_max)
    volume_step=float(info.volume_step)

    if volume < volume_min-1e-12:
        raise HTTPException(400,"Volume below broker minimum")

    if volume > volume_max+1e-12:
        raise HTTPException(400,"Volume above broker maximum")

    if volume_step>0:
        steps=round(volume/volume_step)
        normalized=steps*volume_step
        if abs(volume-normalized)>1e-9:
            raise HTTPException(
                400,
                f"Volume not aligned to broker step {volume_step}"
            )

    price=tick.ask if desired_buy else tick.bid

    request={
        "action":mt5.TRADE_ACTION_DEAL,
        "symbol":rs,
        "volume":volume,
        "type":mt5.ORDER_TYPE_BUY if desired_buy else mt5.ORDER_TYPE_SELL,
        "price":price,
        "sl":float(plan.sl),
        "tp":float(plan.tp),
        "deviation":settings.deviation_points,
        "magic":settings.magic,
        "comment":f"ABUTRON {plan.tier.value}"[:31],
        "type_time":mt5.ORDER_TIME_GTC,
        "type_filling":_filling()
    }

    return rs,desired_buy,request,info


@app.post("/v1/order-check")
def order_check_only(plan:OrderPlan,authorization:str|None=Header(default=None)):
    auth(authorization)
    ready()

    rs,desired_buy,request,info=_build_order_request(plan)

    check=mt5.order_check(request)

    if check is None:
        raise HTTPException(
            502,
            f"order_check failed: {mt5.last_error()}"
        )

    retcode=int(getattr(check,"retcode",-1))

    return {
        "checked":True,
        "order_sent":False,
        "retcode":retcode,
        "check_passed":retcode==0,
        "comment":str(getattr(check,"comment","")),
        "symbol":rs,
        "direction":plan.direction.value,
        "volume":float(plan.volume),
        "price":float(request["price"]),
        "sl":float(plan.sl),
        "tp":float(plan.tp),
        "broker":{
            "volume_min":float(info.volume_min),
            "volume_max":float(info.volume_max),
            "volume_step":float(info.volume_step),
            "tick_size":float(info.trade_tick_size),
            "tick_value":float(info.trade_tick_value),
            "stops_level":int(info.trade_stops_level)
        },
        "margin":float(getattr(check,"margin",0.0) or 0.0),
        "margin_free":float(getattr(check,"margin_free",0.0) or 0.0),
        "margin_level":float(getattr(check,"margin_level",0.0) or 0.0)
    }


@app.post("/v1/order")
def order(
    plan:OrderPlan,
    authorization:str|None=Header(default=None)
):
    auth(authorization)
    ready()

    key=str(plan.idempotency_key)

    # --------------------------------------------------------
    # COMPLETED REQUEST
    # --------------------------------------------------------

    prior=store.get(key)

    if prior is not None:
        return {
            "duplicate":True,
            **prior
        }

    # --------------------------------------------------------
    # ATOMIC EXECUTION CLAIM
    #
    # Only one request is permitted to own an idempotency key.
    # A second simultaneous request fails closed instead of
    # reaching the broker.
    # --------------------------------------------------------

    if not store.claim(key):

        # The first request may have completed between get()
        # and claim(). Re-read before reporting in-progress.

        prior=store.get(key)

        if prior is not None:
            return {
                "duplicate":True,
                **prior
            }

        raise HTTPException(
            409,
            detail={
                "accepted":False,
                "mode":"IDEMPOTENCY_IN_PROGRESS",
                "idempotency_key":key
            }
        )

    send_attempted=False

    try:

        # Re-check after winning the claim.
        prior=store.get(key)

        if prior is not None:
            store.release_claim(key)

            return {
                "duplicate":True,
                **prior
            }

        # ----------------------------------------------------
        # DRY RUN
        # ----------------------------------------------------

        if not settings.live_trading:

            out={
                "accepted":False,
                "mode":"DRY_RUN",
                "reason":"MT5_LIVE_TRADING_FALSE",
                "plan":plan.model_dump(
                    mode="json"
                )
            }

            store.put(
                key,
                out
            )

            store.release_claim(
                key
            )

            return out

        # ----------------------------------------------------
        # DEMO / ACCOUNT SAFETY
        # ----------------------------------------------------

        _require_demo_if_configured()

        # ----------------------------------------------------
        # BROKER REQUEST
        # ----------------------------------------------------

        (
            rs,
            desired_buy,
            request,
            info
        )=_build_order_request(
            plan
        )

        # ----------------------------------------------------
        # MANDATORY BROKER ORDER CHECK
        # ----------------------------------------------------

        check=mt5.order_check(
            request
        )

        if check is None:
            raise HTTPException(
                502,
                f"order_check failed: {mt5.last_error()}"
            )

        check_retcode=int(
            getattr(
                check,
                "retcode",
                -1
            )
        )

        check_comment=str(
            getattr(
                check,
                "comment",
                ""
            )
        )

        if check_retcode != 0:

            out={
                "accepted":False,
                "mode":"ORDER_CHECK_REJECTED",
                "check_retcode":
                    check_retcode,
                "check_comment":
                    check_comment,
                "symbol":
                    rs,
                "volume":
                    float(plan.volume),
                "idempotency_key":
                    key
            }

            # Persist deterministic rejection so a duplicate
            # key cannot later bypass this result.

            store.put(
                key,
                out
            )

            raise HTTPException(
                409,
                detail=out
            )

        # ----------------------------------------------------
        # BROKER SEND
        #
        # From this point onward, if the process dies before
        # persistence, the durable claim intentionally remains.
        # This is fail-closed: the same key cannot automatically
        # be sent again when broker state is unknown.
        # ----------------------------------------------------

        send_attempted=True

        result=mt5.order_send(
            request
        )

        if result is None:

            out={
                "accepted":False,
                "mode":"ORDER_SEND_UNKNOWN",
                "reason":
                    str(mt5.last_error()),
                "symbol":
                    rs,
                "volume":
                    float(plan.volume),
                "idempotency_key":
                    key
            }

            # Persist UNKNOWN rather than allowing the same
            # key to automatically resend.

            store.put(
                key,
                out
            )

            store.release_claim(
                key
            )

            raise HTTPException(
                502,
                detail=out
            )

        # ----------------------------------------------------
        # POSITION IDENTIFICATION
        # ----------------------------------------------------

        position_ticket=0

        if (
            result.retcode
            == mt5.TRADE_RETCODE_DONE
        ):

            candidates=[]

            for q in (
                mt5.positions_get(
                    symbol=rs
                )
                or []
            ):

                q_buy=(
                    q.type
                    == mt5.POSITION_TYPE_BUY
                )

                if (
                    int(
                        getattr(
                            q,
                            "magic",
                            0
                        )
                    )
                    == settings.magic
                    and q_buy
                    == desired_buy
                ):
                    candidates.append(
                        q
                    )

            if candidates:

                q=max(
                    candidates,
                    key=lambda x:
                        int(
                            getattr(
                                x,
                                "time_msc",
                                0
                            )
                            or getattr(
                                x,
                                "time",
                                0
                            )
                        )
                )

                position_ticket=int(
                    q.ticket
                )

                store.put_position(
                    position_ticket,
                    abs(
                        float(plan.entry)
                        - float(plan.sl)
                    ),
                    plan.tier.value,
                    key
                )

        # ----------------------------------------------------
        # FINAL BROKER RESULT
        # ----------------------------------------------------

        out={
            "accepted":
                result.retcode
                == mt5.TRADE_RETCODE_DONE,

            "retcode":
                int(result.retcode),

            "order":
                int(
                    getattr(
                        result,
                        "order",
                        0
                    )
                    or 0
                ),

            "deal":
                int(
                    getattr(
                        result,
                        "deal",
                        0
                    )
                    or 0
                ),

            "position_ticket":
                position_ticket,

            "comment":
                str(
                    getattr(
                        result,
                        "comment",
                        ""
                    )
                ),

            "symbol":
                rs,

            "volume":
                float(plan.volume),

            "check_retcode":
                check_retcode,

            "check_comment":
                check_comment
        }

        # Persistence must succeed before the claim is released.
        # If persistence crashes, the durable claim remains and
        # blocks an automatic duplicate send.

        store.put(
            key,
            out
        )

        store.release_claim(
            key
        )

        if not out["accepted"]:
            raise HTTPException(
                502,
                detail=out
            )

        return out

    except HTTPException:

        # Safe to release only when broker order_send was never
        # attempted. Once sending begins, unresolved states must
        # remain fail-closed unless a result was explicitly stored
        # and the claim released above.

        if not send_attempted:
            store.release_claim(
                key
            )

        raise

    except Exception:

        if not send_attempted:
            store.release_claim(
                key
            )

        raise


@app.post("/v1/manage")
def manage(authorization:str|None=Header(default=None)):
    # STEP18_MANAGEMENT_HARDENING_V1
    auth(authorization)
    ready()

    if not settings.management_enabled:
        return {
            "managed": False,
            "reason": "MT5_MANAGEMENT_ENABLED_FALSE",
            "actions": [],
        }

    _require_demo_if_configured()

    import math

    actions = []

    for p in (mt5.positions_get() or []):
        if not _is_abutron_position(p):
            continue

        if not p.sl:
            continue

        meta = store.get_position(int(p.ticket))

        initial_r = (
            float(meta["initial_r"])
            if meta
            else abs(float(p.price_open) - float(p.sl))
        )

        if initial_r <= 0:
            continue

        current = float(p.price_current)
        entry = float(p.price_open)
        old_sl = float(p.sl)
        tp = float(p.tp)
        is_buy = p.type == mt5.POSITION_TYPE_BUY

        favorable = (
            current - entry
            if is_buy
            else entry - current
        )

        requested_sl = old_sl

        if (
            settings.break_even_enabled
            and favorable >= settings.break_even_r * initial_r
        ):
            requested_sl = (
                max(requested_sl, entry)
                if is_buy
                else min(requested_sl, entry)
            )

        if (
            settings.trailing_enabled
            and favorable >= settings.trail_start_r * initial_r
        ):
            candidate = (
                current - settings.trail_distance_r * initial_r
                if is_buy
                else current + settings.trail_distance_r * initial_r
            )

            requested_sl = (
                max(requested_sl, candidate)
                if is_buy
                else min(requested_sl, candidate)
            )

        improves_requested = (
            requested_sl > old_sl + 1e-12
            if is_buy
            else requested_sl < old_sl - 1e-12
        )

        if not improves_requested:
            continue

        info = mt5.symbol_info(p.symbol)
        tick = mt5.symbol_info_tick(p.symbol)

        if info is None or tick is None:
            actions.append({
                "ticket": int(p.ticket),
                "old_sl": old_sl,
                "new_sl": old_sl,
                "ok": False,
                "retcode": None,
                "reason": "MANAGE_MARKET_INFO_UNAVAILABLE",
            })
            continue

        point = float(getattr(info, "point", 0.0) or 0.0)
        tick_size = float(
            getattr(info, "trade_tick_size", 0.0)
            or point
            or 0.0
        )

        if tick_size <= 0:
            actions.append({
                "ticket": int(p.ticket),
                "old_sl": old_sl,
                "new_sl": old_sl,
                "ok": False,
                "retcode": None,
                "reason": "MANAGE_INVALID_TICK_SIZE",
            })
            continue

        stops_level = int(
            getattr(info, "trade_stops_level", 0)
            or 0
        )
        freeze_level = int(
            getattr(info, "trade_freeze_level", 0)
            or 0
        )

        broker_points = max(
            stops_level,
            freeze_level,
            0,
        )

        broker_distance = (
            float(broker_points) * point
            + tick_size
        )

        market_reference = float(
            tick.bid
            if is_buy
            else tick.ask
        )

        if is_buy:
            broker_limit = market_reference - broker_distance
            broker_limit = (
                math.floor(broker_limit / tick_size)
                * tick_size
            )
            safe_sl = min(requested_sl, broker_limit)
            safe_sl = (
                math.floor(safe_sl / tick_size)
                * tick_size
            )
        else:
            broker_limit = market_reference + broker_distance
            broker_limit = (
                math.ceil(broker_limit / tick_size)
                * tick_size
            )
            safe_sl = max(requested_sl, broker_limit)
            safe_sl = (
                math.ceil(safe_sl / tick_size)
                * tick_size
            )

        safe_sl = round(
            safe_sl,
            int(getattr(info, "digits", 10) or 10),
        )

        improves_safe = (
            safe_sl > old_sl + 1e-12
            if is_buy
            else safe_sl < old_sl - 1e-12
        )

        if not improves_safe:
            actions.append({
                "ticket": int(p.ticket),
                "old_sl": old_sl,
                "new_sl": old_sl,
                "ok": False,
                "retcode": None,
                "reason": "MANAGE_BROKER_CONSTRAINT_NO_SAFE_IMPROVEMENT",
            })
            continue

        req = {
            "action": mt5.TRADE_ACTION_SLTP,
            "position": int(p.ticket),
            "symbol": p.symbol,
            "sl": float(safe_sl),
            "tp": tp,
            "magic": settings.magic,
        }

        check = mt5.order_check(req)

        if check is None:
            actions.append({
                "ticket": int(p.ticket),
                "old_sl": old_sl,
                "new_sl": safe_sl,
                "ok": False,
                "retcode": None,
                "reason": "MANAGE_ORDER_CHECK_NONE",
            })
            continue

        check_retcode = int(
            getattr(check, "retcode", -1)
        )

        if check_retcode != 0:
            actions.append({
                "ticket": int(p.ticket),
                "old_sl": old_sl,
                "new_sl": safe_sl,
                "ok": False,
                "retcode": check_retcode,
                "reason": "MANAGE_ORDER_CHECK_REJECTED",
            })
            continue

        res = mt5.order_send(req)

        actions.append({
            "ticket": int(p.ticket),
            "old_sl": old_sl,
            "new_sl": safe_sl,
            "requested_sl": float(requested_sl),
            "broker_limit": float(broker_limit),
            "broker_stops_level": stops_level,
            "broker_freeze_level": freeze_level,
            "ok": bool(
                res
                and res.retcode == mt5.TRADE_RETCODE_DONE
            ),
            "retcode": int(res.retcode) if res else None,
            "reason": (
                "MANAGE_SLTP_DONE"
                if (
                    res
                    and res.retcode == mt5.TRADE_RETCODE_DONE
                )
                else "MANAGE_SLTP_FAILED"
            ),
        })

    return {
        "managed": True,
        "actions": actions,
    }



@app.post("/v1/close/{ticket}")
def close(ticket:int,authorization:str|None=Header(default=None)):
    auth(authorization); ready()
    if not settings.live_trading:
        return {"closed":False,"reason":"MT5_LIVE_TRADING_FALSE","ticket":ticket}

    _require_demo_if_configured()

    rows=mt5.positions_get(ticket=ticket) or []
    if not rows: raise HTTPException(404,"Position not found")
    p=rows[0]

    if not _is_abutron_position(p):
        raise HTTPException(
            403,
            "Refusing to close position not owned by Abutron"
        )

    tick=mt5.symbol_info_tick(p.symbol)
    if tick is None: raise HTTPException(503,"No tick")
    is_buy=p.type==mt5.POSITION_TYPE_BUY
    req={"action":mt5.TRADE_ACTION_DEAL,"position":int(p.ticket),"symbol":p.symbol,"volume":float(p.volume),
         "type":mt5.ORDER_TYPE_SELL if is_buy else mt5.ORDER_TYPE_BUY,
         "price":tick.bid if is_buy else tick.ask,"deviation":settings.deviation_points,
         "magic":settings.magic,"comment":"ABUTRON CLOSE","type_time":mt5.ORDER_TIME_GTC,"type_filling":_filling()}
    res=mt5.order_send(req)
    if res is None: raise HTTPException(502,f"close failed: {mt5.last_error()}")
    out={"closed":res.retcode==mt5.TRADE_RETCODE_DONE,"retcode":int(res.retcode),"ticket":ticket,
         "deal":int(getattr(res,"deal",0) or 0),"comment":str(getattr(res,"comment",""))}
    if not out["closed"]: raise HTTPException(502,detail=out)
    store.delete_position(ticket)
    return out
