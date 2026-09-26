from pathlib import Path
import sys
root=Path(r"C:\Abutron\TradingPlatformV4")
sys.path.insert(0,str(root))
from abutron.api import app
routes={(m,r.path) for r in app.routes for m in (getattr(r,"methods",set()) or set())}
required={
("GET","/v1/customer/operations"),
("GET","/v1/customer/billing/invoices"),
("GET","/v1/customer/billing/invoices/{invoice_id}"),
("GET","/v1/customer/notification-preferences"),
("PATCH","/v1/customer/notification-preferences"),
("GET","/v1/admin/crm/customers"),
("GET","/v1/admin/crm/customers/{user_id}"),
("PATCH","/v1/admin/crm/customers/{user_id}"),
("POST","/v1/admin/crm/customers/{user_id}/notes"),
("POST","/v1/admin/crm/customers/{user_id}/tasks"),
("PATCH","/v1/admin/crm/tasks/{task_id}"),
("POST","/v1/admin/billing/invoices"),
("GET","/v1/admin/billing/invoices"),
("PATCH","/v1/admin/billing/invoices/{invoice_id}"),
("POST","/v1/admin/billing/invoices/{invoice_id}/record-payment"),
("POST","/v1/billing/webhook/generic"),
("POST","/v1/admin/licenses/grants"),
("POST","/v1/admin/licenses/grants/{grant_id}/approve"),
("POST","/v1/admin/licenses/grants/{grant_id}/revoke"),
("POST","/v1/admin/notifications"),
("GET","/v1/admin/notifications/outbox"),
("POST","/v1/admin/notifications/outbox/{outbox_id}/dispatch"),
("GET","/v1/admin/step27/summary"),
("GET","/admin/step27"),
}
missing=sorted(required-routes)
assert not missing,missing
print("STEP27_ROUTES=PASS")
