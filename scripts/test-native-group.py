import importlib.util
import json
import hashlib
from pathlib import Path
import socket
import tempfile
import unittest
import uuid
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('native',Path(__file__).with_name('relay-native-group.py'))
native=importlib.util.module_from_spec(spec); spec.loader.exec_module(native)

class NativeGroups(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='rng-',dir='/tmp')
        self.home=Path(self.tmp.name)
        self.registry=self.home/'.claude/sessions'; self.registry.mkdir(parents=True,mode=0o700)
        self.sockets=[]; self.members=[]
        for i in range(2):
            pid=100+i; path=str(self.home/('%s.sock'%i))
            sock=socket.socket(socket.AF_UNIX); sock.bind(path); sock.listen(8); sock.settimeout(.2)
            self.sockets.append(sock)
            p=dict(kind='native',host='dandy-07',name='peer-%d'%i,session='session-%d'%i,pid=pid,processStart='123')
            self.members.append(p)
            (self.registry/('%d.json'%pid)).write_text(json.dumps(dict(pid=pid,name=p['name'],sessionId=p['session'],procStart='123',messagingSocketPath=path)))
            (self.registry/('%d.%s.key'%(pid,hashlib.sha256(path.encode()).hexdigest()))).write_text(json.dumps(dict(peerToken='secret-token-12345678')))
            transcript = self.home / '.claude/projects/test' / (p['session'] + '.jsonl')
            transcript.parent.mkdir(parents=True, exist_ok=True)
            transcript.write_text(json.dumps(dict(type='permission-mode', sessionId=p['session'], permissionMode='default')) + '\n')
        self.plan=dict(id=str(uuid.uuid4()),participants=self.members,topology='everyone',purpose='Test')
        self.start=patch.object(native,'process_start',return_value='123'); self.start.start()
    def tearDown(self):
        self.start.stop()
        for sock in self.sockets: sock.close()
        self.tmp.cleanup()
    def read(self,i):
        conn,_=self.sockets[i].accept()
        with conn:
            f=conn.makefile('rb'); auth=json.loads(f.readline()); msg=json.loads(f.readline())
        self.assertEqual(auth['token'],'secret-token-12345678')
        return msg
    def test_bidirectional_native_addresses_and_durable_receipts(self):
        result=native.apply(self.plan,self.home)
        self.assertEqual(result['state'],'introductions_attempted')
        for i in range(2):
            msg=self.read(i)
            self.assertEqual(msg['from'],'uds:'+str(self.home/('%d.sock'%(1-i))))
            self.assertIn('session-%d'%(1-i),msg['message']['content'])
        self.assertEqual([x['receipt'] for x in result['introductions']],['written_to_socket']*2)
        path=self.home/'.local/state/relay/native-groups'/(self.plan['id']+'.json')
        self.assertEqual(path.stat().st_mode&0o777,0o600)
        self.assertEqual(json.loads(path.read_text()),result)
    def test_replay_cannot_send_again(self):
        native.apply(self.plan,self.home)
        self.read(0); self.read(1)
        with self.assertRaises(FileExistsError): native.apply(self.plan,self.home)
        with self.assertRaises(socket.timeout): self.sockets[0].accept()
    def test_pair_task_update_and_idempotent_notices(self):
        native.apply(self.plan,self.home)
        self.read(0); self.read(1)
        update=str(uuid.uuid4())
        result=native.update_pair_task(self.home,self.plan['id'],update,'Profile derep memory and test fixes')
        self.assertEqual(result['state'],'sent')
        for i in range(2):
            content=self.read(i)['message']['content']
            self.assertIn('Profile derep memory',content)
            self.assertIn('not authored by the peer',content)
            self.assertIn('existing permissions',content)
        saved=json.loads((self.home/'.local/state/relay/native-groups'/(self.plan['id']+'.json')).read_text())
        self.assertTrue(saved['autonomous'])
        self.assertEqual(saved['taskAmendments'][0]['previousPurpose'],'Test')
        native.update_pair_task(self.home,self.plan['id'],update,'Profile derep memory and test fixes')
        with self.assertRaises(socket.timeout): self.sockets[0].accept()
        with self.assertRaises(ValueError): native.update_pair_task(self.home,self.plan['id'],update,'Different task')
    def test_autonomous_agreement_reaches_every_member(self):
        self.plan['autonomous'] = True
        result = native.apply(self.plan, self.home)
        self.assertTrue(result['autonomous'])
        for i in range(2):
            content = self.read(i)['message']['content']
            self.assertIn('Collaborate autonomously', content)
            self.assertIn('Existing permissions remain unchanged', content)
    def test_invalid_agreement_has_no_side_effects(self):
        for mode, purpose in [(True, '  '), ('true', 'Task'), (1, 'Task')]:
            self.plan.update(autonomous=mode, purpose=purpose)
            with self.assertRaises(ValueError): native.apply(self.plan, self.home)
        self.assertFalse((self.home/'.local').exists())
    def test_old_plan_is_communication_only(self):
        self.assertIn('Communication only', native.working_agreement(self.plan))
    def test_named_replies_and_explicit_group_send(self):
        native.apply(self.plan,self.home)
        for i in range(2):
            content=self.read(i)['message']['content']
            self.assertIn('native peer name: peer-%d'%(1-i),content)
            self.assertIn('--send '+self.plan['id'],content)
        mid=str(uuid.uuid4())
        result=native.send_group(self.home,self.plan['id'],'session-0',mid,'Test broadcast')
        self.assertEqual(result['state'],'sent')
        self.assertIn('Test broadcast',self.read(1)['message']['content'])
        self.assertEqual(native.send_group(self.home,self.plan['id'],'session-0',mid,'Test broadcast'),result)
        with self.assertRaises(socket.timeout): self.sockets[1].accept()
        with self.assertRaises(ValueError): native.send_group(self.home,self.plan['id'],'session-0',mid,'Changed')
    def test_group_send_rejects_nonmember_and_replaced_session(self):
        native.apply(self.plan,self.home); self.read(0); self.read(1)
        with self.assertRaises(ValueError): native.send_group(self.home,self.plan['id'],'outsider',str(uuid.uuid4()),'Test')
        with patch.object(native,'process_start',return_value='changed'):
            with self.assertRaises(ValueError): native.send_group(self.home,self.plan['id'],'session-0',str(uuid.uuid4()),'Test')
    def test_three_member_fanout_continues_after_failed_recipient(self):
        path=str(self.home/'2.sock')
        sock=socket.socket(socket.AF_UNIX); sock.bind(path); sock.listen(8); sock.settimeout(.2)
        self.sockets.append(sock)
        self.members.append(dict(kind='native',host='dandy-07',name='peer-2',session='session-2',pid=102,processStart='123'))
        (self.registry/'102.json').write_text(json.dumps(dict(pid=102,name='peer-2',sessionId='session-2',procStart='123',messagingSocketPath=path)))
        (self.registry/('102.%s.key'%hashlib.sha256(path.encode()).hexdigest())).write_text(json.dumps(dict(peerToken='secret-token-12345678')))
        native.apply(self.plan,self.home)
        for i in range(3): self.read(i)
        result=native.send_group(self.home,self.plan['id'],'session-0',str(uuid.uuid4()),'All members')
        self.assertEqual(len(result['recipients']),2)
        for i in (1,2): self.assertIn('All members',self.read(i)['message']['content'])
        with self.assertRaises(socket.timeout): self.sockets[0].accept()
        self.sockets[1].close()
        result=native.send_group(self.home,self.plan['id'],'session-0',str(uuid.uuid4()),'Partial failure')
        self.assertEqual(result['state'],'needs_attention')
        self.assertEqual(result['recipients'][0]['receipt'],'unknown')
        self.assertEqual(result['recipients'][1]['receipt'],'written_to_socket')
        self.assertIn('Partial failure',self.read(2)['message']['content'])
    def test_replaced_process_rejects_before_any_send(self):
        self.members[1]['processStart']='changed'
        with self.assertRaises(ValueError): native.apply(self.plan,self.home)
        with self.assertRaises(socket.timeout): self.sockets[0].accept()
    def test_cross_host_is_not_silently_local(self):
        self.members[1]['host']='dandy-08'
        with self.assertRaises(ValueError): native.apply(self.plan,self.home)
    def test_failed_send_remains_unknown(self):
        self.sockets[0].close()
        result=native.apply(self.plan,self.home)
        self.assertEqual(result['state'],'needs_attention')
        self.assertEqual(result['introductions'][0]['receipt'],'unknown')
        with self.assertRaises(FileExistsError): native.apply(self.plan,self.home)

if __name__=='__main__': unittest.main()
