from dataclasses import dataclass
from statistics import fmean
@dataclass(frozen=True,slots=True)
class StrategyStats:
    trades:int;win_rate:float;average_win:float;average_loss:float;payoff_ratio:float|None;expectancy:float;profit_factor:float|None;max_drawdown:float
def summarize(pnls):
    x=[float(v) for v in pnls]
    if not x:return StrategyStats(0,0,0,0,None,0,None,0)
    wins=[v for v in x if v>0];losses=[-v for v in x if v<0];aw=fmean(wins) if wins else 0;al=fmean(losses) if losses else 0
    eq=peak=dd=0
    for p in x:
        eq+=p;peak=max(peak,eq);dd=max(dd,peak-eq)
    return StrategyStats(len(x),len(wins)/len(x),aw,al,None if al<=0 else aw/al,fmean(x),None if sum(losses)<=0 else sum(wins)/sum(losses),dd)
