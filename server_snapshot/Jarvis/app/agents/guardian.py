from app.tools.kronos import health,readiness
from app.tools.windows import resources,mt5
from app.core.audit import audit
async def observe():
 o={"resources":resources(),"mt5":mt5(),"errors":[]}
 for k,fn in [("health",health),("ready",readiness)]:
  try:o[k]=await fn()
  except Exception as e:o["errors"].append(f"{k}:{e!r}")
 audit("observation",o);return o
