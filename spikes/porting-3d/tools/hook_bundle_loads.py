import frida,sys,time,json
dur=float(sys.argv[1]); out=sys.argv[2]
s=frida.attach(int(sys.argv[3]) if len(sys.argv)>3 else 25520); names=[]
def on(m,d):
    if m['type']!='send': return
    p=m['payload']
    if 'bundle' in p: names.append(p['bundle'])
sc=s.create_script(open('/tmp/hook_bundles.js').read()); sc.on('message',on); sc.load()
print('hooking',dur,flush=True)
try:
    end=time.time()+dur
    while time.time()<end: time.sleep(1)
finally:
    s.detach(); json.dump(names, open(out,'w'))
print('bundles seen:',len(names),flush=True)
for n in names[:40]: print("  ",n)
