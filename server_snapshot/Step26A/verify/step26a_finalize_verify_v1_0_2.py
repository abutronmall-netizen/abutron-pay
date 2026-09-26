from pathlib import Path
import json
import sys

ROOT = Path(r"C:\Abutron\TradingPlatformV4")
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from sqlalchemy import inspect
from abutron.api import app
from abutron.config import settings
from abutron.platform_db import engine

required_tables = {
    "step26a_devices",
    "step26a_notification_receipts",
    "step26a_support_tickets",
    "step26a_customer_preferences",
}

tables = set(inspect(engine).get_table_names())
missing_tables = sorted(required_tables - tables)
assert not missing_tables, f"missing tables: {missing_tables}"

routes = {
    (method, route.path)
    for route in app.routes
    for method in (getattr(route, "methods", set()) or set())
}

required_routes = {
    ("GET", "/v1/mobile/bootstrap"),
    ("GET", "/v1/customer/status"),
    ("PATCH", "/v1/customer/profile"),
    ("GET", "/v1/customer/accounts"),
    ("GET", "/v1/customer/trades"),
    ("POST", "/v1/devices/register"),
    ("GET", "/v1/devices"),
    ("DELETE", "/v1/devices/{device_id}"),
    ("GET", "/v1/notifications"),
    ("PUT", "/v1/notifications/{notification_id}/read"),
    ("POST", "/v1/support/tickets"),
    ("GET", "/v1/support/tickets"),
    ("GET", "/v1/admin/customers/{user_id}"),
    ("GET", "/v1/admin/support/tickets"),
    ("PUT", "/v1/admin/support/tickets/{ticket_id}"),
    ("GET", "/v1/admin/step26a/summary"),
    ("GET", "/admin/step26a"),
}

missing_routes = sorted(required_routes - routes)
assert not missing_routes, f"missing routes: {missing_routes}"
assert settings.execution_enabled is False, "execution_enabled must remain false"

api_source = (ROOT / "abutron" / "step26a_api.py").read_text(encoding="utf-8")
assert '"mobile_trading_mode": "READ_ONLY"' in api_source
assert '"order_entry": False' in api_source

mobile = (ROOT / "mobile" / "AbutronMobile" / "App.tsx").read_text(encoding="utf-8")
mobile_api = (ROOT / "mobile" / "AbutronMobile" / "src" / "api.ts").read_text(encoding="utf-8")
merged_mobile = mobile + "\n" + mobile_api

for forbidden in ("/v1/order", "Place Order", "order_send"):
    assert forbidden not in merged_mobile, forbidden

print("STEP26A_DB_CONTRACT=PASS")
print("STEP26A_ROUTE_CONTRACT=PASS")
print("STEP26A_READ_ONLY_CONTRACT=PASS")
print("STEP26A_MOBILE_SOURCE_CONTRACT=PASS")
print("STEP26A_EXECUTION_OFF=PASS")
