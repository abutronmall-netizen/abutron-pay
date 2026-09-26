import json, pathlib, re, unittest

ROOT=pathlib.Path(__file__).resolve().parents[1]

class PackageTests(unittest.TestCase):
    def test_policy_json(self):
        p=json.loads((ROOT/"config/rc1_10_policy.json").read_text())
        self.assertEqual(p["version"],"1.0.0")
        self.assertIn(8088,p["sensitive_loopback_ports"])
        self.assertIn(8789,p["sensitive_loopback_ports"])
        self.assertTrue(p["require_rdp_nla"])
        self.assertGreaterEqual(p["rdp_stability_hours"],8)

    def test_required_scripts_exist(self):
        names=[
            "Install-RC1-10-v1.0.0.ps1",
            "Apply-RC1-10-SafeHardening.ps1",
            "Set-RC1-10-ReleaseAttestation.ps1",
            "Quarantine-RC1-10-LegacySecretCopies.ps1",
            "Set-RC1-10-RdpStabilityAttestation.ps1",
            "Invoke-RC1-10-PreflightAudit.ps1",
            "Test-RC1-10-Secrets.ps1",
            "Test-RC1-10-NetworkTLS.ps1",
            "Test-RC1-10-RDP.ps1",
            "Test-RC1-10-BackupRestore.ps1",
            "New-RC1-10-IntegrityBaseline.ps1",
            "Test-RC1-10-IntegrityBaseline.ps1",
            "Certify-RC1-10-PreReboot.ps1",
            "Certify-RC1-10-PostReboot.ps1",
            "Certify-RC1-10-Final.ps1",
        ]
        for n in names:
            self.assertTrue((ROOT/"scripts"/n).exists(), n)

    def test_no_trade_enable_commands(self):
        text="\n".join(p.read_text(errors="ignore") for p in ROOT.rglob("*.ps1"))
        forbidden=[
            r"ABUTRON_EXECUTION_ENABLED\s*=\s*true",
            r"MT5_LIVE_TRADING\s*=\s*true",
            r"execution_enabled\s*=\s*true",
            r"live_trading\s*=\s*true",
        ]
        for x in forbidden:
            self.assertIsNone(re.search(x,text,re.I),x)

    def test_no_firewall_disable(self):
        text="\n".join(p.read_text(errors="ignore") for p in ROOT.rglob("*.ps1"))
        self.assertNotIn("Set-NetFirewallProfile -Enabled False",text)
        self.assertNotIn("Disable-NetFirewallRule",text)

    def test_no_rdp_disable_or_port_change(self):
        text="\n".join(p.read_text(errors="ignore") for p in ROOT.rglob("*.ps1"))
        self.assertNotRegex(text,r"fDenyTSConnections[^\\n]*(?:=|Value)\\s*1")
        self.assertNotRegex(text,r"PortNumber[^\\n]*(?:Set-ItemProperty|New-ItemProperty)")

    def test_no_caddy_apply_or_reload(self):
        # RC1-10 validates Caddy but does not edit/reload routes.
        text="\n".join(p.read_text(errors="ignore") for p in ROOT.rglob("*.ps1"))
        self.assertNotIn("caddy.exe reload",text.lower())

    def test_secret_values_not_printed(self):
        text="\n".join(p.read_text(errors="ignore") for p in ROOT.rglob("*.ps1"))
        self.assertNotRegex(text,r"Write-Host[^\\n]*(client_secret|bot_token|access_token)\\s*=")

    def test_final_cert_requires_stability(self):
        t=(ROOT/"scripts/Certify-RC1-10-Final.ps1").read_text()
        self.assertIn("RDP_OVERNIGHT_GATE_NOT_MATURE",t)
        self.assertIn("RC1_10_CERTIFIED=True",t)
        self.assertIn("rdp_stability_attestation.json",t)

    def test_integrity_uses_dpapi_hmac(self):
        c=(ROOT/"lib/RC1-10.Common.ps1").read_text()
        n=(ROOT/"scripts/New-RC1-10-IntegrityBaseline.ps1").read_text()
        self.assertIn("ProtectedData",c)
        self.assertIn("HMACSHA256",n)

    def test_backup_restore_mentions_quick_check(self):
        t=(ROOT/"scripts/Test-RC1-10-BackupRestore.ps1").read_text()
        self.assertIn("PRAGMA quick_check",t)
        self.assertIn("DPAPI_SQLITE",t)

if __name__=="__main__":
    unittest.main()
