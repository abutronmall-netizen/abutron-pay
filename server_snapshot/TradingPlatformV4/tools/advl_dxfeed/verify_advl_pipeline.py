from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=r"C:\Abutron\TradingPlatformV4")
    args = parser.parse_args()
    root = Path(args.root)
    sys.path.insert(0, str(root))

    from abutron.advl import get_advl_feature

    feature = get_advl_feature()
    payload = feature.as_dict()
    print(json.dumps(payload, indent=2, sort_keys=True))

    if payload.get("source") != "DXFEED_MARKET_INDICATORS":
        print("PIPELINE=FAIL source", file=sys.stderr)
        return 2
    if payload.get("universe") != "NYSE+NASDAQ_COMPOSITE":
        print("PIPELINE=FAIL universe", file=sys.stderr)
        return 2
    if not payload.get("valid") or payload.get("stale"):
        print("PIPELINE=FAIL feature invalid/stale", file=sys.stderr)
        return 2
    if payload.get("applied"):
        print("PIPELINE=FAIL ADVL must remain shadow", file=sys.stderr)
        return 2

    print("PIPELINE=PASS")
    print("ADVL_MODE_EXPECTED=SHADOW")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
