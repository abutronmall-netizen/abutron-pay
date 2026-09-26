from pathlib import Path
import sys, math
import numpy as np
import pandas as pd
from abutron.config import settings
from abutron.models import MarketSnapshot, KronosSignal, Direction

TF_MINUTES={"M1":1,"M5":5,"M15":15,"M30":30,"H1":60,"H4":240,"D1":1440}

class KronosRuntime:
    def __init__(self):
        self.predictor=None
        self.device="unloaded"
        self.model_version=settings.kronos_model

    def _load(self):
        if self.predictor is not None: return
        repo=Path(settings.kronos_repo).resolve()
        if not (repo/"model").exists():
            raise RuntimeError(f"Kronos source not found at {repo}. Run scripts/fetch_kronos.ps1")
        sys.path.insert(0,str(repo))
        from model import Kronos,KronosTokenizer,KronosPredictor
        device=settings.kronos_device
        if device=="auto":
            import torch
            device="cuda:0" if torch.cuda.is_available() else "cpu"
        tokenizer=KronosTokenizer.from_pretrained(settings.kronos_tokenizer)
        model=Kronos.from_pretrained(settings.kronos_model)
        self.predictor=KronosPredictor(model,tokenizer,device=device,max_context=settings.kronos_max_context)
        self.device=device

    def predict(self,snapshot:MarketSnapshot)->KronosSignal:
        self._load()
        context_bars=max(64, settings.kronos_max_context-settings.kronos_pred_len)
        bars=snapshot.candles[-context_bars:]
        if len(bars)<64: raise ValueError("Kronos requires at least 64 bars")
        ts=pd.to_datetime([x.ts for x in bars],unit="s",utc=True).tz_convert(None)
        df=pd.DataFrame({"open":[x.open for x in bars],"high":[x.high for x in bars],
                         "low":[x.low for x in bars],"close":[x.close for x in bars],
                         "volume":[x.volume for x in bars],"amount":[0.0 for _ in bars]})
        step=TF_MINUTES.get(snapshot.timeframe.upper())
        if step is None: raise ValueError(f"Unsupported timeframe {snapshot.timeframe}")
        y=pd.Series(pd.date_range(ts[-1]+pd.Timedelta(minutes=step),periods=settings.kronos_pred_len,freq=f"{step}min"))
        pred=self.predictor.predict(df=df,x_timestamp=pd.Series(ts),y_timestamp=y,
            pred_len=settings.kronos_pred_len,T=1.0,top_p=0.9,
            sample_count=settings.kronos_sample_count,verbose=False)
        current=float(df["close"].iloc[-1]); predicted=float(pred["close"].iloc[-1])
        expected=(predicted/current)-1.0
        ret=np.diff(np.log(np.maximum(df["close"].tail(80).to_numpy(),1e-12)))
        vol=float(np.std(ret))*math.sqrt(max(settings.kronos_pred_len,1))
        z=expected/max(vol,1e-6)
        score=float(np.tanh(z*0.80))
        direction=Direction.HOLD if abs(score)<0.08 else (Direction.BUY if score>0 else Direction.SELL)
        return KronosSignal(score=score,direction=direction,expected_return=expected,
            normalized_move=float(z),predicted_close=predicted,
            model_version=self.model_version,device=self.device)
