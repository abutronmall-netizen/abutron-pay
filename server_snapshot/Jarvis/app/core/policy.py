from enum import Enum
from pathlib import Path
import yaml
class Decision(str,Enum): ALLOW="ALLOW"; APPROVAL="APPROVAL"; DENY="DENY"
class PolicyEngine:
 def __init__(self,path="config/policy.yaml"):
  c=yaml.safe_load(Path(path).read_text()); self.a=set(c["allow"]); self.p=set(c["approval"]); self.d=set(c["deny"])
 def decide(self,x):
  if x in self.d:return Decision.DENY
  if x in self.p:return Decision.APPROVAL
  if x in self.a:return Decision.ALLOW
  return Decision.DENY
