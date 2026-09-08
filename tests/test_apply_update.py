"""Test the native updater executable, not an imported duplicate implementation."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'shell/.build/debug/BowserRuntimeTool'

class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='bu.', dir='/tmp')
        self.root = Path(self.temp.name)
        self.pending = self.root / 'updates/pending.json'
        self.pending.parent.mkdir()
        self.manifest = dict(saved_apps=str(self.root/"saved-apps"), home=str(self.root), stage=str(self.root/'stage'), runtime=str(self.root/'runtime'), bundle=str(self.root/'Bowser.app'))
        for key in ('runtime','bundle'):
            target = Path(self.manifest[key]); target.mkdir(); (target/'version').write_text('old')
            source = self.root/'stage'/key; source.mkdir(parents=True); (source/'version').write_text('new')
        self.pending.write_text(json.dumps(self.manifest))

    def tearDown(self): self.temp.cleanup()

    def run_tool(self, *args):
        return subprocess.run([str(TOOL), *map(str,args)], capture_output=True, text=True, timeout=15)

    def test_activation_preserves_previous_pair(self):
        result = self.run_tool('apply-update', self.pending)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(self.pending.exists())
        for key in ('runtime','bundle'):
            target = Path(self.manifest[key])
            self.assertEqual((target/'version').read_text(),'new')
            self.assertEqual((target.with_name(target.name+'.previous')/'version').read_text(),'old')

    def test_owner_lock_blocks_activation(self):
        (self.root/'backend').mkdir()
        with open(self.root/'backend/owner.lock','w') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX)
            result = self.run_tool('apply-update',self.pending)
            self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(self.pending.exists())
        self.assertEqual((self.root/'runtime/version').read_text(),'old')

    def test_failed_second_swap_rolls_back_runtime(self):
        # Missing destination parent makes the second filesystem move fail.
        self.manifest['bundle'] = str(self.root/'absent/Bowser.app')
        self.pending.write_text(json.dumps(self.manifest))
        result=self.run_tool('apply-update',self.pending)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.root/'runtime/version').read_text(),'old')
        self.assertEqual((self.root/'stage/runtime/version').read_text(),'new')
        self.assertEqual((self.root/'stage/bundle/version').read_text(),'new')
        self.assertTrue(self.pending.exists())

    def test_partial_updates_preserve_previously_staged_components(self):
        for shell_only in (True,False):
            with self.subTest(shell_only=shell_only):
                old=self.root/('old'+str(shell_only)); new=self.root/('new'+str(shell_only))
                for stage in (old,new):
                    (stage/'runtime/brain').mkdir(parents=True)
                    (stage/'runtime/brain/version').write_text(stage.name)
                (old/'bundle').mkdir(); (old/'bundle/version').write_text('old-shell')
                self.pending.write_text(json.dumps(dict(self.manifest,stage=str(old))))
                result=self.run_tool('publish',self.pending,new,self.manifest['runtime'],self.manifest['bundle'],int(shell_only),int(not shell_only))
                self.assertEqual(result.returncode,0,result.stderr)
                if shell_only: self.assertEqual((new/'runtime/brain/version').read_text(),old.name)
                else: self.assertEqual((new/'bundle/version').read_text(),'old-shell')
                self.assertFalse(old.exists())

    def test_detach_survives_launcher_and_closes_inherited_stdio(self):
        marker=self.root/'finished'
        result=self.run_tool('detach',self.root/'child.log','TEST_VALUE=works','--','/bin/sh','-c','sleep 0.2; printf "$TEST_VALUE" > "$1"','fixture',marker)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(result.stdout.strip().isdigit())
        import time
        end=time.monotonic()+3
        while not marker.exists() and time.monotonic()<end: time.sleep(.02)
        self.assertEqual(marker.read_text(),'works')

    def test_refresh_retires_only_this_homes_watcher(self):
        import shutil, time
        homes = [self.root/'first', self.root/'second']
        processes=[]; locks=[]
        try:
            for root in homes:
                (root/'updates').mkdir(parents=True); (root/'backend').mkdir()
                lock=open(root/'backend/owner.lock','w'); fcntl.flock(lock,fcntl.LOCK_EX); locks.append(lock)
                pending=root/'updates/pending.json'
                pending.write_text(json.dumps(dict(self.manifest,home=str(root))))
                executable=root/'updates/apply-update'; shutil.copy2(TOOL,executable)
                processes.append(subprocess.Popen([str(executable),str(pending),'--wait'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL))
                end=time.monotonic()+3
                while not (root/'updates/pending.watcher.lock').exists() and time.monotonic()<end: time.sleep(.02)
                self.assertTrue((root/'updates/pending.watcher.lock').exists())
            result=self.run_tool('apply-update',homes[0]/'updates/pending.json','--refresh-watcher')
            self.assertEqual(result.returncode,0,result.stderr)
            processes[0].wait(timeout=3)
            self.assertIsNone(processes[1].poll())
        finally:
            for process in processes:
                if process.poll() is None: process.terminate()
                process.wait(timeout=3)
            for lock in locks: lock.close()

    def test_mcp_forwards_run_and_site_context_and_returns_images(self):
        import socket, threading
        endpoint=self.root/'agent.sock'
        server=socket.socket(socket.AF_UNIX); server.bind(str(endpoint)); server.listen(1)
        received=[]
        def reply():
            peer,_=server.accept()
            with peer:
                reader=peer.makefile('rb'); received.append(json.loads(reader.readline()))
                peer.sendall(b'{"ok":true,"image":"YWJj","mimeType":"image/png"}\n')
                reader.close()
        thread=threading.Thread(target=reply,daemon=True); thread.start()
        try:
            message=json.dumps(dict(jsonrpc='2.0',id=7,method='tools/call',params=dict(name='native_screenshot',arguments={})))+'\n'
            result=subprocess.run([str(TOOL),'bowser-mcp-bridge'],input=message,text=True,capture_output=True,timeout=5,env={**os.environ,'PATH':'/nonexistent','BOWSER_HOME':str(self.root),'BOWSER_SITE_APP_ID':'fixture','BOWSER_MODSMITH_RUN':'run1'})
            self.assertEqual(result.returncode,0,result.stderr)
            thread.join(timeout=2)
            self.assertEqual(received,[dict(tool='native_screenshot',args=dict(site_app='fixture'),run='run1')])
            response=json.loads(result.stdout)['result']
            self.assertFalse(response['isError'])
            self.assertEqual(response['content'][1],dict(type='image',data='YWJj',mimeType='image/png'))
        finally: server.close()

    def test_mcp_initialization_and_tool_catalog_without_python(self):
        message='{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n'
        result=subprocess.run([str(TOOL),'bowser-mcp-bridge'],input=message,text=True,capture_output=True,timeout=3,env={**os.environ,'PATH':'/nonexistent'})
        self.assertEqual(result.returncode,0,result.stderr)
        names={tool['name'] for tool in json.loads(result.stdout)['result']['tools']}
        self.assertIn('native_screenshot',names)
        self.assertIn('put_mod',names)

if __name__=='__main__': unittest.main()
