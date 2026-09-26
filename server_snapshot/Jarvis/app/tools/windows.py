import psutil,subprocess
from app.core.settings import settings
def resources():return {"cpu":psutil.cpu_percent(.25),"memory":psutil.virtual_memory().percent,"disk":psutil.disk_usage("C:\\").percent}
def processes(name):
 return [{"pid":p.info["pid"],"name":p.info["name"],"status":p.info["status"]} for p in psutil.process_iter(["pid","name","status"]) if (p.info.get("name") or "").lower()==name.lower()]
def service(name):
 c=subprocess.run(["sc.exe","query",name],capture_output=True,text=True,timeout=10);return {"code":c.returncode,"stdout":c.stdout[-5000:]}
def mt5():return processes(settings.mt5_process_name)
