from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
def text(p): return (ROOT/p).read_text(encoding='utf-8')
def test_safety_defaults():
    e=text('.env.example')
    for x in ['CTRADER_ENABLE_LIVE_CONNECTION=false','CTRADER_DEMO_EXECUTION_ENABLED=false','CTRADER_LIVE_MONEY_AUTHORIZED=false','CTRADER_KILL_SWITCH=true']: assert x in e
def test_persistent_workers_and_no_per_order_subprocess():
    m=text('ctrader_gateway/worker_manager.py'); a=text('ctrader_gateway/app.py')
    assert 'PersistentWorker' in m and "self.workers['DEMO']" in m
    assert 'subprocess.run' not in a
def test_atomic_idempotency_and_uncertain_state():
    s=text('ctrader_gateway/store.py'); assert 'BEGIN IMMEDIATE' in s and 'UNCERTAIN' in s and 'reserve_idempotency' in s
def test_oauth_and_encryption():
    o=text('ctrader_gateway/oauth.py'); c=text('ctrader_gateway/crypto.py')
    assert "grant_type':'authorization_code" in o and 'refresh_token' in o and 'Fernet' in c
def test_dedicated_venv():
    i=text('scripts/install_windows.ps1'); assert ".venv_ctrader" in i and ".venv\\Scripts" not in i
def test_protocol_volume_not_lots_hidden_conversion():
    m=text('ctrader_gateway/models.py'); assert 'protocol_volume' in m

def test_public_proxy_does_not_expose_internal_trading_routes():
    c=text('deployment/caddy/Caddyfile.snippet')
    assert 'oauth/start' in c and 'oauth/callback' in c
    assert 'handle_path' not in c
    assert 'orders/market' not in c

def test_volume_conversion_floors_and_never_forces_minimum():
    import importlib.util
    p=ROOT/'core_integration/volume.py'
    spec=importlib.util.spec_from_file_location('volmod',p); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    assert m.lots_to_protocol_volume(0.01,lot_size_cents=10_000_000,min_volume=1000,step_volume=1000)==100_000
    try:
        m.lots_to_protocol_volume(0.00001,lot_size_cents=10_000_000,min_volume=1000,step_volume=1000)
    except ValueError as e:
        assert str(e)=='MIN_VOLUME_EXCEEDS_RISK_BUDGET'
    else:
        raise AssertionError('Expected minimum-volume risk rejection')

def test_ic_markets_allowlist_and_manual_position_protection():
    a=text('ctrader_gateway/app.py'); e=text('.env.example')
    assert 'CTRADER_ALLOWED_BROKER_MARKERS=ICMARKETS,RAWTRADING' in e
    assert 'CTRADER_ACCOUNT_REJECTED_NON_IC' in a
    assert 'POSITION_NOT_ABUTRON_MANAGED' in a
    assert 'MANUAL_POSITION_CONFLICT' in a

def test_oauth_errors_do_not_echo_token_request_url():
    o=text('ctrader_gateway/oauth.py'); a=text('ctrader_gateway/app.py')
    assert 'CTRADER_TOKEN_HTTP_FAILED' in o
    assert "HTTPException(400,'CTRADER_OAUTH_CALLBACK_FAILED')" in a

def test_installer_copies_complete_target_before_core_adapter():
    i=text('scripts/install_windows.ps1')
    assert "'core_integration'" in i
    assert "'.env.example'" in i
    assert 'INSTALLED_ARTIFACT_MISSING' in i
    assert 'Validate the INSTALLED target before touching the Abutron core adapter.' in i
    assert i.index('& $Python -m pytest -q tests') < i.index("$CoreGatewayDir=Join-Path $Root 'abutron\\gateways'")


def test_step21b_zero_order_discovery_contract():
    a=text('ctrader_gateway/app.py')
    assert "'zero_order':True" in a
    assert "STEP21B_REQUIRES_DEMO_ACCOUNT" in a
    assert "CURRENCY_CONVERSION_REQUIRED" in a
    assert "STEP21B_DISCOVERY_PASS" in a

def test_step21b_worker_read_actions():
    w=text('ctrader_gateway/persistent_worker.py')
    assert 'ProtoOAAssetListReq' in w
    assert 'ProtoOAGetPositionUnrealizedPnLReq' in w
    assert "action=='assets'" in w and "action=='pnl'" in w

def test_step21b_customer_routes_bind_authenticated_user():
    r=text('core_integration/ctrader_routes.py')
    assert 'Depends(current_user)' in r
    assert "prefix='/v1/broker/ic-markets'" in r
    assert 'user_id' not in ''.join(line for line in r.splitlines() if line.strip().startswith('async def connect_ic_markets'))

def test_step21b_no_order_in_certification_script():
    c=text('scripts/step21b_certify.ps1').lower()
    assert '/orders/' not in c
    assert '/positions/close' not in c
    assert 'broker_order_sent=false' in c

def test_step21b_usd_router_boundaries():
    import importlib.util
    p=ROOT/'ctrader_gateway/app.py'
    # Static contract only; importing app would start settings against local env.
    a=p.read_text(encoding='utf-8')
    assert "20 <= equity <= 3000" in a
    assert "3000 < equity <= 5000" in a
    assert "5000 < equity <= 10000" in a

def test_step21b_installer_validates_core_from_project_root():
    i=text('scripts/install_step21b.ps1')
    marker='# Critical v1.1.1 fix: validate the Core from its real project working directory.'
    assert marker in i
    block=i[i.index(marker):]
    assert 'Push-Location $Root' in block
    assert "assert os.getcwd()==r'$Root'" in block
    assert 'from abutron.api import app' in block
    assert 'STEP21B_CORE_IMPORT_FAIL' in block

def test_step21b_installer_has_rollback_and_execution_path_guard():
    i=text('scripts/install_step21b.ps1')
    assert 'function Restore-Step21BBackup' in i
    assert "Write-Host 'STEP21B_ROLLBACK=PASS'" in i
    assert "from abutron\\.gateways\\.mt5 import MT5Gateway" in i
    assert "self\\.gateway\\s*=\\s*MT5Gateway\\(\\)" in i
    assert "Kronos_TradingService_EXECUTION_PATH_CHANGED=False" in i


def test_step21b_v112_route_verification_emits_real_lines():
    i=text('scripts/install_step21b.ps1')
    assert 'v1.1.2: emit one route per stdout line' in i
    assert "[print(r.path) for r in sorted(app.routes,key=lambda r:r.path)]" in i
    assert "$routes=@($routes | ForEach-Object" in i
    # Regression: v1.1.1 joined paths with a literal backslash-n, so -contains saw one item.
    assert "print('\\n'.join" not in i
