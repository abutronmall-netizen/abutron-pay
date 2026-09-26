import re

ALIASES={
    "XAUUSD":("XAUUSD","XAUUSDR","XAUUSDm","XAUUSD.a","GOLD","GOLDUSD"),
    "BTCUSD":("BTCUSD","BTCUSDR","BTCUSDm","BTCUSD.a"),
    "EURUSD":("EURUSD","EURUSDR","EURUSDm","EURUSD.a"),
    "GBPUSD":("GBPUSD","GBPUSDR","GBPUSDm","GBPUSD.a"),
    "USDJPY":("USDJPY","USDJPYR","USDJPYm","USDJPY.a"),
    "US100":("US100","NAS100","USTEC","NASDAQ100"),
    "US30":("US30","DJ30","DJI30","WS30"),
    "SP500":("SP500","US500","SPX500","SPX"),
    "GER40":("GER40","DE40","DAX40","GERMANY40"),
    "USOIL":("USOIL","WTI","XTIUSD","WTICOUSD"),
}

def _clean(x:str)->str:
    return re.sub(r"[^A-Z0-9]","",x.upper())

def normalize_symbol(raw:str)->str:
    x=_clean(raw)
    for canonical,aliases in ALIASES.items():
        for alias in aliases:
            a=_clean(alias)
            if x==a or x.startswith(a):
                return canonical
    raise ValueError(f"Unsupported symbol: {raw}")
