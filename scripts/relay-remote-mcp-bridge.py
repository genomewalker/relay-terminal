#!/usr/bin/env python3
"""Forward a remote MCP client to approved host terminal and messaging operations.
The desktop-wide credential never leaves the Mac; SSH exposes remote loopback only.
"""
import argparse, copy, hmac, http.server, json, os, re, secrets, signal, subprocess, threading, urllib.request
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--host',default='dandy-07');p.add_argument('--port',type=int,default=48473);args=p.parse_args()
private=Path.home()/'.local/share/relay/remote-mcp';private.mkdir(parents=True,exist_ok=True);os.chmod(private,0o700)
capfile=private/(args.host+'.json')
if capfile.exists(): cap=json.loads(capfile.read_text())['token']
else:
 cap=secrets.token_urlsafe(32);capfile.write_text(json.dumps({'token':cap,'port':args.port}));os.chmod(capfile,0o600)
class DesktopRejected(Exception):
 def __init__(self,status,body):self.status,self.body=status,body
def desktop(method,path,body=None,caller=None):
 token=subprocess.check_output(['/usr/bin/defaults','read','dev.relay.terminal','relay.side-panel-token.v1'],text=True,timeout=2).strip()
 headers={'x-relay-token':token,'Content-Type':'application/json'}
 if caller:headers['X-Relay-Caller-Token']=caller
 request=urllib.request.Request('http://127.0.0.1:47471'+path,data=body,method=method,headers=headers)
 try:
  with urllib.request.urlopen(request,timeout=65) as response: return response.status,response.read(8388609)
 except urllib.error.HTTPError as e: return e.code,e.read(8388609)
def state(caller=None):
 status,body=desktop('GET','/api/state',caller=caller)
 if status!=200: raise DesktopRejected(status,body)
 data=json.loads(body);allowed=set();tab_scope={}
 for session in data['sessions']:
  for tab in session['tabs']:
   panes=tab['panes']
   if panes and all(pane.get('host')==args.host and pane.get('contentKind') in ('terminal','editor') for pane in panes):
    tab_scope[str(tab['id']).lower()]={'session':str(session.get('id','')).lower()}
   tab['panes']=[pane for pane in tab['panes'] if pane.get('host')==args.host and pane.get('contentKind') in ('terminal','editor')]
   allowed.update(pane['id'].lower() for pane in tab['panes'])
  session['tabs']=[tab for tab in session['tabs'] if tab['panes']]
 data['sessions']=[session for session in data['sessions'] if session['tabs']]
 if caller:
  if not tab_scope:raise DesktopRejected(403,b'{"error":"No bound remote workspace available"}')
  tab_id=next(iter(tab_scope))
  status,body=desktop('POST','/api/workspace/context',json.dumps({'tab_id':tab_id}).encode(),caller=caller)
  if status!=200:raise DesktopRejected(status,body)
 if str(data.get('selectedPaneID','')).lower() not in allowed: data['selectedPaneID']=None
 return data,allowed,tab_scope
def saved_pair(source,target,allowed,caller=None):
 if source==target or source not in allowed:return False
 status,body=desktop('GET','/api/pane-links',caller=caller)
 if status!=200:raise DesktopRejected(status,body)
 return any(len(link.get('members',[]))==2 and
  {str(m.get('paneID','')).lower() for m in link['members']}=={source,target}
  for link in json.loads(body).get('links',[]))
