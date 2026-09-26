from pathlib import Path
import sys

ROOT=Path(r"C:\Abutron\TradingPlatformV4")
sys.path.insert(0,str(ROOT))

from sqlalchemy import inspect
from abutron.api import app
from abutron.config import settings
from abutron.platform_db import engine

required_tables={
    "step26a_devices",
    "step26a_notification_receipts",
    "step26a_support_tickets",
    "step26a_customer_preferences",
}
tables=set(inspect(engine).get_table_names())
missing=sorted(required_tables-tables)
assert not missing, missing

required_paths={
    "/v1/mobile/bootstrap",
    "/v1/customer/status",
    "/v1/customer/profile",
    "/v1/customer/accounts",
    "/v1/customer/trades",
    "/v1/devices/register",
    "/v1/devices",
    "/v1/notifications",
    "/v1/notifications/{notification_id}/read",
    "/v1/support/tickets",
    "/v1/admin/customers/{user_id}",
    "/v1/admin/support/tickets",
    "/v1/admin/support/tickets/{ticket_id}",
    "/v1/admin/step26a/summary",
    "/admin/step26a",
}
paths={r.path for r in app.routes}
missing_paths=sorted(required_paths-paths)
assert not missing_paths, missing_paths
assert settings.execution_enabled is False

api=(ROOT/"abutron"/"step26a_api.py").read_text(encoding="utf-8")
assert '"mobile_trading_mode": "READ_ONLY"' in api
assert '"order_entry": False' in api

mobile=(ROOT/"mobile"/"AbutronMobile"/"App.tsx").read_text(encoding="utf-8")
mobile_api=(ROOT/"mobile"/"AbutronMobile"/"src"/"api.ts").read_text(encoding="utf-8")
merged=mobile+"\n"+mobile_api
for forbidden in ("/v1/order","Place Order","order_send"):
    assert forbidden not in merged, forbidden

print("STEP26A_DB_CONTRACT=PASS")
print("STEP26A_ROUTE_CONTRACT=PASS")
print("STEP26A_READ_ONLY_CONTRACT=PASS")
print("STEP26A_MOBILE_SOURCE_CONTRACT=PASS")
print("STEP26A_EXECUTION_OFF=PASS")
