#!/usr/bin/env python3
"""Validate localization coverage, formatting, canonical exercise identity, and Swift syntax.
Run from the repository root on macOS with Xcode command-line tools installed.
"""
from pathlib import Path
import json,re,plistlib,subprocess

def strings(path):
 text=Path(path).read_text();pairs=re.findall(r'^("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*");$',text,re.M)
 obj={json.loads(k):json.loads(v) for k,v in pairs};assert len(pairs)==len(obj),path
 return obj
eng=strings('Shared/en.lproj/Localizable.strings');pol=strings('Shared/pl.lproj/Localizable.strings');assert eng.keys()==pol.keys();assert all(pol.values())
# Compare printf argument types, ignoring optional positional numbering.
fmt=lambda s: sorted(re.findall(r'%(?:\d+\$)?([@]|(?:ll|l)?[diuf])',s))
for k,v in eng.items():assert fmt(v)==fmt(pol[k]),(k,pol[k])
for name in ['Localizable.strings','Intents.strings','Localizable.stringsdict']:
 for lang in ['en','pl']:
  subprocess.run(['plutil','-lint',f'Shared/{lang}.lproj/{name}'],check=True)
intent_en=strings('Shared/en.lproj/Intents.strings');intent_pl=strings('Shared/pl.lproj/Intents.strings');assert intent_en.keys()==intent_pl.keys()
for k,v in intent_en.items():assert sorted(re.findall(r'\$\{[^}]+\}',v))==sorted(re.findall(r'\$\{[^}]+\}',intent_pl[k]))
missing={}
for p in Path('.').rglob('*.swift'):
 if any(x in p.parts for x in ['Pods','.build','.git','IronTests']):continue
 for k in re.findall(r'L10n\.(?:string|format)\("((?:[^"\\]|\\.)*)"',p.read_text()):
  if k not in eng and k!='%d workouts':missing.setdefault(k,[]).append(str(p))
assert not missing,missing
files=[]
for root in ['Iron/UI','Shared/UI','WatchIron Extension/UI','IronWidget','IronIntents','IronIntentsUI']:files+=list(Path(root).rglob('*.swift'))
errors=[]
for p in files:
 r=subprocess.run(['xcrun','swiftc','-frontend','-parse',str(p)],capture_output=True,text=True)
 if r.returncode:errors.append((str(p),r.stderr))
assert not errors,errors
print(f'PASS: {len(eng)} matching Localizable entries; {len(intent_en)} matching intent entries with variables preserved; printf types preserved; six resources valid; no missing production L10n literal keys; {len(files)} Swift source files parse.')

source=json.loads(Path('WorkoutDataKit/everkinetic-data/exercises.json').read_text())
translated=json.loads(Path('WorkoutDataKit/everkinetic-data/exercises-pl.json').read_text())
assert len(source)==len(translated)==159
assert len({e['uuid'] for e in translated})==159
for original,localized in zip(source,translated):
 assert original.keys()==localized.keys(),original['id']
 for key in ['uuid','id','type','primary','secondary','equipment','references','pdf','png']:
  assert original[key]==localized[key],(original['id'],key)
 for key,value in original.items():
  if isinstance(value,list):assert len(value)==len(localized[key]),(original['id'],key)
 assert original['title']!=localized['title'] and localized['title'].strip()
 for key in ['alias','steps','tips']:
  for before,after in zip(original.get(key,[]),localized.get(key,[])):
   if before.replace('&nbsp;','').strip():assert after.strip() and after!=before,(original['id'],key)
 if original.get('primer'):assert localized.get('primer') and original['primer']!=localized['primer']
terms={term for exercise in source for key in ['primary','secondary','equipment'] for term in exercise[key]}
assert terms<=pol.keys(),terms-pol.keys()
print('PASS: 159 exercises; canonical identity, schema, list counts, translated prose and muscle/equipment coverage preserved.')
