from pathlib import Path
import ast
import json
import re
import unittest

ROOT=Path(__file__).resolve().parents[1]

class Step26APackageTests(unittest.TestCase):
    def test_python_syntax(self):
        for p in (ROOT/"src"/"abutron").glob("step26a_*.py"):
            ast.parse(p.read_text(encoding="utf-8"))

    def test_required_routes_present(self):
        s=(ROOT/"src"/"abutron"/"step26a_api.py").read_text(encoding="utf-8")
        for route in [
            "/v1/mobile/bootstrap",
            "/v1/customer/status",
            "/v1/customer/profile",
            "/v1/customer/accounts",
            "/v1/customer/trades",
            "/v1/devices/register",
            "/v1/notifications",
            "/v1/support/tickets",
            "/v1/admin/customers/{user_id}",
            "/v1/admin/support/tickets",
            "/v1/admin/step26a/summary",
            "/admin/step26a",
        ]:
            self.assertIn(route,s)

    def test_read_only_mobile_contract(self):
        s=(ROOT/"src"/"abutron"/"step26a_api.py").read_text(encoding="utf-8")
        self.assertIn('"mobile_trading_mode": "READ_ONLY"',s)
        self.assertIn('"order_entry": False',s)

    def test_no_execution_hooks(self):
        merged="\n".join(
            p.read_text(encoding="utf-8")
            for p in (ROOT/"src"/"abutron").glob("step26a_*.py")
        )
        for token in ["order_send","gateway.order","MT5Gateway","execute=True"]:
            self.assertNotIn(token,merged)

    def test_mobile_has_no_order_ui(self):
        s=(ROOT/"mobile"/"AbutronMobile"/"App.tsx").read_text(encoding="utf-8")
        self.assertNotIn("Place Order",s)
        self.assertNotIn("/v1/order",s)
        self.assertIn("data.platform.mobile_trading_mode",s)

    def test_package_versions(self):
        pkg=json.loads((ROOT/"mobile"/"AbutronMobile"/"package.json").read_text())
        self.assertEqual(pkg["dependencies"]["expo"],"~57.0.0")
        self.assertEqual(pkg["dependencies"]["react-native"],"0.86.0")
        self.assertEqual(pkg["dependencies"]["expo-secure-store"],"57.0.4")

    def test_admin_escapes_user_data(self):
        s=(ROOT/"admin"/"step26a.html").read_text(encoding="utf-8")
        self.assertIn("function esc",s)
        self.assertIn("/v1/admin/support/tickets",s)

if __name__=="__main__":
    unittest.main()
