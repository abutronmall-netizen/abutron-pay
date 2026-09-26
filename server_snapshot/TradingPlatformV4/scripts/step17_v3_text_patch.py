import ast, shutil, sys, textwrap
from pathlib import Path

def out(k,v):
    print(f"{k}={v}", flush=True)

def die(m):
    out("STEP17_V3_TEXT_PATCH","FAILED")
    out("FAILURE",m)
    raise SystemExit(2)

if len(sys.argv)!=2:
    die("Usage: patch.py <step17 helper>")

p=Path(sys.argv[1])

if not p.exists():
    die(f"Missing helper: {p}")

src=p.read_text(encoding="utf-8-sig")

try:
    tree=ast.parse(src)
except SyntaxError as e:
    die(f"Existing helper syntax error: {e}")

funcs={
    n.name:n
    for n in ast.walk(tree)
    if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef))
}

need={
    "magic_deals_since",
    "emergency_close",
    "wait_position_absent"
}

missing=sorted(need-set(funcs))

if missing:
    die("Missing functions: "+",".join(missing))

if "wait_for_magic_deals" in funcs:
    c=" ".join(src.split())

    if (
        "after_open_deals = wait_for_magic_deals" in c
        and "final_deals = wait_for_magic_deals" in c
        and "EMERGENCY_SELECTED_FILLING" in src
        and "order_check" in src
    ):
        out("STEP17_V3_ALREADY_PATCHED","PASS")
        out("STEP17_V3_TEXT_PATCH","PASS")
        raise SystemExit(0)

    die("Partial prior Step17 v3 patch detected.")

assign={}

for n in ast.walk(tree):

    if not isinstance(n,ast.Assign):
        continue

    if len(n.targets)!=1:
        continue

    if not isinstance(n.targets[0],ast.Name):
        continue

    name=n.targets[0].id

    if name not in {
        "after_open_deals",
        "final_deals"
    }:
        continue

    if not isinstance(n.value,ast.Call):
        continue

    if not isinstance(n.value.func,ast.Name):
        continue

    if n.value.func.id!="magic_deals_since":
        continue

    assign[name]=n

for k in (
    "after_open_deals",
    "final_deals"
):
    if k not in assign:
        die(
            f"Missing {k}=magic_deals_since(...)"
        )

wait_src=textwrap.dedent('''
def wait_for_magic_deals(
    start_epoch,
    magic,
    symbol,
    minimum_count,
    seconds=20
):
    deadline=time.time()+seconds
    last=[]

    while time.time()<deadline:

        try:
            last=magic_deals_since(
                start_epoch,
                magic,
                symbol
            )
        except RuntimeError:
            last=[]

        if len(last)>=minimum_count:
            return last

        time.sleep(0.5)

    return last
''').strip()+"\n\n"

emergency_src=textwrap.dedent('''
def emergency_close(ticket: int, magic: int) -> bool:

    fills=[
        ("IOC",mt5.ORDER_FILLING_IOC),
        ("FOK",mt5.ORDER_FILLING_FOK),
        ("RETURN",mt5.ORDER_FILLING_RETURN)
    ]

    for cycle in range(1,5):

        rows=mt5.positions_get(
            ticket=int(ticket)
        )

        if rows is None:
            emit(
                "EMERGENCY_POSITION_QUERY_ERROR",
                mt5.last_error()
            )
            return False

        if len(rows)==0:
            return True

        if len(rows)!=1:
            emit(
                "EMERGENCY_POSITION_COUNT",
                len(rows)
            )
            return False

        pos=rows[0]

        owned=(
            int(
                getattr(
                    pos,
                    "magic",
                    0
                ) or 0
            )
            == int(magic)
            or
            str(
                getattr(
                    pos,
                    "comment",
                    ""
                ) or ""
            )
            .upper()
            .startswith("ABUTRON")
        )

        if not owned:
            emit(
                "EMERGENCY_OWNERSHIP_CHECK",
                "FAILED"
            )
            return False

        tick=mt5.symbol_info_tick(
            pos.symbol
        )

        if tick is None:
            emit(
                "EMERGENCY_TICK",
                "UNAVAILABLE"
            )
            time.sleep(1)
            continue

        is_buy=(
            int(pos.type)
            ==
            int(mt5.POSITION_TYPE_BUY)
        )

        selected=None

        for name,fill in fills:

            req={
                "action":
                    mt5.TRADE_ACTION_DEAL,

                "position":
                    int(pos.ticket),

                "symbol":
                    pos.symbol,

                "volume":
                    float(pos.volume),

                "type":
                    mt5.ORDER_TYPE_SELL
                    if is_buy
                    else mt5.ORDER_TYPE_BUY,

                "price":
                    float(
                        tick.bid
                        if is_buy
                        else tick.ask
                    ),

                "deviation":
                    50,

                "magic":
                    int(magic),

                "comment":
                    "ABUTRON S17 EMERG",

                "type_time":
                    mt5.ORDER_TIME_GTC,

                "type_filling":
                    int(fill)
            }

            chk=mt5.order_check(req)

            if chk is None:

                emit(
                    f"EMERGENCY_CHECK_{name}_RETCODE",
                    "NONE"
                )

                continue

            rc=int(
                getattr(
                    chk,
                    "retcode",
                    -1
                )
            )

            emit(
                f"EMERGENCY_CHECK_{name}_RETCODE",
                rc
            )

            if rc==0:
                selected=(name,req)
                break

        if selected is None:

            emit(
                "EMERGENCY_SUPPORTED_FILLING",
                "NONE"
            )

            return False

        name,req=selected

        emit(
            "EMERGENCY_SELECTED_FILLING",
            name
        )

        emit(
            "EMERGENCY_SEND_CYCLE",
            cycle
        )

        res=mt5.order_send(req)

        if res is None:

            emit(
                "EMERGENCY_SEND_NONE",
                mt5.last_error()
            )

            time.sleep(1)
            continue

        rc=int(
            getattr(
                res,
                "retcode",
                -1
            )
        )

        emit(
            "EMERGENCY_SEND_RETCODE",
            rc
        )

        if rc in (
            int(
                mt5.TRADE_RETCODE_DONE
            ),
            int(
                mt5.TRADE_RETCODE_DONE_PARTIAL
            )
        ):

            if wait_position_absent(
                ticket,
                seconds=15
            ):
                return True

        time.sleep(1)

    return wait_position_absent(
        ticket,
        seconds=2
    )
''').strip()+"\n\n"

