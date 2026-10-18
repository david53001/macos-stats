import sys
S=sys.argv[1]
# SystemLoad accumulators (gauge log) -> per-update avg W
rows=[]; seen=set()
for l in open(S+'/gaugelog.txt'):
    f=l.split('|')[0].split()
    if f[0] in seen: continue
    seen.add(f[0]); rows.append([int(x) for x in f])
# pack current accumulator log
pk=[]; seen=set()
for l in open(S+'/packacc.txt'):
    d=dict(kv.split('=') for kv in l.split()[1:] if '=' in kv)
    u=d['UpdateTime']
    if u in seen: continue
    seen.add(u)
    acc=int(d['PackCurrentAccumulator']); acc = acc-2**64 if acc>=2**63 else acc
    pk.append((int(u),acc,int(d['PackCurrentAccumulatorCount']),int(d['Voltage'])))
print("update  sysLoadAvgW(acc)  instantSysLoadW  VxA_W  rawCur")
for a,b in zip(rows,rows[1:]):
    w=(b[1]-a[1])/(b[2]-a[2])/1000
    print(b[0], f"{w:6.2f}", f"{b[6]/1000:6.2f}", f"{abs(b[4]*b[5])/1e6:6.2f}", b[3], "dt", b[0]-a[0], "dcnt", b[2]-a[2])
tot=(rows[-1][1]-rows[0][1])/(rows[-1][2]-rows[0][2])/1000
print("SystemLoad mean over", rows[-1][0]-rows[0][0], "s:", round(tot,3), "W")
if len(pk)>1:
    # mean current over the pack log span, times mean voltage
    I=(pk[-1][1]-pk[0][1])/(pk[-1][2]-pk[0][2])
    V=sum(p[3] for p in pk)/len(pk)/1000
    print("Pack accumulator mean current", round(I,1), "mA x", round(V,3), "V =", round(abs(I)*V/1000,3), "W over", pk[-1][0]-pk[0][0], "s (updates", pk[0][0], "->", pk[-1][0], ")")
    # SystemLoad over same span
    sl=[r for r in rows if pk[0][0]<=r[0]<=pk[-1][0]]
    if len(sl)>1: print("SystemLoad mean over same span:", round((sl[-1][1]-sl[0][1])/(sl[-1][2]-sl[0][2])/1000,3), "W", sl[0][0], "->", sl[-1][0])
