from pathlib import Path

ROOT = Path(r"C:\Abutron\TradingPlatformV4")

store_path = ROOT / "mt5_bridge" / "store.py"
app_path = ROOT / "mt5_bridge" / "app.py"

# ============================================================
# STORE: durable execution claims
# ============================================================

src = store_path.read_text(encoding="utf-8")

old = '''            db.execute("CREATE TABLE IF NOT EXISTS executions(key TEXT PRIMARY KEY,created_ts INTEGER NOT NULL,response TEXT NOT NULL)")
            db.execute("CREATE TABLE IF NOT EXISTS position_meta(ticket INTEGER PRIMARY KEY,created_ts INTEGER NOT NULL,initial_r REAL NOT NULL,tier TEXT NOT NULL,signal_key TEXT NOT NULL)")
'''

new = '''            db.execute("CREATE TABLE IF NOT EXISTS executions(key TEXT PRIMARY KEY,created_ts INTEGER NOT NULL,response TEXT NOT NULL)")
            db.execute("CREATE TABLE IF NOT EXISTS execution_claims(key TEXT PRIMARY KEY,created_ts INTEGER NOT NULL)")
            db.execute("CREATE TABLE IF NOT EXISTS position_meta(ticket INTEGER PRIMARY KEY,created_ts INTEGER NOT NULL,initial_r REAL NOT NULL,tier TEXT NOT NULL,signal_key TEXT NOT NULL)")
'''

if old in src:
    src = src.replace(old, new, 1)
elif "execution_claims" not in src:
    raise SystemExit(
        "PATCH ABORTED: store schema block not found"
    )

if "def claim(self,key):" not in src:
    marker = '''    def get(self,key):
'''

    methods = '''    def claim(self,key):
        """
        Atomically reserve an idempotency key before broker execution.

        The SQLite PRIMARY KEY provides protection across threads and
        separate gateway worker processes sharing the same database.
        """
        with self.db() as db:
            cur=db.execute(
                "INSERT OR IGNORE INTO execution_claims(key,created_ts) VALUES(?,?)",
                (str(key),int(time.time()))
            )
            db.commit()
            return cur.rowcount==1

    def release_claim(self,key):
        with self.db() as db:
            db.execute(
                "DELETE FROM execution_claims WHERE key=?",
                (str(key),)
            )
            db.commit()

    def claim_exists(self,key):
        with self.db() as db:
            row=db.execute(
                "SELECT created_ts FROM execution_claims WHERE key=?",
                (str(key),)
            ).fetchone()
            return int(row[0]) if row else None

'''

    if marker not in src:
        raise SystemExit(
            "PATCH ABORTED: store get() marker not found"
        )

    src = src.replace(
        marker,
        methods + marker,
        1
    )

store_path.write_text(
    src,
    encoding="utf-8"
)

# ============================================================
# APP: replace /v1/order with fail-closed execution flow
# ============================================================

src = app_path.read_text(encoding="utf-8")

start_marker = '@app.post("/v1/order")'
end_marker = '@app.post("/v1/manage")'

start = src.find(start_marker)
end = src.find(end_marker)

if start < 0 or end < 0 or end <= start:
    raise SystemExit(
        "PATCH ABORTED: /v1/order boundaries not found"
    )

new_order = '''@app.post("/v1/order")
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


'''

src = (
    src[:start]
    + new_order
    + src[end:]
)

app_path.write_text(
    src,
    encoding="utf-8"
)

print("EXECUTION HARDENING: APPLIED")
print("Mandatory order_check retcode enforcement: ENABLED")
print("Durable atomic idempotency claims: ENABLED")
print("Unknown post-send state: FAIL-CLOSED")