receipts=set();lock=threading.Lock()
class Handler(http.server.BaseHTTPRequestHandler):
 def setup(self):
  self.request.settimeout(10)
  super().setup()
 def log_message(self,*a): pass
 def reply(self,status,body):
  if isinstance(body,str):body=body.encode()
  self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
 def handle_request(self):
  if not hmac.compare_digest(self.headers.get('x-relay-token',''),cap):return self.reply(401,'{"error":"Unauthorized"}')
  caller=self.headers.get('X-Relay-Caller-Token')
  if caller is not None and (not caller or len(caller)>200 or not re.fullmatch(r'[A-Za-z0-9_-]+',caller)):
   return self.reply(403,'{"error":"Invalid caller credential"}')
  def forward(method,path,body=None):return desktop(method,path,body,caller=caller)
  path=self.path
  try:
   data,allowed,tab_scope=state(caller);body=None
   if self.command=='GET' and path=='/api/state':return self.reply(200,json.dumps(data))
   if self.command=='GET' and path=='/api/control':pass
   elif self.command=='POST' and path in ('/api/workspace/context','/api/workspace/host-request','/api/workspace/image','/api/host/request'):
    size=int(self.headers.get('Content-Length','0'))
    if not 0<size<=4194304:return self.reply(413,'{"error":"Bounded workspace request required"}')
    body=self.rfile.read(size);proposal=json.loads(body)
    if not isinstance(proposal,dict):return self.reply(400,'{"error":"Structured workspace request required"}')
    if path=='/api/host/request':
     if proposal.get('host')!=args.host:return self.reply(403,'{"error":"Host is outside this bridge scope"}')
    elif path=='/api/workspace/context' and 'pane_id' in proposal:
     if 'tab_id' in proposal or str(proposal['pane_id']).lower() not in allowed:
      return self.reply(403,'{"error":"Pane is outside this bridge scope"}')
    elif str(proposal.get('tab_id','')).lower() not in tab_scope:
     return self.reply(403,'{"error":"Tab is outside this bridge scope"}')
    if path=='/api/workspace/context' and proposal.get('action')=='bind':
     return self.reply(403,'{"error":"Workspace binding requires desktop control"}')
   elif self.command=='POST' and path=='/api/workspace/tab-action':
    size=int(self.headers.get('Content-Length','0'))
    if size<1 or size>4096:return self.reply(413,'{"error":"Bounded request required"}')
    body=self.rfile.read(size);proposal=json.loads(body)
    source=tab_scope.get(str(proposal.get('tabID','')).lower())
    if source is None:return self.reply(403,'{"error":"Tab is outside this remote host scope"}')
    action=proposal.get('action')
    if action=='move':
     target=tab_scope.get(str(proposal.get('targetTabID','')).lower())
     if target is None or target['session']!=source['session']:
      return self.reply(403,'{"error":"Move target must be in the same scoped Relay session"}')
    elif action not in ('rename','close'):
     return self.reply(403,'{"error":"Tab action outside bridge scope"}')
   elif self.command=='POST' and path=='/api/network/remote-peers':
    size=int(self.headers.get('Content-Length','0'))
    if not 0<size<=4096:return self.reply(413,'{"error":"Bounded discovery request required"}')
    body=self.rfile.read(size);proposal=json.loads(body)
    if set(proposal)!={'host'} or proposal['host']!=args.host:
     return self.reply(403,'{"error":"Peer discovery is limited to this bridge SSH host"}')
   elif self.command=='GET' and path in ('/api/network/status','/api/network/links'):
    status,result=forward('GET',path)
    if status!=200:return self.reply(status,result)
    rows=json.loads(result)
    if not isinstance(rows,list):raise ValueError('Invalid network inventory')
    return self.reply(200,json.dumps([row for row in rows if row.get('host')==args.host]))
   elif self.command=='GET' and path=='/api/network/local-peers':
    return self.reply(403,'{"error":"Use relay_discover_remote_peers with the bridge SSH host; local discovery refers to the Mac"}')
   elif self.command=='POST' and path=='/api/network/request':
    size=int(self.headers.get('Content-Length','0'))
    if not 0<size<=4096:return self.reply(413,'{"error":"Bounded network request required"}')
    body=self.rfile.read(size);proposal=json.loads(body)
    status,result=forward('GET','/api/network/links')
    if status!=200:return self.reply(status,result)
    if not any(str(row.get('id','')).lower()==str(proposal.get('linkID','')).lower() and row.get('host')==args.host for row in json.loads(result)):
     return self.reply(403,'{"error":"Link is outside this bridge host scope"}')
   elif self.command=='GET' and re.fullmatch('/api/network/receipts/[a-fA-F0-9-]{36}',path):
    status,result=forward('GET',path)
    if status!=200:return self.reply(status,result)
    receipt=json.loads(result);link=str(receipt.get('linkID','')).lower()
    link_status,links=forward('GET','/api/network/links')
    if link_status!=200 or not any(str(row.get('id','')).lower()==link and row.get('host')==args.host for row in json.loads(links)):
     return self.reply(403,'{"error":"Network receipt is outside this bridge host scope"}')
    return self.reply(status,result)
   elif self.command=='GET' and path=='/api/pane-links':
    status,result=forward('GET',path)
    if status!=200:return self.reply(status,result)
    links=json.loads(result)['links']
    return self.reply(200,json.dumps({'links':[link for link in links if len(link.get('members',[]))==2 and any(str(m.get('paneID','')).lower() in allowed for m in link['members'])]}))
   elif self.command=='POST' and (path=='/api/pane-links' or re.fullmatch('/api/panes/[a-fA-F0-9-]{36}/message',path)):
    size=int(self.headers.get('Content-Length','0'))
    if not 0<size<=70000:return self.reply(413,'{"error":"Bounded messaging request required"}')
    body=self.rfile.read(size);proposal=json.loads(body)
    source=str(proposal.get('sourcePaneID','')).lower()
    target=str(proposal.get('paneID','')).lower() if path=='/api/pane-links' else path.split('/')[3].lower()
    if source==target or source not in allowed:
     return self.reply(403,'{"error":"Message source must be a distinct pane on this bridge host"}')
    if target not in allowed and (path=='/api/pane-links' or not saved_pair(source,target,allowed,caller)):
     return self.reply(403,'{"error":"Cross-host messages require an explicitly saved pane pair"}')
   elif self.command=='GET' and re.fullmatch('/api/pane-messages/[a-fA-F0-9-]{36}',path):
    status,result=forward('GET',path)
    if status!=200:return self.reply(status,result)
    receipt=json.loads(result)
    source=str(receipt.get('source_pane_id','')).lower();target=str(receipt.get('pane_id','')).lower()
    if not ((source in allowed and target in allowed) or saved_pair(source,target,allowed,caller)):
     return self.reply(403,'{"error":"Message receipt is outside this bridge host scope"}')
    return self.reply(status,result)
   elif self.command=='GET' and re.fullmatch('/api/input-receipts/[a-fA-F0-9-]{36}',path):
    with lock:
     if path.rsplit('/',1)[1] not in receipts:return self.reply(403,'{"error":"Receipt outside this bridge"}')
   else:
    match=re.fullmatch('/api/panes/([a-fA-F0-9-]{36})(/(viewport|editor|agent-binding|r-status|r-snapshot|input-request|input-direct|editor-selection|r-run-selection|r-run-file|r-run-project-file|editor-edit|editor-save|editor-receipt|r-authorize|r-run|r-result|r-pause))?',path)
    if not match or match[1].lower() not in allowed:return self.reply(403,'{"error":"Only this remote host terminal scope is allowed"}')
    op=match[3]
    if self.command=='GET' and op in (None,'viewport','editor','agent-binding','r-status'):pass
    elif self.command=='POST' and op in ('r-snapshot','input-request','input-direct','editor-selection','r-run-selection','r-run-file','r-run-project-file','editor-edit','editor-save','editor-receipt','r-authorize','r-run','r-result','r-pause'):
     size=int(self.headers.get('Content-Length','0'))
     if size<1 or size>70000:return self.reply(413,'{"error":"Bounded request required"}')
     body=self.rfile.read(size);proposal=json.loads(body)
     if op in ('input-request','input-direct'):
      request_id=proposal.get('requestID','')
      if not re.fullmatch('[a-fA-F0-9-]{36}',request_id):return self.reply(400,'{"error":"Request identity required"}')
      with lock:
       if len(receipts)>=512 and request_id not in receipts:return self.reply(429,'{"error":"Bridge request limit reached"}')
       receipts.add(request_id)
    else:return self.reply(403,'{"error":"Operation outside bridge scope"}')
   status,result=forward(self.command,path,body)
   if path=='/api/workspace/tab-action' and status==200:
    try:
     receipt=json.loads(result);receipt.pop('selectedTabID',None);result=json.dumps(receipt).encode()
    except Exception:return self.reply(502,'{"error":"Invalid tab action receipt"}')
   if len(result)>8388608:return self.reply(502,'{"error":"Desktop response too large"}')
   return self.reply(status,result)
  except DesktopRejected as error:return self.reply(error.status,error.body)
  except Exception:return self.reply(503,'{"error":"Bridge unavailable; inspect receipt before retrying an execution"}')
 do_GET=handle_request
 do_POST=handle_request
server=http.server.ThreadingHTTPServer(('127.0.0.1',args.port),Handler)
server.daemon_threads=False
def shutdown(signum,frame):
 threading.Thread(target=server.shutdown,daemon=True).start()
signal.signal(signal.SIGTERM,shutdown)
signal.signal(signal.SIGINT,shutdown)
print('Scoped remote MCP bridge listening on loopback',args.port,flush=True)
try:server.serve_forever()
finally:server.server_close()