lines=src.splitlines(
    keepends=True
)

edits=[]

m=funcs["magic_deals_since"]

edits.append(
    (
        m.end_lineno,
        m.end_lineno,
        wait_src
    )
)

e=funcs["emergency_close"]

edits.append(
    (
        e.lineno-1,
        e.end_lineno,
        emergency_src
    )
)

for name,inc in (
    ("after_open_deals",1),
    ("final_deals",2)
):

    n=assign[name]

    call=ast.Call(
        func=ast.Name(
            id="wait_for_magic_deals",
            ctx=ast.Load()
        ),
        args=
            list(n.value.args)
            +
            [
                ast.BinOp(
                    left=ast.Name(
                        id="baseline_magic_deals",
                        ctx=ast.Load()
                    ),
                    op=ast.Add(),
                    right=ast.Constant(
                        value=inc
                    )
                )
            ],
        keywords=
            list(
                n.value.keywords
            )
    )

    rep=ast.Assign(
        targets=n.targets,
        value=call,
        type_comment=getattr(
            n,
            "type_comment",
            None
        )
    )

    ast.fix_missing_locations(rep)

    replacement=(
        " "*n.col_offset
        +
        ast.unparse(rep)
        +
        "\n"
    )

    edits.append(
        (
            n.lineno-1,
            n.end_lineno,
            replacement
        )
    )

for a,b,r in sorted(
    edits,
    key=lambda x:(
        x[0],
        x[1]
    ),
    reverse=True
):
    lines[a:b]=[r]

new="".join(lines)

try:
    newtree=ast.parse(new)
except SyntaxError as e:
    die(
        f"Patched helper syntax error: {e}"
    )

c=" ".join(
    new.split()
)

if (
    "after_open_deals = wait_for_magic_deals"
    not in c
):
    die(
        "Open history patch missing"
    )

if (
    "final_deals = wait_for_magic_deals"
    not in c
):
    die(
        "Close history patch missing"
    )

if (
    "EMERGENCY_SELECTED_FILLING"
    not in new
):
    die(
        "Emergency filling patch missing"
    )

if "order_check" not in new:
    die(
        "Emergency order_check patch missing"
    )

bak=p.with_suffix(
    p.suffix
    +
    ".before-step17-v3-text.bak"
)

if not bak.exists():
    shutil.copy2(
        p,
        bak
    )

p.write_text(
    new,
    encoding="utf-8"
)

out(
    "STEP17_V3_BACKUP",
    bak
)

out(
    "STEP17_V3_HISTORY_POLLING",
    "PASS"
)

out(
    "STEP17_V3_EMERGENCY_CLOSE_REPAIR",
    "PASS"
)

out(
    "STEP17_V3_AST_VALIDATION",
    "PASS"
)

out(
    "STEP17_V3_TEXT_PATCH",
    "PASS"
)
