"""One long-lived cTrader Open API process for exactly one environment.

Protocol: newline-delimited JSON over stdin/stdout. The parent gateway serializes requests
per worker. This process keeps the Spotware TCP/TLS connection alive and performs app auth once.
"""
from __future__ import annotations
import json,os,sys,threading,time,traceback
from google.protobuf.json_format import MessageToDict

ENV=os.environ.get('CTRADER_WORKER_ENV','DEMO').upper()
CLIENT_ID=os.environ.get('CTRADER_CLIENT_ID','')
CLIENT_SECRET=os.environ.get('CTRADER_CLIENT_SECRET','')

_out_lock=threading.Lock()
def emit(obj):
    with _out_lock:
        sys.stdout.write(json.dumps(obj,separators=(',',':'))+'\n'); sys.stdout.flush()

def main():
    try:
        from ctrader_open_api import Client,Protobuf,TcpProtocol,EndPoints
        from ctrader_open_api.messages.OpenApiCommonMessages_pb2 import ProtoHeartbeatEvent
        from ctrader_open_api.messages.OpenApiMessages_pb2 import (
            ProtoOAApplicationAuthReq,ProtoOAGetAccountListByAccessTokenReq,ProtoOAAccountAuthReq,
            ProtoOATraderReq,ProtoOAReconcileReq,ProtoOASymbolsListReq,ProtoOASymbolByIdReq,
            ProtoOAAssetListReq,ProtoOAGetPositionUnrealizedPnLReq,ProtoOANewOrderReq,ProtoOAClosePositionReq,ProtoOAAmendPositionSLTPReq,
            ProtoOASubscribeSpotsReq,ProtoOASpotEvent,ProtoOADealListReq,
        )
        from ctrader_open_api.messages.OpenApiModelMessages_pb2 import ProtoOAOrderType,ProtoOATradeSide
        from twisted.internet import reactor
        from twisted.internet.task import LoopingCall
    except Exception as exc:
        emit({'type':'fatal','ok':False,'error':'CTRADER_SDK_IMPORT_FAILED','detail':str(exc)}); return 2
    if ENV not in {'DEMO','LIVE'} or not CLIENT_ID or not CLIENT_SECRET:
        emit({'type':'fatal','ok':False,'error':'WORKER_CONFIG_INVALID'}); return 2

    host=EndPoints.PROTOBUF_DEMO_HOST if ENV=='DEMO' else EndPoints.PROTOBUF_LIVE_HOST
    client=Client(host,EndPoints.PROTOBUF_PORT,TcpProtocol,numberOfMessagesToSendPerSecond=10)
    state={'connected':False,'app_authorized':False,'last_connected':None,'last_message':None}
    spot_cache={}  # (account_id,symbol_id) -> bid/ask/timestamp values in actual prices

    def typed_dict(raw):
        typed=Protobuf.extract(raw)
        return MessageToDict(typed,preserving_proto_field_name=True)

    def error_text(failure):
        try: return failure.getErrorMessage()
        except Exception: return str(failure)

    def send_response(req_id, ok, **payload): emit({'type':'response','request_id':req_id,'ok':ok,'environment':ENV,**payload})

    def on_connected(_client):
        state.update(connected=True,app_authorized=False,last_connected=int(time.time()))
        req=ProtoOAApplicationAuthReq(clientId=CLIENT_ID,clientSecret=CLIENT_SECRET)
        d=client.send(req,responseTimeoutInSeconds=10)
        def good(raw):
            state['app_authorized']=True
            emit({'type':'status','ok':True,'event':'APP_AUTHORIZED','environment':ENV})
            return raw
        def bad(f):
            state['app_authorized']=False
            emit({'type':'status','ok':False,'event':'APP_AUTH_FAILED','environment':ENV,'detail':error_text(f)})
            return f
        d.addCallbacks(good,bad)

    def on_disconnected(_client,reason):
        state.update(connected=False,app_authorized=False)
        emit({'type':'status','ok':False,'event':'DISCONNECTED','environment':ENV,'detail':str(reason)})

    def on_message(_client,message):
        state['last_message']=int(time.time())
        try:
            typed=Protobuf.extract(message)
            if isinstance(typed,ProtoOASpotEvent):
                key=(int(typed.ctidTraderAccountId),int(typed.symbolId))
                old=spot_cache.get(key,{})
                bid=(float(typed.bid)/100000.0) if typed.HasField('bid') else old.get('bid')
                ask=(float(typed.ask)/100000.0) if typed.HasField('ask') else old.get('ask')
                spot_cache[key]={'bid':bid,'ask':ask,'timestamp_ms':int(getattr(typed,'timestamp',0) or int(time.time()*1000)),'received_at':int(time.time())}
        except Exception:
            pass
    client.setConnectedCallback(on_connected); client.setDisconnectedCallback(on_disconnected); client.setMessageReceivedCallback(on_message)

    def heartbeat():
        if not state['connected'] or not state['app_authorized']: return
        d=client.send(ProtoHeartbeatEvent(),responseTimeoutInSeconds=4)
        d.addErrback(lambda _f: None)

    def after_account_auth(req_id, cmd):
        action=cmd['action']; aid=int(cmd['account_id'])
        if action=='trader': req=ProtoOATraderReq(ctidTraderAccountId=aid)
        elif action=='reconcile': req=ProtoOAReconcileReq(ctidTraderAccountId=aid,returnProtectionOrders=True)
        elif action=='symbols': req=ProtoOASymbolsListReq(ctidTraderAccountId=aid,includeArchivedSymbols=False)
        elif action=='assets': req=ProtoOAAssetListReq(ctidTraderAccountId=aid)
        elif action=='pnl': req=ProtoOAGetPositionUnrealizedPnLReq(ctidTraderAccountId=aid)
        elif action=='symbol-details':
            req=ProtoOASymbolByIdReq(ctidTraderAccountId=aid); req.symbolId.append(int(cmd['symbol_id']))
        elif action=='subscribe-spots':
            req=ProtoOASubscribeSpotsReq(ctidTraderAccountId=aid,subscribeToSpotTimestamp=True); req.symbolId.append(int(cmd['symbol_id']))
        elif action=='spot-snapshot':
            q=spot_cache.get((aid,int(cmd['symbol_id'])))
            if not q: send_response(req_id,False,error='SPOT_NOT_AVAILABLE'); return
            send_response(req_id,True,response={'spot':q}); return
        elif action=='deal-list':
            req=ProtoOADealListReq(ctidTraderAccountId=aid,fromTimestamp=int(cmd['from_timestamp']),toTimestamp=int(cmd['to_timestamp']),maxRows=int(cmd.get('max_rows',500)))
        elif action=='market-order':
            req=ProtoOANewOrderReq(ctidTraderAccountId=aid,symbolId=int(cmd['symbol_id']),
                orderType=ProtoOAOrderType.Value('MARKET'),tradeSide=ProtoOATradeSide.Value(str(cmd['side']).upper()),volume=int(cmd['protocol_volume']))
            req.label='ABUTRON'; req.comment='ABUTRON_KRONOS_CLOUD'
            if cmd.get('relative_stop_loss') is not None: req.relativeStopLoss=int(cmd['relative_stop_loss'])
            if cmd.get('relative_take_profit') is not None: req.relativeTakeProfit=int(cmd['relative_take_profit'])
            if cmd.get('client_order_id'): req.clientOrderId=str(cmd['client_order_id'])[:50]
        elif action=='close-position':
            req=ProtoOAClosePositionReq(ctidTraderAccountId=aid,positionId=int(cmd['position_id']),volume=int(cmd['protocol_volume']))
        elif action=='amend-position':
            req=ProtoOAAmendPositionSLTPReq(ctidTraderAccountId=aid,positionId=int(cmd['position_id']))
            if cmd.get('relative_stop_loss') is not None: req.relativeStopLoss=int(cmd['relative_stop_loss'])
            if cmd.get('relative_take_profit') is not None: req.relativeTakeProfit=int(cmd['relative_take_profit'])
        else:
            send_response(req_id,False,error='UNSUPPORTED_ACTION'); return
        d=client.send(req,responseTimeoutInSeconds=12)
        d.addCallbacks(lambda raw: send_response(req_id,True,response=typed_dict(raw)),lambda f: send_response(req_id,False,error='OPEN_API_REQUEST_FAILED',detail=error_text(f)))

    def dispatch(cmd):
        req_id=str(cmd.get('request_id',''))
        if cmd.get('action')=='status': send_response(req_id,True,status=dict(state)); return
        if not state['connected'] or not state['app_authorized']:
            send_response(req_id,False,error='OPEN_API_NOT_READY',status=dict(state)); return
        action=cmd.get('action')
        if action=='accounts':
            req=ProtoOAGetAccountListByAccessTokenReq(accessToken=str(cmd['access_token']))
            d=client.send(req,responseTimeoutInSeconds=10)
            d.addCallbacks(lambda raw: send_response(req_id,True,response=typed_dict(raw)),lambda f: send_response(req_id,False,error='ACCOUNT_LIST_FAILED',detail=error_text(f)))
            return
        if not cmd.get('account_id') or not cmd.get('access_token'):
            send_response(req_id,False,error='ACCOUNT_AUTH_FIELDS_REQUIRED'); return
        auth=ProtoOAAccountAuthReq(ctidTraderAccountId=int(cmd['account_id']),accessToken=str(cmd['access_token']))
        d=client.send(auth,responseTimeoutInSeconds=10)
        d.addCallbacks(lambda _raw: after_account_auth(req_id,cmd),lambda f: send_response(req_id,False,error='ACCOUNT_AUTH_FAILED',detail=error_text(f)))

    def stdin_loop():
        for line in sys.stdin:
            line=line.strip()
            if not line: continue
            try: cmd=json.loads(line)
            except Exception as exc:
                emit({'type':'response','request_id':'','ok':False,'error':'BAD_JSON','detail':str(exc)}); continue
            reactor.callFromThread(dispatch,cmd)
        reactor.callFromThread(reactor.stop)

    threading.Thread(target=stdin_loop,name='command-reader',daemon=True).start()
    client.startService()
    LoopingCall(heartbeat).start(8.0,now=False)
    emit({'type':'status','ok':True,'event':'WORKER_STARTED','environment':ENV})
    reactor.run()
    return 0

if __name__=='__main__':
    try: raise SystemExit(main())
    except SystemExit: raise
    except Exception as exc:
        emit({'type':'fatal','ok':False,'error':'WORKER_CRASH','detail':str(exc),'trace':traceback.format_exc()[-2000:]}); raise
