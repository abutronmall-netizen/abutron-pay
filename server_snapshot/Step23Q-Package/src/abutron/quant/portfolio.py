from statistics import fmean
def correlation(a,b):
    x=[float(v) for v in a]; y=[float(v) for v in b]; n=min(len(x),len(y))
    if n<2:return 0.0
    x=x[-n:]; y=y[-n:]; mx,my=fmean(x),fmean(y)
    num=sum((u-mx)*(v-my) for u,v in zip(x,y))
    den=(sum((u-mx)**2 for u in x)*sum((v-my)**2 for v in y))**0.5
    return 0.0 if den<=1e-12 else max(-1,min(1,num/den))
def correlation_matrix(series):
    keys=list(series)
    return {a:{b:(1.0 if a==b else correlation(series[a],series[b])) for b in keys} for a in keys}
