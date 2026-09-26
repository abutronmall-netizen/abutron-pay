from enum import Enum
class Stage(str,Enum):DETECTED="DETECTED";EVIDENCE="EVIDENCE";RCA="RCA";PLAN="PLAN";APPROVAL="APPROVAL";EXECUTE="EXECUTE";VERIFY="VERIFY";CLOSED="CLOSED"
# Persist before/after every side effect. Temporal/DBOS adapter plugs in here.
