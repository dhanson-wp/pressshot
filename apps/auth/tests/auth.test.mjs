import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHandler, challenge} from '../handler.mjs';
const origin='https://auth.example';
const env={PRESSSHOT_LIBRARY_CALLBACK:'https://library.example/api/auth/callback',PRESSSHOT_AUTH_ORIGIN:origin,WPCOM_CLIENT_ID:'123456',WPCOM_CLIENT_SECRET:'synthetic-secret',PRESSSHOT_AUTH_KEY:'a'.repeat(43)};
function fixture(){
 let time=1000,calls=0;const claims=new Set();
 const store={prepare:async()=>{},limit:async()=>true,clean:async()=>{},claim:async id=>{if(claims.has(id))return false;claims.add(id);return true;}};
 const handler=createHandler({now:()=>time,storeFactory:()=>store,fetcher:async(url,options)=>{
  calls++;assert.equal(url,'https://public-api.wordpress.com/oauth2/token');assert.equal(options.redirect,'manual');
  assert.equal(new URLSearchParams(options.body).get('client_secret'),'synthetic-secret');assert.equal(new URLSearchParams(options.body).get('redirect_uri'),origin+'/callback');
  return Response.json({access_token:'synthetic-user-token',token_type:'bearer',expires_in:3600});
 }});
 const send=(path,options)=>handler.fetch(new Request(origin+path,options),env);
 const exchange=(handoff,verifier)=>send('/exchange',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({handoff,code_verifier:verifier})});
 return {send,exchange,store,advance:n=>time+=n,calls:()=>calls};
}
async function begin(f){
 const verifier='v'.repeat(64),state='a'.repeat(64);
 const res=await f.send('/start?'+new URLSearchParams({state,code_challenge:await challenge(verifier),code_challenge_method:'S256'}));
 assert.equal(res.status,302);const location=new URL(res.headers.get('Location'));
 assert.equal(location.searchParams.get('response_type'),'code');assert.ok(!location.searchParams.has('client_secret'));
 return {verifier,state,upstream:location.searchParams.get('state'),cookie:res.headers.get('Set-Cookie').split(';')[0]};
}
async function callback(f,b){return f.send('/callback?'+new URLSearchParams({state:b.upstream,code:'synthetic-code'}),{headers:{Cookie:b.cookie}});}
async function ticket(f,b){const res=await callback(f,b);assert.equal(res.status,302);const url=new URL(res.headers.get('Location'));assert.equal(url.origin,'http://127.0.0.1:52632');const params=new URLSearchParams(url.hash.slice(1));assert.equal(params.get('state'),b.state);return params.get('handoff');}
test('complete code flow, secret only upstream, no token in browser, one-use redemption',async()=>{
 const f=fixture(),b=await begin(f),t=await ticket(f,b);
 assert.ok(!t.includes('synthetic'));const good=await f.exchange(t,b.verifier);assert.equal(good.status,200);
 assert.equal((await good.json()).access_token,'synthetic-user-token');assert.equal(good.headers.get('Cache-Control'),'no-store');
 assert.equal((await f.exchange(t,b.verifier)).status,400);assert.equal(f.calls(),1);
});
test('wrong verifier cannot consume valid handoff',async()=>{const f=fixture(),b=await begin(f),t=await ticket(f,b);assert.equal((await f.exchange(t,'x'.repeat(64))).status,400);assert.equal((await f.exchange(t,b.verifier)).status,200);});
test('concurrent replay makes exactly one upstream exchange',async()=>{const f=fixture(),b=await begin(f),t=await ticket(f,b);const results=await Promise.all([f.exchange(t,b.verifier),f.exchange(t,b.verifier)]);assert.deepEqual(results.map(r=>r.status).sort(),[200,400]);assert.equal(f.calls(),1);});
test('callback requires same browser and rejects duplicate fields',async()=>{const f=fixture(),b=await begin(f);assert.equal((await f.send('/callback?'+new URLSearchParams({state:b.upstream,code:'x'}))).status,400);assert.equal((await f.send('/callback?state='+b.upstream+'&state=x&code=x',{headers:{Cookie:b.cookie}})).status,400);await ticket(f,b);assert.equal((await callback(f,b)).status,400);});
test('expired and tampered handoffs cannot exchange',async()=>{const f=fixture(),b=await begin(f),t=await ticket(f,b);assert.equal((await f.exchange('X'+t,b.verifier)).status,400);f.advance(91);assert.equal((await f.exchange(t,b.verifier)).status,400);assert.equal(f.calls(),0);});
test('denial returns only bound cancellation',async()=>{const f=fixture(),b=await begin(f);const r=await f.send('/callback?'+new URLSearchParams({state:b.upstream,error:'access_denied'}),{headers:{Cookie:b.cookie}});assert.equal(r.status,302);assert.ok(r.headers.get('Location').includes('error=access_denied'));assert.equal(f.calls(),0);});
test('invalid origin, arbitrary redirect, rate limit, missing configuration fail closed',async()=>{
 const f=fixture();assert.equal((await f.send('/start',{headers:{Origin:'https://foreign.example'}})).status,403);
 assert.equal((await f.send('/start?redirect_uri=https://evil.example')).status,400);
 f.store.limit=async()=>false;assert.equal((await f.send('/start')).status,429);
 assert.equal((await createHandler().fetch(new Request(origin+'/health'),{})).status,503);
});
test('database failure never causes upstream exchange',async()=>{const f=fixture(),b=await begin(f),t=await ticket(f,b);f.store.claim=async()=>{throw Error('private detail');};const r=await f.exchange(t,b.verifier);assert.equal(r.status,503);assert.equal(await r.text(),'{"error":"service_unavailable"}');assert.equal(f.calls(),0);});
test('default transport preserves runtime fetch receiver and sends encoded text',async()=>{
 const original=globalThis.fetch;
 try {
  globalThis.fetch=async function(url,options){
   assert.equal(this,globalThis);
   assert.equal(typeof options.body,'string');
   assert.equal(new URLSearchParams(options.body).get('client_secret'),'synthetic-secret');
   return Response.json({access_token:'synthetic-token',token_type:'bearer'});
  };
  const base=fixture();const handler=createHandler({storeFactory:()=>base.store});
  const send=(path,options)=>handler.fetch(new Request(origin+path,options),env);
  const f={send,exchange:(handoff,verifier)=>send('/exchange',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({handoff,code_verifier:verifier})})};
  const b=await begin(f),t=await ticket(f,b);assert.equal((await f.exchange(t,b.verifier)).status,200);
 }finally{globalThis.fetch=original;}
});

