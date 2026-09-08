#!/usr/bin/env python3
"""Experimental stable-host relay: durable event journal, generation fencing, rollback.
Not installed in Bowser. All sockets, state and subprocesses are fixture-owned.
"""
import asyncio
import json
import os
from pathlib import Path
import sqlite3
import signal
import struct
import sys
import time

HOME, REPO = map(Path, sys.argv[1:3])
if not str(HOME).startswith(('/tmp/bowser-handoff.', '/private/tmp/bowser-handoff.')):
    raise SystemExit('Refusing non-fixture home')

async def recv(reader):
    size = struct.unpack('!I', await reader.readexactly(4))[0]
    if size > 64*1024*1024: raise ValueError('oversized frame')
    return json.loads(await reader.readexactly(size))

def send(writer, msg):
    payload = json.dumps(msg, separators=(',', ':')).encode()
    writer.write(struct.pack('!I',len(payload))+payload)

async def wait_for(predicate, timeout=15):
    end = time.monotonic()+timeout
    while time.monotonic() < end:
        if predicate(): return
        await asyncio.sleep(.01)
    raise TimeoutError('Fixture readiness timeout')

class Relay:
    def __init__(self):
        self.db=sqlite3.connect(HOME/'journal.sqlite')
        self.db.execute('pragma journal_mode=WAL')
        self.db.execute('pragma synchronous=FULL')
        self.db.execute('create table events(seq integer primary key, data text not null)')
        self.db.execute('create table cursor(ack integer not null)')
        self.db.execute('insert into cursor values(0)');self.db.commit()
        self.ack=0;self.seq=0;self.active=None;self.live_writer=None;self.connections={};self.children={};self.servers=[]
        self.hello=None;self.tabs={};self.request=1000000;self.pending={};self.stale=0
        self.sent_per_generation={};self.samples=[]
    async def start(self):
        reader,self.host=await asyncio.open_unix_connection(str(HOME/'brain.sock'))
        asyncio.create_task(self.host_messages(reader))
        await wait_for(lambda:self.hello is not None)
    async def host_messages(self, reader):
        while True:
            msg=await recv(reader)
            op=msg.get('op')
            if op=='hello':
                self.hello=msg
                self.tabs={x['id']:x for x in msg['tabs']}
            elif op=='event':
                event=msg.get('event');wv=msg.get('webview')
                if event=='tab_opened':self.tabs[wv]={'id':wv,'url':None,'profile':msg.get('profile','default')}
                if event=='url_changed':self.tabs.setdefault(wv,{'id':wv})['url']=msg['url']
                if event=='title_changed':self.tabs.setdefault(wv,{'id':wv})['title']=msg['title']
                if event=='webview_closed':self.tabs.pop(wv,None)
                if event=='tab_activated':self.hello['active']=wv
                self.seq+=1;msg['relay_seq']=self.seq
                self.db.execute('insert into events values(?,?)',(self.seq,json.dumps(msg)));self.db.commit()
                if self.live_writer is not None:send(self.live_writer,msg)
            elif 'id' in msg:
                owner=self.pending.pop(msg['id'],None)
                if owner:
                    gen, original, writer=owner
                    if gen==self.active and self.connections.get(gen) is writer:
                        msg['id']=original;send(writer,msg)
                    else:self.stale+=1
    async def connect_backend(self,gen,reader,writer):
        self.connections[gen]=writer
        try:
            while self.active!=gen: await asyncio.sleep(.005)
            # Latest live host state, never the backend's old disk session.
            hello=dict(self.hello,tabs=list(self.tabs.values()),webviews=list(self.tabs))
            send(writer,hello)
            for _,data in self.db.execute('select seq,data from events where seq>? order by seq',(self.ack,)):
                send(writer,json.loads(data))
            self.live_writer=writer
            while True:
                msg=await recv(reader)
                if self.active!=gen or self.connections.get(gen) is not writer:
                    self.stale+=1;continue
                if msg.get('op')=='experiment_ack':
                    ack=msg['seq']
                    if self.ack<ack<=self.seq:
                        self.ack=ack;self.db.execute('update cursor set ack=?',(ack,));self.db.commit()
                else:
                    if 'id' in msg:
                        original=msg['id'];self.request+=1
                        self.pending[self.request]=(gen,original,writer);msg['id']=self.request
                    self.sent_per_generation[gen]=self.sent_per_generation.get(gen,0)+1
                    send(self.host,msg)
        except (asyncio.IncompleteReadError,ConnectionError,BrokenPipeError):pass
        finally:
            if self.live_writer is writer:self.live_writer=None
            if self.connections.get(gen) is writer:self.connections.pop(gen,None)
            writer.close()
    async def boot(self,gen,behavior='healthy'):
        folder=HOME/('g%d'%gen);folder.mkdir()
        server=await asyncio.start_unix_server(lambda r,w:self.connect_backend(gen,r,w),path=str(folder/'brain.sock'))
        self.servers.append(server)
        log=open(HOME/('beam-%d.log'%gen),'wb')
        env=dict(os.environ,BOWSER_HOME=str(folder),BOWSER_NO_SPAWN='1')
        env['PATH']='/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'
        process=await asyncio.create_subprocess_exec('/opt/homebrew/bin/elixir','--erl','+S 2:2',
            '-pa',str(REPO/'beam/_build/prod/lib/bowser_brain/ebin'),
            str(REPO/'experiments/backend-handoff/controller.exs'),str(HOME),str(gen),behavior,
            env=env,stdout=log,stderr=log)
        self.children[gen]=process
        await wait_for(lambda:(HOME/('booted-%d.json'%gen)).exists())
        return json.loads((HOME/('booted-%d.json'%gen)).read_text())
    async def switch(self,gen,timeout=3):
        marker=HOME/('adopted-%d.json'%gen)
        marker.unlink(missing_ok=True)
        previous=self.active
        start=time.monotonic()
        self.live_writer=None
        self.active=gen
        if previous in self.connections:
            self.connections[previous].close()
        await wait_for(marker.exists,timeout)
        return (time.monotonic()-start)*1000
    async def run(self):
        await self.start();await self.boot(1);await self.switch(1)
        (HOME/'initial-ready').touch()
        await wait_for(lambda:(HOME/'run-backend-test').exists(),120)
        # Incompatible candidate is rejected before acquiring any host authority.
        info=await self.boot(9,'incompatible')
        assert info['protocol']!=1
        self.children[9].terminate();await self.children[9].wait()
        assert self.active==1 and self.sent_per_generation.get(9,0)==0
        self.samples.append(dict(case='incompatible_candidate',passed=True))
        # A pending result from the retired generation must not reach its replacement.
        self.request+=1
        self.pending[self.request]=(1,777,self.connections[1])
        send(self.host,dict(op='eval_js',id=self.request,webview=min(self.tabs),
            code="new Promise(resolve=>setTimeout(()=>resolve('stale-generation'),1500))"))
        await self.boot(2)
        start_seq=self.seq
        ms=await self.switch(2)
        assert ms < 1000, "Backend handoff exceeded one second"
        await asyncio.sleep(2)
        self.samples.append(dict(case='full_backend_replacement',handoffMS=ms,gapStartSequence=start_seq,ack=self.ack))
        assert self.stale>=1
        self.children[1].terminate();await self.children[1].wait()
        # Crash the candidate after attach, then restore the still-living previous VM.
        await self.boot(3,'crash_on_attach')
        start=time.monotonic();start_seq=self.seq
        try:await self.switch(3,.35)
        except TimeoutError:pass
        else:raise AssertionError('Candidate should have crashed')
        assert self.children[3].returncode == 86, 'Candidate did not hit the deliberate post-attach crash'
        rollback_ms=await self.switch(2)
        total_gap_ms=(time.monotonic()-start)*1000
        assert total_gap_ms < 1000, 'Failed-candidate control gap exceeded one second'
        self.samples.append(dict(case='candidate_crash_rollback',totalGapMS=total_gap_ms,
            rollbackMS=rollback_ms,gapStartSequence=start_seq,ack=self.ack))
        await asyncio.sleep(1)
        # Tell the fixture to stop producing probes, then drain all captured events.
        (HOME/'stop-probes').touch()
        await wait_for(lambda:(HOME/'probes-stopped').exists())
        await wait_for(lambda:self.ack==self.seq)
        expected=[]
        for seq,data in self.db.execute('select seq,data from events order by seq'):
            event=json.loads(data)
            if event.get('payload',{}).get('kind')=='handoff_probe':expected.append(seq)
        received=[]
        for path in HOME.glob('receipts-*.jsonl'):
            for line in path.read_text().splitlines():
                event=json.loads(line)
                if event.get('payload',{}).get('kind')=='handoff_probe':received.append(event['relay_seq'])
        assert expected and set(expected)==set(received)
        adopted=json.loads((HOME/'adopted-2.json').read_text())
        assert adopted['restore'] is None
        assert 'handoff-work' in adopted['profiles'].values()
        assert 'handoff-personal' in adopted['profiles'].values()
        assert adopted['children']>=20
        assert adopted['active']==next(int(wv) for wv,profile in adopted['profiles'].items() if profile=='handoff-work')
        result=dict(passed=True,phases=self.samples,journalEvents=self.seq,acknowledged=self.ack,
            probesCaptured=len(expected),uniqueProbesReceived=len(set(received)),duplicateProbeDeliveries=len(received)-len(set(received)),
            staleResponsesRejected=self.stale,adopted=adopted,
            limitations='Experimental relay and receipt observer, not shipped updater; at-least-once durable receipt, not exactly-once arbitrary mod effects.')
        (HOME/'backend-result.json').write_text(json.dumps(result,indent=2))
    async def cleanup(self):
        for p in self.children.values():
            if p.returncode is None:p.terminate()
        for p in self.children.values():
            try:await asyncio.wait_for(p.wait(),5)
            except asyncio.TimeoutError:p.kill();await p.wait()

async def main():
    relay=Relay()
    task=asyncio.current_task()
    for sig in (signal.SIGTERM,signal.SIGINT):asyncio.get_running_loop().add_signal_handler(sig,task.cancel)
    try:await relay.run()
    except Exception as e:
        (HOME/'backend-failure.txt').write_text(repr(e));raise
    finally:await relay.cleanup()

asyncio.run(main())
