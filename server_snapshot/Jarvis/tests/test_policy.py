from app.core.policy import PolicyEngine,Decision
p=PolicyEngine()
def test_unknown():assert p.decide("unknown")==Decision.DENY
def test_trade():assert p.decide("change_trading_strategy")==Decision.DENY
def test_restart():assert p.decide("restart_kronos_service")==Decision.APPROVAL
def test_read():assert p.decide("read_kronos_health")==Decision.ALLOW
