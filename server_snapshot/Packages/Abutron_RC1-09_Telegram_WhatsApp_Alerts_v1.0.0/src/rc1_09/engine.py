from __future__ import annotations
import time, collections
from .events import normalize_collection,incident_event,approval_event,render_plain
from .providers import ProviderError

class NotificationEngine:
    def __init__(self,settings,store,source,providers:dict):
        self.s=settings
        self.store=store
        self.source=source
        self.providers=providers
        self.cycles=0
        self.poll_failures=0
        self.delivery_failures=0
        self.last_cycle=None
        self.last_send={k:0.0 for k in providers}
        self.bursts={k:collections.deque() for k in providers}

    def channels(self)->list[str]:
        return sorted(self.providers.keys())

    def _queue(self,event):
        return self.store.create_event(event,self.channels())

    def poll_once(self):
        inc=normalize_collection(self.source.incidents())
        apr=normalize_collection(self.source.approvals())
        for i in inc:
            iid=str(i.get("id",""))
            if not iid: continue
            status=str(i.get("status","")).upper()
            sev=str(i.get("severity","INFO")).upper()
            prev=self.store.get_state("incident",iid)
            if prev is None:
                self.store.set_state("incident",iid,status)
                if status=="OPEN" and sev in self.s.severities:
                    self._queue(incident_event(i,"OPEN"))
                continue
            if prev!=status:
                self.store.set_state("incident",iid,status)
                if sev in self.s.severities and status in {"OPEN","RECOVERED"}:
                    if status=="OPEN" or prev=="OPEN":
                        self._queue(incident_event(i,status))
        for a in apr:
            aid=str(a.get("id",""))
            if not aid: continue
            status=str(a.get("status","")).upper()
            prev=self.store.get_state("approval",aid)
            if prev is None:
                self.store.set_state("approval",aid,status)
                if status=="PENDING":
                    self._queue(approval_event(a))
                continue
            if prev!=status:
                self.store.set_state("approval",aid,status)
                if status=="PENDING":
                    self._queue(approval_event(a))
        self.cycles+=1
        self.last_cycle=time.time()

    def _rate_delay(self,ch:str)->float:
        now=time.time()
        min_interval=self.s.telegram_min_interval if ch=="telegram" else self.s.whatsapp_min_interval
        d=max(0.0,min_interval-(now-self.last_send.get(ch,0.0)))
        q=self.bursts.setdefault(ch,collections.deque())
        while q and q[0] < now-self.s.burst_window_seconds:
            q.popleft()
        if len(q)>=self.s.burst_limit:
            d=max(d, max(1.0,q[0]+self.s.burst_window_seconds-now))
        return d

    def dispatch_once(self):
        for d in self.store.due_deliveries():
            ch=d["channel"]
            provider=self.providers.get(ch)
            if not provider:
                self.store.mark_retry(d["id"],"provider disabled",300,self.s.max_attempts)
                continue
            delay=self._rate_delay(ch)
            if delay>0:
                # requeue without incrementing attempt
                with self.store.con() as c:
                    c.execute("UPDATE deliveries SET next_attempt_at=?,updated_at=? WHERE id=?",
                              (time.time()+delay,time.time(),d["id"]))
                continue
            event={
                "event_key":d["event_key"],"kind":d["kind"],"severity":d["severity"],
                "title":d["title"],"body":d["body"],"reference_id":d["reference_id"],
            }
            text=render_plain(event)
            try:
                result=provider.send(text,event)
                self.store.mark_sent(d["id"],result.provider_message_id)
                now=time.time()
                self.last_send[ch]=now
                self.bursts.setdefault(ch,collections.deque()).append(now)
            except Exception as e:
                self.delivery_failures+=1
                attempts=int(d.get("attempts",0))+1
                backoffs=[15,60,300,900,1800]
                delay=backoffs[min(attempts-1,len(backoffs)-1)]
                self.store.mark_retry(d["id"],f"{type(e).__name__}: {e}",delay,self.s.max_attempts)

    def cycle(self):
        try:
            self.poll_once()
        except Exception as e:
            self.poll_failures+=1
            self.store.audit("POLL_FAILED",{"error":f"{type(e).__name__}: {e}"})
        self.dispatch_once()
