import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('agent_conversation', ROOT / 'Sources/Relay/Resources/Rotation/agent_conversation.py')
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)

class FrontendBindingTests(unittest.TestCase):
    def test_same_process_thread_switch_rejects_snapshot(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'first.jsonl'
            path.write_text(json.dumps({'type':'response_item','payload':{'type':'message','role':'assistant','content':[{'type':'output_text','text':'first thread'}]}})+'\n')
            path.chmod(0o600)
            with patch.object(reader,'identity',return_value='same-process'), patch.object(reader,'agent',return_value=(22,'codex')), patch.object(reader,'inventory',return_value={}), patch.object(reader,'ancestors',return_value=[11]), patch.object(reader,'authenticated_binding',return_value=None), patch.object(reader,'transcript',side_effect=[(path,'first'),(path,'second')]):
                with self.assertRaisesRegex(reader.Unbound,'changed its bound transcript'):
                    reader.snapshot('pane',11)

    def test_same_process_thread_switch_rejects_attachment(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'first.jsonl'
            path.write_text(json.dumps({'type':'user','uuid':'image','sessionId':'first','message':{'content':[{'type':'image','source':{'type':'base64','media_type':'image/png','data':base64.b64encode(b'image fixture').decode()}}]}})+'\n')
            path.chmod(0o600)
            with patch.object(reader,'identity',return_value='same-process'), patch.object(reader,'agent',return_value=(22,'claude')), patch.object(reader,'inventory',return_value={}), patch.object(reader,'ancestors',return_value=[11]), patch.object(reader,'authenticated_binding',return_value=None), patch.object(reader,'transcript',return_value=(path,'first')):
                reference = reader.snapshot('pane',11)['items'][0]['images'][0]['reference']
                with patch.object(reader,'transcript',side_effect=[(path,'first'),(path,'second')]):
                    with self.assertRaisesRegex(reader.Unbound,'changed its bound transcript'):
                        reader.attachment('pane',11,None,reference)

    def test_closed_descriptor_rejects_recheck(self):
        with patch.object(reader,'transcript',side_effect=reader.Unbound('No unique transcript')):
            with self.assertRaises(reader.Unbound):
                reader.recheck_transcript(22,'codex',Path('/first'),'first',None)

    def test_changed_path_with_same_session_rejects_recheck(self):
        with patch.object(reader,'transcript',return_value=(Path('/replacement'),'first')):
            with self.assertRaises(reader.Unbound):
                reader.recheck_transcript(22,'codex',Path('/first'),'first',None)

    def test_unchanged_descriptor_accepts_recheck(self):
        with patch.object(reader,'transcript',return_value=(Path('/first'),'first')):
            reader.recheck_transcript(22,'codex',Path('/first'),'first',None)

    def test_authenticated_path_uses_separate_revision_recheck(self):
        with patch.object(reader,'transcript',side_effect=AssertionError('must use authenticated revision')), patch.object(reader,'metadata',return_value='first'):
            reader.recheck_transcript(22,'codex',Path('/first'),'first',{'transcript_path':'/first'})

    def test_authenticated_metadata_change_rejects_recheck(self):
        with patch.object(reader,'metadata',return_value='second'):
            with self.assertRaisesRegex(reader.Unbound,'Authenticated transcript session changed'):
                reader.recheck_transcript(22,'codex',Path('/first'),'first',{'transcript_path':'/first'})

    def test_authenticated_path_change_rejects_recheck(self):
        with patch.object(reader,'metadata',return_value='first'):
            with self.assertRaisesRegex(reader.Unbound,'Authenticated transcript session changed'):
                reader.recheck_transcript(22,'codex',Path('/first'),'first',{'transcript_path':'/replacement'})

class HistoryPagingTests(unittest.TestCase):
    def test_history_pages_cover_all_rows_without_duplicates(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'history.jsonl'
            rows = [{'uuid':str(i),'type':'response_item','payload':{'type':'message','role':'assistant','content':[{'type':'output_text','text':'message '+str(i)}]}} for i in range(600)]
            path.write_text(''.join(json.dumps(row)+'\n' for row in rows)); path.chmod(0o600)
            with patch.object(reader,'identity',return_value='same-process'), patch.object(reader,'agent',return_value=(22,'codex')), patch.object(reader,'inventory',return_value={}), patch.object(reader,'ancestors',return_value=[11]), patch.object(reader,'authenticated_binding',return_value=None), patch.object(reader,'transcript',return_value=(path,'session')):
                page = reader.snapshot('pane',11); pages = [page['items']]
                source = page['binding']['source_identity']
                while page['history']['before'] is not None:
                    page = reader.snapshot('pane',11,before=page['history']['before'],expected_source=source,expected_session='session')
                    self.assertTrue(page['history']['historical']); self.assertIsNone(page['control'])
                    pages.insert(0,page['items'])
                ids = [item['id'] for page in pages for item in page]
                self.assertEqual(ids,[str(i) for i in range(600)])
                with self.assertRaisesRegex(reader.Unbound,'history source changed'):
                    reader.snapshot('pane',11,before=100,expected_source='different',expected_session='session')

    def test_history_cursor_keeps_tools_from_same_record_together(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'tools.jsonl'
            rows = [{'uuid':str(i),'sessionId':'session','type':'assistant','message':{'content':[{'type':'tool_use','id':str(i)+'-'+str(j),'name':'Read','input':{}} for j in range(64)]}} for i in range(6)]
            path.write_text(''.join(json.dumps(row)+'\n' for row in rows)); path.chmod(0o600)
            with patch.object(reader,'identity',return_value='same-process'), patch.object(reader,'agent',return_value=(22,'claude')), patch.object(reader,'inventory',return_value={}), patch.object(reader,'ancestors',return_value=[11]), patch.object(reader,'authenticated_binding',return_value=None), patch.object(reader,'transcript',return_value=(path,'session')):
                latest = reader.snapshot('pane',11)
                older = reader.snapshot('pane',11,before=latest['history']['before'],expected_source=latest['binding']['source_identity'],expected_session='session')
                ids = [item['id'] for item in older['items']+latest['items']]
                self.assertEqual(len(ids),384); self.assertEqual(len(set(ids)),384)
                self.assertIsNone(older['history']['before'])

if __name__ == '__main__': unittest.main()
