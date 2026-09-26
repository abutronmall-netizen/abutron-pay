from pathlib import Path
import importlib.util, json, sqlite3
ROOT=Path(__file__).resolve().parents[1]
def text(p): return (ROOT/p).read_text(encoding='utf-8')

def test_step22_caddy_public_allowlist_and_default_deny():
    c=text('deployment/caddy/Caddyfile.step22')
    for p in ['/v1/auth/register','/v1/auth/login','/v1/me','/v1/accounts','/v1/mobile/dashboard','/v1/mobile/trades','/v1/broker/ic-markets/connect','/v1/broker/ic-markets/accounts','/v1/broker/ic-markets/accounts/refresh','/v1/broker/ic-markets/accounts/*/discovery','/v1/ctrader/oauth/start*','/v1/ctrader/oauth/callback*']:
        assert p in c
    assert 'respond "Not Found" 404' in c

def test_step22_caddy_never_publicly_proxies_internal_gateway_mutations():
    c=text('deployment/caddy/Caddyfile.step22')
    for x in ['/orders/market','/positions/close','/positions/amend','step21d','token-refresh','recovery-status','/v1/broker/ic-markets/*']:
        assert x not in c
    assert 'method POST DELETE' in c and 'method GET' in c

def test_step22_security_headers_present():
    c=text('deployment/caddy/Caddyfile.step22')
    for x in ['Strict-Transport-Security','X-Content-Type-Options','X-Frame-Options','Referrer-Policy','Permissions-Policy']:
        assert x in c

def test_step22_caddy_admin_is_loopback_only():
    assert 'admin 127.0.0.1:2019' in text('deployment/caddy/Caddyfile.step22')

def test_step22_backup_uses_sqlite_online_backup_and_integrity_check():
    b=text('ops/backup_sqlite.py'); v=text('ops/verify_backup.py')
    assert 's.backup(d)' in b and 'PRAGMA integrity_check' in b and 'PRAGMA integrity_check' in v

def test_step22_backup_includes_ctrader_and_core_sqlite():
    b=text('ops/backup_sqlite.py')
    for x in ['abutron_platform.db','abutron_decisions.db','mt5_idempotency.db','ctrader_gateway.db']:
        assert x in b

def test_step22_secret_audit_never_prints_values_and_keeps_live_off():
    s=text('ops/step22_secret_audit.ps1')
    assert 'SECRET_VALUES_PRINTED=False' in s
    assert 'LIVE_MONEY_MUST_REMAIN_FALSE' in s
    assert 'Write|Modify|FullControl' in s

def test_step22_internal_ports_must_not_bind_public():
    s=text('ops/step22_service_inventory.ps1')
    for p in ['8088','8090','8091']: assert p in s
    assert 'INTERNAL_PORT_PUBLIC_BIND' in s and "'0.0.0.0','::'" in s

def test_step22_caddy_apply_requires_explicit_switch_and_validates():
    s=text('ops/apply_caddy.ps1')
    assert 'EXPLICIT_APPLY_REQUIRED' in s and 'caddy' in s.lower() and 'validate --config' in s

def test_step22_installer_preserves_env_db_and_rolls_back():
    s=text('scripts/install_step22.ps1')
    assert '$EnvBackup' in s and '$DbBackup' in s and 'STEP22_ROLLBACK=PASS' in s

def test_step22_installer_does_not_apply_tls_or_enable_live():
    s=text('scripts/install_step22.ps1')
    assert 'TLS_CONFIG_APPLIED=FALSE' in s
    assert 'LIVE_MONEY_AUTHORIZED=False' in s
    assert 'apply_caddy.ps1 -Apply' not in s

def test_step22_rc_gate_requires_real_ctrader_certifications():
    s=text('scripts/step22_release_candidate.ps1')
    for x in ['STEP21B_REAL_OAUTH_DISCOVERY','STEP21C_REAL_DEMO_LIFECYCLE','STEP21D_REAL_NETWORK_RECOVERY','certification_gate','user_id=? and ctid_account_id=? and gate=?']:
        assert x in s
    assert 'STEP22_RELEASE_CANDIDATE=BLOCKED' in s

def test_step22_monitor_checks_core_gateway_tls_disk_and_live_flag():
    s=text('ops/step22_monitor.ps1')
    for x in ['8088/health','8091/health','/healthz','DISK_FREE_GB','CTRADER_LIVE_MONEY_AUTHORIZED']:
        assert x in s

def test_step22_backup_roundtrip(tmp_path):
    src=tmp_path/'root'; (src/'data').mkdir(parents=True); (src/'ctrader_cloud_gateway'/'data').mkdir(parents=True)
    for p in [src/'data'/'abutron_platform.db',src/'ctrader_cloud_gateway'/'data'/'ctrader_gateway.db']:
        with sqlite3.connect(p) as c:
            c.execute('create table t(id integer primary key, v text)'); c.execute("insert into t(v) values('x')"); c.commit()
    modp=ROOT/'ops'/'backup_sqlite.py'; spec=importlib.util.spec_from_file_location('bkp',modp); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    out=tmp_path/'out'; out.mkdir();
    for p in [src/'data'/'abutron_platform.db',src/'ctrader_cloud_gateway'/'data'/'ctrader_gateway.db']:
        q=out/p.name; m.sqlite_backup(p,q)
        with sqlite3.connect(q) as c: assert c.execute('select count(*) from t').fetchone()[0]==1


def test_step22_real_cert_scripts_record_account_scoped_gates():
    c=text('scripts/step21c_certify.ps1'); d=text('scripts/step21d_certify.ps1'); r=text('ops/record_cert_gate.py')
    assert 'STEP21C_REAL_DEMO_LIFECYCLE' in c
    assert 'STEP21D_REAL_NETWORK_RECOVERY' in d
    assert 'on conflict(user_id,ctid_account_id,gate)' in r


def test_step22_backup_acl_is_restricted_to_system_and_admins():
    s=text('ops/step22_backup.ps1')
    assert '/inheritance:r' in s
    assert '*S-1-5-18:(OI)(CI)F' in s
    assert '*S-1-5-32-544:(OI)(CI)F' in s
    assert 'STEP22_BACKUP_ACL=PASS' in s

def test_step22_public_proxy_excludes_internal_core_routes():
    c=text('deployment/caddy/Caddyfile.step22')
    for x in ['/v1/evaluate','/v1/live/','/v1/positions','/v1/manage','/v1/close/','/v1/decisions','/v1/admin/','/admin','/docs','/openapi.json']:
        assert x not in c


def test_step22_backup_missing_ctrader_is_deferred_not_faked():
    b=text('ops/backup_sqlite.py')
    assert "CTRADER_DB_BACKUP=" in b
    assert "DEFERRED_NO_DB" in b
    assert "NO_SQLITE_DATABASES_BACKED_UP" in b
    assert "touch" not in b.lower()

def test_step22_release_candidate_requires_real_ctrader_db():
    s=text('scripts/step22_release_candidate.ps1')
    assert "CTRADER_DB=MISSING" in s and "CTRADER_DB=PRESENT" in s
    assert "Test-Path $db" in s
