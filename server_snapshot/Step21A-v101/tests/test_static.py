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