test('upstream redirect is rejected and the handoff remains consumed',async()=>{
 const base=fixture();let calls=0;
 const handler=createHandler({storeFactory:()=>base.store,fetcher:async(url,options)=>{calls++;assert.equal(options.redirect,'manual');return new Response(null,{status:302,headers:{Location:'https://untrusted.example'}});}});
 const send=(path,options)=>handler.fetch(new Request(origin+path,options),env);
 const f={send,exchange:(handoff,verifier)=>send('/exchange',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({handoff,code_verifier:verifier})})};
 const b=await begin(f),t=await ticket(f,b);assert.equal((await f.exchange(t,b.verifier)).status,502);assert.equal((await f.exchange(t,b.verifier)).status,400);assert.equal(calls,1);
});

test('Library uses a fixed callback with a verifier-bound handoff; unknown clients fail closed',async()=>{
 const f=fixture(),verifier='v'.repeat(64),state='a'.repeat(64);
 const params=new URLSearchParams({client:'library',state,code_challenge:await challenge(verifier),code_challenge_method:'S256'});
 const start=await f.send('/start?'+params);assert.equal(start.status,302);
 const upstream=new URL(start.headers.get('Location')).searchParams.get('state');
 const cb=await f.send('/callback?'+new URLSearchParams({state:upstream,code:'synthetic-code'}),{headers:{Cookie:start.headers.get('Set-Cookie').split(';')[0]}});
 const target=new URL(cb.headers.get('Location'));assert.equal(target.origin+target.pathname,'https://library.example/api/auth/callback');assert.equal(target.searchParams.get('state'),state);assert.equal(target.hash,'');
 assert.equal((await f.exchange(target.searchParams.get('handoff'),verifier)).status,200);
 params.set('client','https://evil.example');assert.equal((await f.send('/start?'+params)).status,400);
});
