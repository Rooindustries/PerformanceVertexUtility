p='backend/scripts/Test-ProcessPolicyWorker.ps1'
s=open(p,encoding='utf-8').read().split('\n')
i=next(k for k,l in enumerate(s) if 'The governor gives a new process its rules within 1 s' in l)
h=open('proof/harness.ps1',encoding='utf-8').read().rstrip('\n').split('\n')
open(p,'w',encoding='utf-8').write('\n'.join(s[:i+1]+h+s[i+1:]))
