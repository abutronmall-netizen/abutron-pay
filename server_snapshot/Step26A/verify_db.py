from sqlalchemy import inspect
from abutron.api import app
from abutron.platform_db import init_db, engine
init_db()
required={
    "step26a_devices",
    "step26a_notification_receipts",
    "step26a_support_tickets",
    "step26a_customer_preferences",
}
tables=set(inspect(engine).get_table_names())
missing=required-tables
assert not missing, missing
print("STEP26A_DB_TABLES=PASS")
