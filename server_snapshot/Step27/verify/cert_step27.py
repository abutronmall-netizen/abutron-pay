from pathlib import Path
import sys
root=Path(r"C:\Abutron\TradingPlatformV4")
sys.path.insert(0,str(root))
from sqlalchemy import inspect
from abutron.api import app
from abutron.config import settings
from abutron.platform_db import engine
required_tables={
"step27_crm_profiles","step27_crm_notes","step27_crm_tasks",
"step27_billing_invoices","step27_payment_events","step27_license_grants",
"step27_notification_preferences","step27_notification_outbox",
}
tables=set(inspect(engine).get_table_names())
assert not(required_tables-tables),sorted(required_tables-tables)
assert settings.execution_enabled is False
print("STEP27_DB_CONTRACT=PASS")
print("STEP27_EXECUTION_OFF=PASS")
