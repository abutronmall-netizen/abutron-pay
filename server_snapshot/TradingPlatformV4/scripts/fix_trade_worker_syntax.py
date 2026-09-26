from pathlib import Path

path = Path(
    r"C:\Abutron\TradingPlatformV4\abutron\worker.py"
)

src = path.read_text(
    encoding="utf-8"
)

replacements = {
'''            existing.symbol=
                result.symbol
''':
'''            existing.symbol=result.symbol
''',

'''            existing.side=
                result.plan.direction.value
''':
'''            existing.side=result.plan.direction.value
''',

'''            existing.tier=
                result.route.selected.value
''':
'''            existing.tier=result.route.selected.value
''',

'''            existing.volume=
                result.plan.volume
''':
'''            existing.volume=result.plan.volume
''',

'''            existing.entry=
                result.plan.entry
''':
'''            existing.entry=result.plan.entry
''',

'''            existing.sl=
                result.plan.sl
''':
'''            existing.sl=result.plan.sl
''',

'''            existing.tp=
                result.plan.tp
''':
'''            existing.tp=result.plan.tp
''',
}

changed = 0

for old,new in replacements.items():
    if old in src:
        src = src.replace(
            old,
            new,
            1,
        )
        changed += 1

path.write_text(
    src,
    encoding="utf-8",
)

print(
    f"WORKER SYNTAX FIX: {changed}/7 assignments corrected"
)

if changed != 7:
    raise SystemExit(
        "FIX ABORTED: expected 7 corrections"
    )