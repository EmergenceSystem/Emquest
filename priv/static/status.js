async function load(){
let d=await (await fetch('/health')).json();
document.getElementById('pc').textContent=d.peer_count;
document.getElementById('ac').textContent=d.alive_count;
let c=d.cache||{};
document.getElementById('cache').textContent=(c.l1_hits||0)+'/'+(c.l2_hits||0)+'/'+(c.misses||0);
document.getElementById('redis').textContent=c.redis?'on':'off';
document.getElementById('ts').textContent=new Date().toLocaleTimeString();
let ps=(d.peers||[]).slice().sort((a,b)=>(a.alive-b.alive)||(a.name>b.name?1:-1));
document.getElementById('rows').innerHTML=ps.map(p=>
'<tr><td><span class="dot '+(p.alive?'up':'down')+'"></span>'+(p.name||'?')+
'</td><td class=muted>'+(p.host||'')+':'+(p.port==null?'-':p.port)+
'</td><td class=num>'+(p.latency==null?'-':p.latency+' ms')+
'</td><td class=num>'+(p.fails||0)+'</td></tr>').join('');}
load();setInterval(load,10000);
