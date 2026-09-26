from abutron.symbols import normalize_symbol
def test_aliases():
    assert normalize_symbol("XAUUSDr")=="XAUUSD"
    assert normalize_symbol("EURUSD.r")=="EURUSD"
    assert normalize_symbol("NAS100")=="US100"
    assert normalize_symbol("US500.cash")=="SP500"
    assert normalize_symbol("WTI")=="USOIL"
