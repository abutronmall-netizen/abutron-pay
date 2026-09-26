from __future__ import annotations
import json, urllib.request, urllib.error

class RC108Source:
    def __init__(self,base_url:str,token:str):
        self.base_url=base_url.rstrip("/")
        self.token=token

    def _get(self,path:str):
        req=urllib.request.Request(self.base_url+path,headers={"Authorization":f"Bearer {self.token}"})
        with urllib.request.urlopen(req,timeout=10) as r:
            return json.loads(r.read().decode("utf-8"))

    def health(self):
        with urllib.request.urlopen(self.base_url+"/health",timeout=10) as r:
            return json.loads(r.read().decode("utf-8"))

    def incidents(self):
        return self._get("/incidents")

    def approvals(self):
        return self._get("/approvals")
