# Developer-only integration check; requires Docker and bowser-server:local.
import subprocess,os,uuid,json,time,urllib.request
from datetime import datetime,timezone
name='bowser-check-'+uuid.uuid4().hex[:8]
volume=name+'-data'
docker=['docker']
env=dict(os.environ)
def run(*args): return subprocess.check_output(docker+list(args),env=env,text=True).strip()
def boot():
 run('run','--rm','-d','--name',name,'--read-only','--tmpfs','/tmp:rw,noexec,nosuid,size=64m,mode=1777','--cap-drop','ALL','--security-opt','no-new-privileges:true','-p','127.0.0.1::8080','-v',volume+':/data','-e','BOWSER_TERMS_VERSIONS=fixture','-e','BOWSER_TELEMETRY_ENABLED=1','-e','BOWSER_EVENT_RETENTION_DAYS=7','bowser-server:local')
 base='http://'+run('port',name,'8080/tcp')
 for _ in range(100):
  try:
   with urllib.request.urlopen(base+'/healthz',timeout=1) as r: assert json.load(r)=={'ok':True}
   return base
  except OSError: time.sleep(.2)
 raise RuntimeError(run('logs',name))
def register(base,data):
 req=urllib.request.Request(base+'/v1/registrations',data=json.dumps(data).encode(),headers={'Content-Type':'application/json','Idempotency-Key':data['requestID']})
 with urllib.request.urlopen(req) as r:return r.status,json.load(r)
try:
 base=boot()
 with urllib.request.urlopen(base+'/') as r:assert b'Bowser' in r.read()
 data={'requestID':str(uuid.uuid4()),'email':'fixture@example.com','termsVersion':'fixture','acceptedAt':datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z'),'trainingConsent':False}
 status,receipt=register(base,data);assert status==201
 event={'eventID':str(uuid.uuid4()),'name':'crash','occurredAt':data['acceptedAt'],'properties':{'appVersion':'1','appBuild':'1','category':'native'}}
 req=urllib.request.Request(base+'/v1/events',data=json.dumps({'events':[event]}).encode(),headers={'Content-Type':'application/json','Authorization':'Bearer '+receipt['telemetryToken']})
 with urllib.request.urlopen(req) as r:assert r.status==202
 run('exec',name,'/app/bin/bowser_server','rpc','BowserServer.Admin.run("backup", "/data/snapshot.sqlite")')
 assert run('exec',name,'id','-u')=='10001'
 run('stop',name)
 base=boot()
 assert register(base,data)==(200,receipt)
 print('Docker smoke: non-root/read-only runtime, website, registration, telemetry, backup RPC and persistent restart passed')
finally:
 subprocess.run(docker+['rm','-f',name],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 subprocess.run(docker+['volume','rm',volume],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
