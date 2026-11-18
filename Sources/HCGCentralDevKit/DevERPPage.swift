import Foundation

/// The development approver page ("ERP emulation"). Served only on 127.0.0.1.
/// Everything on it is labelled as local development, not HCG ERP.
enum DevERPPage {
    static func html(adminToken: String) -> String {
        let tokenJSON = "\"" + adminToken.replacingOccurrences(of: "\"", with: "") + "\""
        return """
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Development approver — not HCG ERP</title>
<style>
:root{--bg:#05080b;--panel:#0c1217;--raised:#111a21;--line:#1d2d3b;--text:#e6ecf0;--dim:#8f9ca5;--cyan:#2fd3e6;--warn:#ebb84d;--err:#f27373;--ok:#5ccc8f}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
.banner{background:repeating-linear-gradient(135deg,#3a2a05,#3a2a05 14px,#2a1f04 14px,#2a1f04 28px);border-bottom:2px solid var(--warn);padding:14px 22px;color:#ffe2a3}
.banner b{font-size:16px;letter-spacing:.06em}.wrap{max-width:1100px;margin:0 auto;padding:20px}
h2{font-size:12px;letter-spacing:.12em;text-transform:uppercase;color:var(--dim);margin:26px 0 10px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:14px 16px;margin-bottom:10px}
.row{display:flex;gap:12px;flex-wrap:wrap;align-items:center}.grow{flex:1;min-width:220px}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;color:var(--dim)}
.code{font-family:ui-monospace,Menlo,monospace;font-size:20px;color:var(--cyan);letter-spacing:.08em}
.pill{display:inline-block;padding:2px 9px;border-radius:99px;font-size:11px;border:1px solid var(--line);color:var(--dim)}
.pill.pending_review{color:var(--warn);border-color:var(--warn)}.pill.approved,.pill.active{color:var(--ok);border-color:var(--ok)}
.pill.rejected,.pill.revoked,.pill.expired{color:var(--err);border-color:var(--err)}
button{background:var(--raised);color:var(--text);border:1px solid var(--line);border-radius:7px;padding:7px 12px;cursor:pointer;font:inherit}
button.ok{border-color:var(--ok);color:var(--ok)}button.bad{border-color:var(--err);color:var(--err)}
input[type=text]{background:var(--bg);color:var(--text);border:1px solid var(--line);border-radius:7px;padding:7px 9px;font:inherit;width:100%}
label.cap{display:inline-flex;gap:6px;align-items:center;margin-right:14px}.muted{color:var(--dim)}.err{color:var(--err)}
</style></head><body>
<div class="banner"><b>LOCAL DEVELOPMENT SERVICE — NOT HCG, NOT ERP</b><br>
This page stands in for the ERP approval step so the HCG Origin enrollment flow can be exercised on this Mac.
Decisions made here are development results only: they are not HCG account verification and admit nothing in production.</div>
<div class="wrap">
<div class="row"><div class="grow"><span class="muted">Simulated central outage:</span> <b id="outage">…</b></div>
<button id="toggleOutage">Toggle outage</button></div>
<p id="msg" class="err"></p>
<h2>Enrollment requests</h2><div id="enrollments"><p class="muted">Loading…</p></div>
<h2>Admitted devices</h2><div id="devices"></div>
<h2>Gateway audit events</h2><div id="events"></div>
<h2>Decision log</h2><div id="log"></div>
</div>
<script>
const TOKEN = \(tokenJSON);
const $ = (id) => document.getElementById(id);
function el(tag, cls, text){const e=document.createElement(tag);if(cls)e.className=cls;if(text!==undefined)e.textContent=text;return e;}
async function api(method, path, body){
  const r = await fetch(path,{method,headers:{'X-HCG-Dev-Admin':TOKEN,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});
  const j = await r.json(); if(!r.ok){throw new Error((j.error&&j.error.message)||('HTTP '+r.status));} return j;
}
let editing=false;
function render(s){
  $('outage').textContent = s.outage ? 'ON (Origin sees 503)' : 'off';
  const en=$('enrollments'); en.replaceChildren();
  if(!s.enrollments.length) en.append(el('p','muted','No requests yet. Start pairing in HCG Origin and run the Connector test client.'));
  for(const e of s.enrollments){
    const c=el('div','card'); const top=el('div','row');
    const left=el('div','grow'); left.append(el('b','',e.deviceName+' '), el('span','pill '+e.state,e.state.replace('_',' ')));
    left.append(el('div','mono',e.platform+' · '+e.clientKind+' · key '+e.deviceFingerprint.slice(0,16)));
    left.append(el('div','mono','account '+e.account+' · gateway '+e.gatewayName+' ('+e.gatewayId+')'));
    left.append(el('div','mono','verification: account '+e.verification.account+', device signature '+e.verification.deviceSignature+', gateway signature '+e.verification.gatewaySignature));
    if(e.refusedByGateway.length) left.append(el('div','mono','refused by gateway: '+e.refusedByGateway.map(r=>r.capability).join(', ')));
    if(e.reason) left.append(el('div','mono','reason: '+e.reason));
    if(e.deviceId) left.append(el('div','mono','issued device ID: '+e.deviceId));
    const right=el('div',''); right.append(el('div','muted','Check code (compare with the device)'), el('div','code',e.checkCode));
    top.append(left,right); c.append(top);
    if(e.state==='pending_review'){
      const caps=el('div',''); caps.style.margin='10px 0';
      for(const id of e.requestedCapabilities){const l=el('label','cap');const cb=document.createElement('input');cb.type='checkbox';cb.checked=true;cb.value=id;cb.addEventListener('focus',()=>editing=true);l.append(cb,document.createTextNode(id));caps.append(l);}
      caps.append(el('span','muted','  · command execution can never be granted here'));
      const reason=document.createElement('input');reason.type='text';reason.placeholder='Reason (for rejection) or note';reason.addEventListener('focus',()=>editing=true);reason.addEventListener('blur',()=>editing=false);
      const actions=el('div','row');actions.style.marginTop='8px';
      const ok=el('button','ok','Approve'); const no=el('button','bad','Reject');
      ok.onclick=async()=>{editing=false;try{render(await api('POST','/dev/v1/admin/enrollments/'+e.enrollmentId+'/approve',{capabilities:[...caps.querySelectorAll('input:checked')].map(x=>x.value),note:reason.value||null}));$('msg').textContent='';}catch(x){$('msg').textContent=x.message;}};
      no.onclick=async()=>{editing=false;try{render(await api('POST','/dev/v1/admin/enrollments/'+e.enrollmentId+'/reject',{reason:reason.value}));$('msg').textContent='';}catch(x){$('msg').textContent=x.message;}};
      actions.append(ok,no); c.append(caps,reason,actions);
    }
    en.append(c);
  }
  const dv=$('devices'); dv.replaceChildren();
  if(!s.devices.length) dv.append(el('p','muted','None.'));
  for(const d of s.devices){
    const c=el('div','card row'); const l=el('div','grow');
    l.append(el('b','',d.name+' '), el('span','pill '+d.status,d.status));
    l.append(el('div','mono',d.deviceId+' · key '+d.fingerprint.slice(0,16)+' · '+d.grant.capabilities.join(', ')));
    if(d.revocationReason) l.append(el('div','mono','revoked: '+d.revocationReason));
    c.append(l);
    if(d.status==='active'){const b=el('button','bad','Revoke');b.onclick=async()=>{try{render(await api('POST','/dev/v1/admin/devices/'+d.deviceId+'/revoke',{reason:'Revoked on the development approver page.'}));}catch(x){$('msg').textContent=x.message;}};c.append(b);}
    dv.append(c);
  }
  const ev=$('events'); ev.replaceChildren(); if(!s.events.length) ev.append(el('p','muted','None.'));
  for(const e of s.events.slice(0,30)) ev.append(el('div','mono',e.occurredAt+'  '+e.type+'  '+(e.deviceId||e.localRequestId||'')+'  '+e.detail));
  const lg=$('log'); lg.replaceChildren(); for(const e of s.log.slice(0,30)) lg.append(el('div','mono',e.at+'  '+e.action+'  '+e.subject+'  '+e.detail));
}
async function refresh(){ if(editing) return; try{render(await api('GET','/dev/v1/admin/state'));}catch(x){$('msg').textContent=x.message;} }
$('toggleOutage').onclick=async()=>{try{const s=await api('GET','/dev/v1/admin/state');render(await api('POST','/dev/v1/admin/outage',{enabled:!s.outage}));}catch(x){$('msg').textContent=x.message;}};
refresh(); setInterval(refresh, 2000);
</script></body></html>
"""
    }
}
