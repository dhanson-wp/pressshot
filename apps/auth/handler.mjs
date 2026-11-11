// PressShot's confidential WordPress.com exchange. No access tokens are persisted.
const loopback = 'http://127.0.0.1:52632/callback';
const tokenEndpoint = 'https://public-api.wordpress.com/oauth2/token';
const encoder = new TextEncoder();
const headers = {'Cache-Control':'no-store','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff','X-Robots-Tag':'noindex','Content-Security-Policy':"default-src 'none'; frame-ancestors 'none'; base-uri 'none'"};
const b64 = bytes => btoa(String.fromCharCode(...new Uint8Array(bytes))).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');
const unb64 = value => Uint8Array.from(atob(value.replaceAll('-','+').replaceAll('_','/')), c=>c.charCodeAt(0));
const random = () => b64(crypto.getRandomValues(new Uint8Array(32)));
export const challenge = async value => b64(await crypto.subtle.digest('SHA-256',encoder.encode(value)));
const json = (body,status=200) => Response.json(body,{status,headers});
const redirect = (url,cookie) => new Response(null,{status:302,headers:{...headers,Location:url,...(cookie?{'Set-Cookie':cookie}:{})}});
const cookie = value => `__Host-pressshot=${value}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=${value?300:0}`;
function fail(code='invalid_request',status=400){ const error=new Error(code);error.status=status;throw error; }
function fields(params, allowed){for(const key of params.keys()) if(!allowed.includes(key)||params.getAll(key).length!==1) fail();}
function configuration(env) {
  const origin = new URL(env.PRESSSHOT_AUTH_ORIGIN);
  if(origin.protocol!=='https:'||origin.username||origin.password||origin.pathname!=='/'||origin.search||origin.hash) fail('unconfigured',503);
  if(!/^[1-9][0-9]+$/.test(env.WPCOM_CLIENT_ID||'')||!env.WPCOM_CLIENT_SECRET||! /^[A-Za-z0-9_-]{43}$/.test(env.PRESSSHOT_AUTH_KEY||'')) fail('unconfigured',503);
  return origin.origin;
}
async function key(env){return crypto.subtle.importKey('raw',unb64(env.PRESSSHOT_AUTH_KEY),{name:'AES-GCM'},false,['encrypt','decrypt']);}
async function seal(env, value, purpose){
  const iv=crypto.getRandomValues(new Uint8Array(12));
  const ciphertext=await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:encoder.encode(purpose)},await key(env),encoder.encode(JSON.stringify(value)));
  return b64(iv)+'.'+b64(ciphertext);
}
async function open(env, value, purpose, now){
  try {
    if(typeof value!=='string'||value.length>8192||! /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(value)) fail();
    const [iv,data]=value.split('.');
    const plain=await crypto.subtle.decrypt({name:'AES-GCM',iv:unb64(iv),additionalData:encoder.encode(purpose)},await key(env),unb64(data));
    const result=JSON.parse(new TextDecoder().decode(plain));
    if(!Number.isSafeInteger(result.exp)||result.exp<=now||result.exp>now+300) fail();
    return result;
  } catch {fail('invalid_grant');}
}
// Spacefast Functions DB is backed by MySQL. Claims are atomic unique-key inserts.
export class SQLStore {
  constructor(db){this.db=db;}
  async prepare(){
    await this.db.prepare('CREATE TABLE IF NOT EXISTS pressshot_auth_claims (id VARCHAR(64) PRIMARY KEY, expires BIGINT NOT NULL)').run();
    await this.db.prepare('CREATE TABLE IF NOT EXISTS pressshot_auth_limits (id VARCHAR(64) PRIMARY KEY, count BIGINT NOT NULL, expires BIGINT NOT NULL)').run();
  }
  async claim(id, expires){
    // Distinguish a duplicate claim from a database failure without returning secrets.
    try {await this.db.prepare('INSERT INTO pressshot_auth_claims (id, expires) VALUES (?, ?)').bind(id,expires).run();return true;}
    catch {const row=await this.db.prepare('SELECT id FROM pressshot_auth_claims WHERE id = ?').bind(id).first();if(row)return false;throw new Error('storage_unavailable');}
  }
  async limit(id, expires){
    await this.db.prepare('INSERT INTO pressshot_auth_limits (id, count, expires) VALUES (?, 1, ?) ON DUPLICATE KEY UPDATE count = count + 1').bind(id,expires).run();
    const row=await this.db.prepare('SELECT count FROM pressshot_auth_limits WHERE id = ?').bind(id).first();
    return Number(row?.count)<=30;
  }
  async clean(now){
    await this.db.prepare('DELETE FROM pressshot_auth_claims WHERE expires < ?').bind(now).run();
    await this.db.prepare('DELETE FROM pressshot_auth_limits WHERE expires < ?').bind(now).run();
  }
}
export function createHandler({fetcher=(...args)=>globalThis.fetch(...args),now=()=>Math.floor(Date.now()/1000),storeFactory=env=>new SQLStore(env.DB)}={}) {
  return {async fetch(request,env){
    let stage = "request";
    try {
      const url=new URL(request.url);
      if(url.pathname==='/health'&&request.method==='GET') {
        try {configuration(env);return json({status:'configured'});}catch{return json({status:'unconfigured'},503);}
      }
      const origin=configuration(env);
      if(url.origin!==origin) fail('wrong_origin',400);
      if(!['/start','/callback','/exchange'].includes(url.pathname)) return json({error:'not_found'},404);
      if(request.headers.get('Origin')&&request.headers.get('Origin')!==origin) fail('invalid_origin',403);
      const store=storeFactory(env);await store.prepare();
      const time=now();
      const ip=request.headers.get('CF-Connecting-IP');
      // Absent trusted edge identity shares one conservative bucket; never trust X-Forwarded-For.
      const bucket=await challenge(env.PRESSSHOT_AUTH_KEY+':'+(ip||'unknown')+':'+Math.floor(time/60));
      if(!await store.limit(bucket,time+120)) fail('slow_down',429);
      await store.clean(time);
      if(url.pathname==='/start'&&request.method==='GET') {
        fields(url.searchParams,['state','code_challenge','code_challenge_method','client']);
        const state=url.searchParams.get('state'), digest=url.searchParams.get('code_challenge');
        if(!/^[a-f0-9]{64}$/.test(state||'')||! /^[A-Za-z0-9_-]{43}$/.test(digest||'')||url.searchParams.get('code_challenge_method')!=='S256')fail();
        const client=url.searchParams.get('client')??'mac';
        if(!['mac','library'].includes(client))fail();
        const binding=random();
        const upstream=await seal(env,{id:random(),client,state,challenge:digest,binding:await challenge(binding),exp:time+300},'state');
        const target=new URL('https://public-api.wordpress.com/oauth2/authorize');
        target.search=new URLSearchParams({client_id:env.WPCOM_CLIENT_ID,redirect_uri:origin+'/callback',response_type:'code',scope:'global',state:upstream}).toString();
        return redirect(target.toString(),cookie(binding));
      }
      if(url.pathname==='/callback'&&request.method==='GET') {
        fields(url.searchParams,['state','code','error','error_description']);
        const state=await open(env,url.searchParams.get('state'),'state',time);
        const cookies=(request.headers.get('Cookie')||'').split(';').map(s=>s.trim()).filter(s=>s.startsWith('__Host-pressshot='));
        if(cookies.length!==1||await challenge(cookies[0].slice('__Host-pressshot='.length))!==state.binding)fail('invalid_grant');
        if(!await store.claim(await challenge('state:'+state.id),state.exp))fail('invalid_grant');
        if(state.client==='library'&&!/^https:\/\/[a-z0-9.-]+\/api\/auth\/callback$/.test(env.PRESSSHOT_LIBRARY_CALLBACK??''))fail('unconfigured',503);
        const target=new URL(state.client==='library'?env.PRESSSHOT_LIBRARY_CALLBACK:loopback);
        const result=new URLSearchParams();
        if(url.searchParams.has('error')) {
          result.set('state',state.state);result.set('error','access_denied');
        } else {
          const code=url.searchParams.get('code');
          if(!code||code.length>4096||/[\r\n]/.test(code))fail();
          const ticket=await seal(env,{id:random(),code,challenge:state.challenge,exp:time+90},'handoff');
          result.set('state',state.state);result.set('handoff',ticket);
        }
        if(state.client==='library')target.search=result.toString();else target.hash=result.toString();
        return redirect(target.toString(),cookie(''));
      }
      if(url.pathname==='/exchange'&&request.method==='POST') {
        if(!request.headers.get('Content-Type')?.startsWith('application/json'))fail();
        const reader=request.body?.getReader(); if(!reader)fail();
        let text='',size=0;const decoder=new TextDecoder();
        while(true){const chunk=await reader.read();if(chunk.done)break;size+=chunk.value.length;if(size>12288){await reader.cancel();fail();}text+=decoder.decode(chunk.value,{stream:true});}
        const body=JSON.parse(text+decoder.decode());
        if(Object.keys(body).some(k=>!['handoff','code_verifier'].includes(k))||! /^[A-Za-z0-9._~-]{43,128}$/.test(body.code_verifier||''))fail();
        const ticket=await open(env,body.handoff,'handoff',time);
        if(await challenge(body.code_verifier)!==ticket.challenge)fail('invalid_grant');
        if(!await store.claim(await challenge('ticket:'+ticket.id),ticket.exp))fail('invalid_grant');
        // Consume before exchange: ambiguous failures require a fresh sign-in, never code replay.
        stage = "token_request";
        const response=await fetcher(tokenEndpoint,{method:'POST',redirect:'manual',signal:AbortSignal.timeout(15000),headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({client_id:env.WPCOM_CLIENT_ID,client_secret:env.WPCOM_CLIENT_SECRET,redirect_uri:origin+'/callback',grant_type:'authorization_code',code:ticket.code}).toString()});
        if(!response.ok)fail('authorization_failed',502);
        stage = "token_response";
        const grant=await response.json();
        if(typeof grant.access_token!=='string'||!grant.access_token||grant.access_token.length>16384||/[\r\n]/.test(grant.access_token)||grant.token_type?.toLowerCase()!=='bearer')fail('authorization_failed',502);
        if(grant.expires_in!==undefined&&(!Number.isFinite(Number(grant.expires_in))||Number(grant.expires_in)<=0||Number(grant.expires_in)>315360000))fail('authorization_failed',502);
        return json({access_token:grant.access_token,token_type:'bearer',...(grant.expires_in!==undefined?{expires_in:Number(grant.expires_in)}:{})});
      }
      return json({error:'method_not_allowed'},405);
    } catch(error) {
      // Only fixed diagnostic labels, never exception messages or request data.
      if(!error.status) console.error(JSON.stringify({event:"auth_failure",stage,kind:error instanceof TypeError?"type_error":"runtime_error",reason:/illegal invocation|receiver|this object/i.test(String(error.message))?"fetch_receiver":/redirect/i.test(String(error.message))?"redirect":/signal|abort/i.test(String(error.message))?"abort_signal":/body|URLSearchParams/i.test(String(error.message))?"request_body":"other_type_error"}));
      // Never log upstream bodies, callback URLs, authorization codes, or tokens.
      return json({error:error.status?error.message:'service_unavailable'},error.status||503);
    }
  }};
}
export default createHandler();
