from sqlalchemy import inspect
from abutron.api import app
from abutron.config import settings
from abutron.platform_db import engine

routes={(m,r.path) for r in app.routes for m in (getattr(r,"methods",set()) or set())}
required_routes={
("GET","/v1/mobile/bootstrap"),
("GET","/v1/customer/status"),
("PATCH","/v1/customer/profile"),
("GET","/v1/customer/accounts"),
("GET","/v1/customer/trades"),
("POST","/v1/devices/register"),
("GET","/v1/devices"),
("DELETE","/v1/devices/{device_id}"),
("GET","/v1/notifications"),
("PUT","/v1/notifications/{notification_id}/read"),
("POST","/v1/support/tickets"),
("GET","/v1/support/tickets"),
("GET","/v1/admin/customers/{user_id}"),
("GET","/v1/admin/support/tickets"),
("PUT","/v1/admin/support/tickets/{ticket_id}"),
("GET","/v1/admin/step26a/summary"),
("GET","/admin/step26a"),
}
required_tables={
"step26a_devices",
"step26a_notification_receipts",
"step26a_support_tickets",
"step26a_customer_preferences",
}
tables=set(inspect(engine).get_table_names())
missing_routes=sorted(required_routes-routes)
missing_tables=sorted(required_tables-tables)
assert not missing_routes, missing_routes
assert not missing_tables, missing_tables
assert settings.execution_enabled is False, "execution_enabled must remain false"
print("STEP26A_ROUTE_CONTRACT=PASS")
print("STEP26A_DB_CONTRACT=PASS")
print("STEP26A_EXECUTION_OFF=PASS")
