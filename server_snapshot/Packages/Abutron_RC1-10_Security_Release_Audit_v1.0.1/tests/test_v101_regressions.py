import pathlib, unittest, re
ROOT=pathlib.Path(__file__).resolve().parents[1]

class V101Regression(unittest.TestCase):
    def test_acl_regex_has_escaped_windows_backslash(self):
        t=(ROOT/"scripts/Apply-RC1-10-SafeHardening.ps1").read_text(encoding="utf-8-sig")
        self.assertIn(r"BUILTIN\\Users", t)
        self.assertNotIn(r"BUILTIN\Users|Authenticated", t.replace(r"BUILTIN\\Users|Authenticated",""))

    def test_acl_backup_written_before_set_acl(self):
        t=(ROOT/"scripts/Apply-RC1-10-SafeHardening.ps1").read_text(encoding="utf-8-sig")
        self.assertLess(t.index("Write-RC10Json -Path $aclBackupPath"), t.index("Set-Acl -Path $path"))

    def test_dpapi_assembly_and_probe(self):
        t=(ROOT/"lib/RC1-10.Common.ps1").read_text(encoding="utf-8-sig")
        self.assertIn("Add-Type -AssemblyName System.Security",t)
        self.assertIn("Assert-RC10DpapiAvailable",t)
        self.assertIn("ABUTRON_RC1_10_DPAPI_PROBE",t)

    def test_quarantine_probes_before_removal(self):
        t=(ROOT/"scripts/Quarantine-RC1-10-LegacySecretCopies.ps1").read_text(encoding="utf-8-sig")
        self.assertLess(t.index("Assert-RC10DpapiAvailable"),t.index("Remove-Item $f.FullName"))
        self.assertLess(t.index("DPAPI verification mismatch"),t.index("Remove-Item $f.FullName"))

    def test_repair_has_parser_gate(self):
        t=(ROOT/"scripts/Repair-RC1-10-v1.0.1.ps1").read_text(encoding="utf-8-sig")
        self.assertIn("Language.Parser",t)
        self.assertIn("RC1_10_REPAIR_V1_0_1=PASS",t)

if __name__=="__main__":
    unittest.main()
