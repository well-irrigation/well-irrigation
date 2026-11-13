#!/usr/bin/env python3
"""Local-only read benchmark and old/new complete JSON parity.

Requires the latest migrations in a running local Supabase DB container.
All fixtures and baseline functions roll back. No production URL is accepted.
Example: python3 scripts/benchmark_session_reads.py --container CONTAINER_ID
"""
import argparse
import tempfile
import re,subprocess,json
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--container',required=True,help='Local Supabase Docker DB container')
parser.add_argument('--output',default=None,help='Directory for logs and JSON plans')
args=parser.parse_args()
output=Path(args.output or tempfile.mkdtemp(prefix='session-read-benchmark-'))
output.mkdir(parents=True,exist_ok=True)
root=Path(__file__).resolve().parents[1]
old=(root/'supabase/migrations/20261110000000_session_financial_adjustment.sql').read_text()
new=(root/'supabase/migrations/20261111000000_session_read_performance.sql').read_text()
fixture=(root/'supabase/tests/20261111000000_session_read_performance.test.sql').read_text().split('-- END FIXTURE')[0]
funcs={}
for version,text in [('before',old),('after',new)]:
 for name in ['list_well_sessions','get_session_detail']:
  funcs[version,name]=re.search(r'create or replace function api\.'+name+r'\([\s\S]*?\$function\$;',text).group()
sql=fixture+'\n'
for name in ['list_well_sessions','get_session_detail']:
 sql+=funcs['before',name].replace('function api.'+name,'function pg_temp.baseline_'+name)+'\n'
sql+='''
set local jit=off;
set local statement_timeout='180s';
select set_config('request.jwt.claim.sub',f->>'actor',true) from srp_context;
set local role authenticated;
select f->>'well' as bench_well,f->>'session' as bench_session from srp_context \\gset
do $$declare f jsonb;a jsonb;b jsonb;t timestamptz;s uuid;begin
 select srp_context.f into f from srp_context;
 t:=clock_timestamp();a:=pg_temp.baseline_list_well_sessions((f->>'well')::uuid);
 raise notice 'BASELINE_LIST_MS %',1000*extract(epoch from clock_timestamp()-t);
 t:=clock_timestamp();b:=api.list_well_sessions((f->>'well')::uuid);
 raise notice 'AFTER_LIST_MS %',1000*extract(epoch from clock_timestamp()-t);
 perform pg_temp.srp_assert(a::text=b::text,'full list JSON byte equality, all 28 sessions');
 foreach s in array array[(f->>'session')::uuid,(f->'sessions'->>1)::uuid,(f->'sessions'->>2)::uuid] loop
  t:=clock_timestamp();a:=pg_temp.baseline_get_session_detail(s);
  raise notice 'BASELINE_DETAIL_MS %',1000*extract(epoch from clock_timestamp()-t);
  t:=clock_timestamp();b:=api.get_session_detail(s);
  raise notice 'AFTER_DETAIL_MS %',1000*extract(epoch from clock_timestamp()-t);
  perform pg_temp.srp_assert(a::text=b::text,'full detail JSON byte equality, correction/approval/credit');
 end loop;
 a:=pg_temp.baseline_list_well_sessions((f->>'well')::uuid,null,null,null,true,200);
 b:=api.list_well_sessions((f->>'well')::uuid,null,null,null,true,200);
 perform pg_temp.srp_assert(a::text=b::text,'unpaid filter full JSON equality');
 a:=pg_temp.baseline_list_well_sessions((f->>'well')::uuid,(f->>'other_account')::uuid);
 b:=api.list_well_sessions((f->>'well')::uuid,(f->>'other_account')::uuid);
 perform pg_temp.srp_assert(a::text=b::text,'farmer filter full JSON equality');
end;$$;
'''
def main_query(src,name):
 body=src.split('begin',1)[1]
 if name=='list_well_sessions':
  start=body.index('  with target_sessions') if '  with target_sessions' in body else body.index('  select coalesce(')
  q=body[start:body.index('\n\n  return',start)]
  q=q.replace('  into v_items\n','')
 else:
  start=body.index('  with target_sessions') if '  with target_sessions' in body else body.index('  select\n    jsonb_build_object(')
  q=body[start:body.index('\n\n  -- الجلسة',start)]
  q=re.sub(r'\n  into v_session, v_payment\n','\n',q)
 for a,b in {'p_well_id':" :'bench_well'::uuid ",'p_session_id':" :'bench_session'::uuid ",'p_farmer_well_account_id':'null::uuid','p_from':'null::timestamptz','p_to':'null::timestamptz','p_unpaid_only':'false','v_limit':'200'}.items():
  q=re.sub(r'\b'+a+r'\b',b,q)
 return q
for version in ['before','after']:
 for name in ['list_well_sessions','get_session_detail']:
  q=main_query(funcs[version,name],name)
  sql+=f'\n\\echo PLAN_BEGIN {version}-{name}\n'
  sql+='EXPLAIN (ANALYZE,VERBOSE,TIMING OFF,FORMAT JSON) '+q+f'\n\\echo PLAN_END {version}-{name}\n'
# Explain the non-inlined invoker helper separately; wrappers alone hide its plan.
q=new.split('as $context$\n',1)[1].split('$context$;',1)[0].strip().rstrip(';')
q=re.sub(r'\bp_session_ids\b',"array[:'bench_session'::uuid]",q)
q=re.sub(r'\bp_include_latest\b','true',q)
sql+='\n\\echo PLAN_BEGIN helper\nEXPLAIN (ANALYZE,VERBOSE,TIMING OFF,FORMAT JSON) '+q+';\n\\echo PLAN_END helper\n'
sql+='reset role;rollback;\n'
(output/'benchmark.sql').write_text(sql)
r=subprocess.run(['docker','exec','-i',args.container,'psql','-X','-A','-t','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1'],input=sql,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
(output/'output.log').write_text(r.stdout)
if r.returncode:
 print(r.stdout[-4000:])
 raise SystemExit(r.returncode)
captured_plans=re.findall(r'PLAN_BEGIN ([^\n]+)\n(.*?)\nPLAN_END [^\n]+',r.stdout,re.S)
if len(captured_plans)!=5:
 raise RuntimeError('Expected five complete EXPLAIN plans; inspect output.log')
for name,raw in captured_plans:
 plan=json.loads(raw)[0]
 (output/(name+'.json')).write_text(json.dumps([plan],indent=2))
 nodes=[]
 def walk(value):
  if isinstance(value,dict):
   if 'Node Type' in value:nodes.append(value)
   for child in value.values():walk(child)
  elif isinstance(value,list):
   for child in value:walk(child)
 walk(plan['Plan'])
 windows=sum(n['Node Type']=='WindowAgg' for n in nodes)
 if name=='helper' and windows!=2:
  raise RuntimeError('Shared economic context must retain its two cumulative windows')
 if name.startswith('after-') and windows!=0:
  raise RuntimeError('Outer readers must not duplicate economic windows')
 print(json.dumps(dict(plan=name,nodes=len(nodes),windows=sum(n['Node Type']=='WindowAgg' for n in nodes),planning_ms=plan.get('Planning Time'),execution_ms=plan.get('Execution Time'))))
for line in r.stdout.splitlines():
 if 'NOTICE:' in line:print(line)
print('PASS local benchmark; artifacts:',output)
