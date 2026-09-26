from pathlib import Path
import sys
root=Path(r"C:\Abutron\TradingPlatformV4")
sys.path.insert(0,str(root))
from sqlalchemy import inspect
from abutron.api import app
from abutron.platform_db import init_db,engine
init_db()
required={
"step27_crm_profiles",
"step27_crm_notes",
"step27_crm_tasks",
"step27_billing_invoices",
"step27_payment_events",
"step27_license_grants",
"step27_notification_preferences",
"step27_notification_outbox",
}
tables=set(inspect(engine).get_table_names())
missing=sorted(required-tables)
assert not missing,missing
print("STEP27_DB_TABLES=PASS")
