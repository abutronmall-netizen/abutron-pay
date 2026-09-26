from __future__ import annotations
import asyncio,hashlib,json
from .worker_manager import manager

def stable_hash(data:dict)->str:
    return hashlib.sha256(json.dumps(data,sort_keys=True,separators=(',',':')).encode()).hexdigest()

async def worker_request(environment:str,action:str,**kwargs)->dict:
    return await asyncio.to_thread(manager.request,environment,action,**kwargs)
