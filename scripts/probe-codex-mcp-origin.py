"""Bounded read-only Codex runtime MCP origin observation; never resumes or sends turns."""
import argparse, asyncio, json, os, stat, subprocess, sys
from pathlib import Path
import websockets

def start(pid):
    result = subprocess.run(['/bin/ps','-p',str(pid),'-o','lstart='], env=dict(os.environ,TZ='UTC',LC_ALL='C'), capture_output=True,text=True,timeout=3)
    if result.returncode or not result.stdout.strip():
        raise ValueError('process unavailable')
    return result.stdout.strip()

def kernel(args):
    if start(args.frontend_pid) != args.frontend_start or start(args.daemon_pid) != args.daemon_start:
        raise ValueError('process incarnation changed')
    info = os.lstat(args.socket)
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError('native socket ownership/type mismatch')
    result = subprocess.run(['/usr/sbin/lsof','-nP','-a','-p',str(args.daemon_pid),'-U','-Fn'],capture_output=True,text=True,timeout=5)
    if result.returncode or 'n'+args.socket not in result.stdout.splitlines():
        raise ValueError('socket is not owned by pinned daemon')
    result = subprocess.run(['/usr/sbin/lsof','-nP','-a','-p',str(args.frontend_pid),'-iTCP','-sTCP:LISTEN','-Fn'],capture_output=True,text=True,timeout=5)
    expected = 'n127.0.0.1:'+str(args.port)
    if result.returncode or expected not in result.stdout.splitlines():
        raise ValueError('frontend no longer owns loopback listener')
    return (info.st_dev,info.st_ino)

async def main(args):
    before = kernel(args)
    async with websockets.unix_connect(args.socket,compression=None,max_size=1048576,open_timeout=5,close_timeout=2) as ws:
        sequence = 0
        async def rpc(method,params):
            nonlocal sequence
            if method not in ('initialize','thread/loaded/list','mcpServerStatus/list'):
                raise ValueError('method outside read-only allowlist')
            sequence += 1
            await ws.send(json.dumps(dict(id=sequence,method=method,params=params)))
            for _ in range(4096):
                reply=json.loads(await asyncio.wait_for(ws.recv(),15))
                if reply.get('id') == sequence:
                    if 'error' in reply:
                        raise ValueError('native RPC '+method+' failed: '+json.dumps(reply['error'])[:300])
                    return reply['result']
            raise ValueError('notification limit exceeded')
        initialized = await rpc('initialize',dict(clientInfo=dict(name='relay_readonly_binding_observer',title='Relay read-only binding observer',version='0.1'),capabilities=dict(experimentalApi=True)))
        await ws.send(json.dumps(dict(method='initialized',params={})))
        async def snapshot():
            cursor=None
            ids=[]
            for _ in range(8):
                page=await rpc('thread/loaded/list',dict(limit=100,cursor=cursor))
                ids.extend(page.get('data',[]))
                if len(ids)>512 or len(ids)!=len(set(ids)):
                    raise ValueError('loaded-thread limit/duplicate')
                cursor=page.get('nextCursor')
                if not cursor:
                    break
            else:
                raise ValueError('loaded-thread pagination limit')
            rows=[]
            for tid in ids:
                status=await rpc('mcpServerStatus/list',dict(threadId=tid,serverName='codex_tui',detail='toolsAndAuthOnly',limit=100))
                if status.get('nextCursor'):
                    raise ValueError('server status pagination unexpected')
                for server in status.get('data',[]):
                    if server.get('name')=='codex_tui':
                        rows.append(dict(thread_id=tid,http_origin=server.get('httpOrigin'),runtime_status=server.get('runtimeStatus')))
            return dict(loaded_count=len(ids),rows=rows)
        first=await snapshot()
        second=await snapshot()
    after=kernel(args)
    if before!=after or first!=second:
        raise ValueError('kernel/runtime state changed during observation')
    origin='http://127.0.0.1:'+str(args.port)
    matches=[r for r in second['rows'] if r['http_origin']==origin]
    result=dict(observation='native_runtime_mcp_origin',frontend_pid=args.frontend_pid,frontend_start=args.frontend_start,daemon_pid=args.daemon_pid,daemon_start=args.daemon_start,listener_origin=origin,loaded_count=second['loaded_count'],matching_threads=matches,all_runtime_origins=second['rows'],binding_claim=False)
    print(json.dumps(result,sort_keys=True))

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket',required=True)
    parser.add_argument('--frontend-pid',type=int,required=True)
    parser.add_argument('--frontend-start',required=True)
    parser.add_argument('--daemon-pid',type=int,required=True)
    parser.add_argument('--daemon-start',required=True)
    parser.add_argument('--port',type=int,required=True)
    args=parser.parse_args()
    try:
        asyncio.run(asyncio.wait_for(main(args),90))
    except Exception as error:
        print(json.dumps(dict(observation='unavailable',reason=str(error)[:500],binding_claim=False)),file=sys.stderr)
        sys.exit(1)
