from pathlib import Path
import importlib
import pytest
ROOT=Path(__file__).resolve().parents[1]
def text(p): return (ROOT/p).read_text(encoding='utf-8')

def test_step21d_worker_disconnect_exits_for_clean_restart():
    w=text('ctrader_gateway/persistent_worker.py')
    assert 'reactor.callLater(0.25, reactor.stop)' in w
    assert "event':'DISCONNECTED'" in w

def test_step21d_order_history_has_client_order_id_recovery_support():
    w=text('ctrader_gateway/persistent_worker.py'); a=text('ctrader_gateway/app.py')
    assert 'ProtoOAOrderListReq' in w and "action=='order-list'" in w
    assert '_order_client_id' in a and "classification='BROKER_MUTATION_OBSERVED'" in a

def test_step21d_never_allows_automatic_uncertain_retry():
    a=text('ctrader_gateway/app.py')
    assert 'automatic_retry_allowed' in a
    assert 'retry_allowed=False' in a
    assert 'NO_BROKER_EVIDENCE_RETRY_STILL_BLOCKED' in a

def test_step21d_worker_manager_mutation_not_in_read_only_set():
    m=text('ctrader_gateway/worker_manager.py')
    assert "MUTATING_ACTIONS={'market-order','close-position','amend-position'}" in m
    block=m[m.index('READ_ONLY_ACTIONS='):m.index('MUTATING_ACTIONS=')]
    for x in ['market-order','close-position','amend-position']:
        assert x not in block
    assert 'Mutation requests are never auto-replayed' in text('ctrader_gateway/persistent_worker.py')

def test_step21d_read_only_retry_once_but_mutation_does_not_retry(monkeypatch):
    wm=importlib.import_module('ctrader_gateway.worker_manager')
    monkeypatch.setattr(wm.settings,'step21d_read_retry_enabled',True)
    monkeypatch.setattr(wm.time,'sleep',lambda _x: None)
    class Fake:
        def __init__(self): self.calls=0; self.restarts=0
        def request(self,action,**kwargs):
            self.calls+=1
            if self.calls==1: raise wm.WorkerError('CTRADER_WORKER_PIPE_CLOSED')
            return {'ok':True,'action':action}
        def restart(self): self.restarts+=1
    f=Fake(); mgr=wm.WorkerManager(); mgr.workers={'DEMO':f}
    out=mgr.request('DEMO','reconcile')
    assert out['ok'] is True and f.calls==2 and f.restarts==1
    g=Fake(); mgr.workers={'DEMO':g}
    with pytest.raises(wm.WorkerError): mgr.request('DEMO','market-order')
    assert g.calls==1 and g.restarts==0

def test_step21d_uncertain_ledger_survives_database_reopen(tmp_path,monkeypatch):
    st=importlib.import_module('ctrader_gateway.store')
    monkeypatch.setattr(st.settings,'database_path',str(tmp_path/'d.db'))
    st.init_db(); key='uncertain-12345678'
    assert st.reserve_idempotency(key,'7',99,'hash')['state']=='RESERVED'
    st.mark_uncertain(key,'transport')
    row=st.get_idempotency(key)
    assert row['status']=='UNCERTAIN'
    row2=st.get_idempotency(key)
    assert row2['idempotency_key']==key and row2['status']=='UNCERTAIN'

def test_step21d_force_refresh_never_returns_secrets():
    o=text('ctrader_gateway/oauth.py'); a=text('ctrader_gateway/app.py')
    assert 'force_refresh_access_token' in o
    fn=o[o.index('async def force_refresh_access_token'):]
    assert "'expires_at'" in fn and "'scope'" in fn
    # Returned metadata must not contain token values.
    ret=fn[fn.index("return {'refreshed'"):]
    assert "accessToken" not in ret and "refreshToken" not in ret
    endpoint=a[a.index("@app.post('/v1/ctrader/step21d/users/{user_id}/token-refresh')"):]
    assert "'secrets_returned':False" in endpoint

def test_step21d_real_cert_is_zero_order_recovery_only():
    c=text('scripts/step21d_real_recovery_cert.py').lower()
    assert '/orders/' not in c and 'market-order' not in c and 'close-position' not in c and 'amend-position' not in c
    assert 'automatic_retry_allowed' in c and 'broker_order_sent=false' in c

def test_step21d_install_and_precheck_keep_live_closed():
    for f in ['scripts/install_step21d.ps1','scripts/step21d_precheck.ps1','scripts/step21d_certify.ps1']:
        s=text(f)
        assert 'LIVE_MONEY' in s and 'LIVE_CONNECTION' in s
    e=text('.env.example')
    assert 'CTRADER_ENABLE_LIVE_CONNECTION=false' in e
    assert 'CTRADER_LIVE_MONEY_AUTHORIZED=false' in e

def test_step21d_installer_has_rollback_and_preserves_env_db():
    i=text('scripts/install_step21d.ps1')
    assert 'STEP21D_ROLLBACK=PASS' in i
    assert '$EnvBackup' in i and '$DbBackup' in i
    assert 'ctrader_gateway.db' in i

def test_step21d_recovery_is_demo_only_and_internal_auth():
    a=text('ctrader_gateway/app.py')
    start=a.index("@app.get('/v1/ctrader/step21d/users/{user_id}/accounts/{account_id}/recovery-status')")
    end=a.index("@app.post('/v1/ctrader/step21d/users/{user_id}/accounts/{account_id}/restart-worker')")
    b=a[start:end]
    assert 'internal_auth' in b and 'STEP21D_DEMO_ONLY' in b

def test_step21d_current_exposure_blocks_retry_classification():
    a=text('ctrader_gateway/app.py')
    assert "classification='ACTIVE_ABUTRON_EXPOSURE'" in a
    assert 'current_abutron_positions' in a and 'current_abutron_orders' in a

def test_step21d_docs_state_no_blind_retry():
    d=text('docs/STEP21D_ARCHITECTURE.md')
    assert 'never auto-retried' in d
    assert 'automatic_retry_allowed' in d
