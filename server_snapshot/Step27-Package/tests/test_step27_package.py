import ast
import json
import unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]


class Step27PackageTests(unittest.TestCase):
    def text(self, rel):
        return (ROOT/rel).read_text(encoding="utf-8")

    def test_python_syntax(self):
        for rel in (
            "src/abutron/step27_models.py",
            "src/abutron/step27_service.py",
            "src/abutron/step27_api.py",
            "scripts/patch_api.py",
        ):
            ast.parse(self.text(rel))

    def test_manifest_safety(self):
        m=json.loads(self.text("MANIFEST.json"))
        self.assertFalse(m["scope"]["broker_execution"])
        self.assertFalse(m["scope"]["live_money_authority"])
        self.assertFalse(m["scope"]["external_payment_provider_certified"])
        self.assertTrue(m["safety"]["payment_does_not_auto_activate_license"])
        self.assertTrue(m["safety"]["external_providers_fail_closed"])

    def test_required_tables(self):
        src=self.text("src/abutron/step27_models.py")
        for table in (
            "step27_crm_profiles","step27_crm_notes","step27_crm_tasks",
            "step27_billing_invoices","step27_payment_events","step27_license_grants",
            "step27_notification_preferences","step27_notification_outbox",
        ):
            self.assertIn(table,src)

    def test_required_routes(self):
        src=self.text("src/abutron/step27_api.py")
        for route in (
            "/v1/customer/operations",
            "/v1/admin/crm/customers",
            "/v1/admin/billing/invoices",
            "/v1/billing/webhook/generic",
            "/v1/admin/licenses/grants",
            "/v1/admin/notifications",
            "/v1/admin/step27/summary",
            "/admin/step27",
        ):
            self.assertIn(route,src)

    def test_no_execution_hooks(self):
        merged="\n".join(
            self.text(x) for x in (
                "src/abutron/step27_models.py",
                "src/abutron/step27_service.py",
                "src/abutron/step27_api.py",
            )
        ).lower()
        for bad in ("order_send","mt5gateway","gateway.order","execute=true"):
            self.assertNotIn(bad,merged)

    def test_payment_license_separation(self):
        src=self.text("src/abutron/step27_api.py")
        self.assertIn('"license_auto_activated": False',src)
        self.assertIn('"trading_execution_changed": False',src)
        # Webhook route itself must not instantiate a License.
        start=src.index("async def generic_billing_webhook")
        end=src.index('@router.post("/v1/admin/licenses/grants")')
        webhook=src[start:end]
        self.assertNotIn("License(",webhook)

    def test_webhook_fail_closed(self):
        service=self.text("src/abutron/step27_service.py")
        api=self.text("src/abutron/step27_api.py")
        self.assertIn("STEP27_BILLING_WEBHOOK_ENABLED",service)
        self.assertIn("hmac.compare_digest",service)
        self.assertIn('raise HTTPException(503, "Step27 billing webhook is disabled")',api)

    def test_admin_escapes_dynamic_data(self):
        html=self.text("admin/step27.html")
        self.assertIn("function esc(v)",html)
        self.assertIn("esc(x.user.email)",html)

    def test_install_gates_step26a_and_live_safety(self):
        ps=self.text("scripts/install_step27.ps1")
        self.assertIn("STEP27_GATE_STEP26A=PASS",ps)
        self.assertIn("LIVE_MONEY_AUTHORIZED=true",ps)
        self.assertIn("STEP27_NO_EXECUTION_REFERENCE=PASS",ps)

    def test_cert_requires_live_openapi(self):
        ps=self.text("scripts/certify_step27.ps1")
        self.assertIn("STEP27_LIVE_OPENAPI=PASS",ps)
        self.assertIn("STEP27_BILLING_WEBHOOK_FAIL_CLOSED=PASS",ps)
        self.assertIn("STEP27=PASS",ps)


if __name__=="__main__":
    unittest.main()
