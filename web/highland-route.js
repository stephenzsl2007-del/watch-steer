/* Original closed highland route. Metres; Y-up; arc-length queries shared by physics and rendering. */
(function(root){
'use strict';
const clamp=(v,a,b)=>Math.max(a,Math.min(b,v)),mix=(a,b,t)=>a+(b-a)*t;
const smooth=t=>{t=clamp(t,0,1);return t*t*(3-2*t);};
const hash=(x,z)=>{const n=Math.sin(x*127.1+z*311.7)*43758.5453;return n-Math.floor(n);};
function noise(x,z){const i=Math.floor(x),j=Math.floor(z),u=smooth(x-i),v=smooth(z-j);return mix(mix(hash(i,j),hash(i+1,j),u),mix(hash(i,j+1),hash(i+1,j+1),u),v);}
const points=[[0,0],[0,-340],[65,-650],[165,-800],[60,-925],[-75,-1030],[-95,-1190],[20,-1300],[150,-1280],[190,-1450],[390,-1640],[820,-1730],[1160,-1650],[1380,-1450],[1470,-1130],[1380,-860],[1280,-670],[1390,-420],[1250,-155],[1010,25],[670,80],[370,175],[130,170],[-25,100]];
function spline(t){const i=Math.floor(t),u=t-i,n=points.length,p0=points[(i-1+n)%n],p1=points[i%n],p2=points[(i+1)%n],p3=points[(i+2)%n];return [0,1].map(k=>.5*((2*p1[k])+(-p0[k]+p2[k])*u+(2*p0[k]-5*p1[k]+4*p2[k]-p3[k])*u*u+(-p0[k]+3*p1[k]-3*p2[k]+p3[k])*u*u*u));}
const dense=[{s:0,p:spline(0)}];let total=0;
for(let i=1;i<=points.length*160;i++){const p=spline(i/160),prev=dense[dense.length-1].p;total+=Math.hypot(p[0]-prev[0],p[1]-prev[1]);dense.push({s:total,p});}
const length=total,step=2,count=Math.ceil(length/step),ds=length/count,table=[];let di=0;
for(let i=0;i<count;i++){const s=i*ds;while(dense[di+1].s<s)di++;const a=dense[di],b=dense[di+1],t=(s-a.s)/(b.s-a.s);table.push({s,x:mix(a.p[0],b.p[0],t),z:mix(a.p[1],b.p[1],t)});}
const wrap=s=>((s%length)+length)%length;
const rawY=s=>38*Math.sin(2*Math.PI*s/length)+12*Math.sin(6*Math.PI*s/length)+5*Math.sin(10*Math.PI*s/length);
let maxGrade=0;for(let i=0;i<count;i++)maxGrade=Math.max(maxGrade,Math.abs(rawY(i*ds+1)-rawY(i*ds-1))/2);
const heightScale=Math.min(1,.085/maxGrade),elevation=s=>55+heightScale*rawY(wrap(s));
function region(s){const f=wrap(s)/length;if(f<.23)return {zone:'forest',name:'松林夹道'};if(f<.46)return {zone:'pass',name:'石楠山口'};if(f<.70)return {zone:'highland',name:'高地长风'};if(f<.84)return {zone:'village',name:'格伦溪村'};return {zone:'valley',name:'溪谷归途'};}
for(let i=0;i<count;i++){
 const p=table[i],a=table[(i-1+count)%count],b=table[(i+1)%count],dx=b.x-a.x,dz=b.z-a.z,l=Math.hypot(dx,dz);
 p.y=elevation(p.s);p.tx=dx/l;p.tz=dz/l;p.nx=-p.tz;p.nz=p.tx;p.grade=(elevation(p.s+1)-elevation(p.s-1))/2;p.vertical=(elevation(p.s+3)-2*p.y+elevation(p.s-3))/9;
 const ax=p.x-a.x,az=p.z-a.z,bx=b.x-p.x,bz=b.z-p.z;
 p.curvature=2*(ax*bz-az*bx)/(Math.hypot(ax,az)*Math.hypot(bx,bz)*Math.hypot(b.x-a.x,b.z-a.z));Object.assign(p,region(p.s));
 p.limit=Math.min(100/3.6,Math.sqrt(2.65/Math.max(Math.abs(p.curvature),.0001)),Math.sqrt(3/Math.max(-p.vertical,.00001)),p.zone==='village'?36/3.6:Infinity);
 p.speed=p.limit;
}
// Backward reachable speed envelope, including the loop's end/start boundary.
for(let pass=0;pass<3;pass++)for(let i=count-1;i>=0;i--)table[i].speed=Math.min(table[i].speed,Math.sqrt(table[(i+1)%count].speed**2+2*2.6*ds));
function sample(s){s=wrap(s);const k=s/ds,i=Math.floor(k),a=table[i],b=table[(i+1)%count],t=k-i;const tx=mix(a.tx,b.tx,t),tz=mix(a.tz,b.tz,t),len=Math.hypot(tx,tz);return {...a,s,x:mix(a.x,b.x,t),y:mix(a.y,b.y,t),z:mix(a.z,b.z,t),tx:tx/len,tz:tz/len,nx:-tz/len,nz:tx/len,grade:mix(a.grade,b.grade,t),curvature:mix(a.curvature,b.curvature,t),speed:mix(a.speed,b.speed,t)};}
const bins=new Map(),cell=50,key=(x,z)=>Math.floor(x/cell)+','+Math.floor(z/cell);
for(let i=0;i<count;i++){const p=table[i],k=key(p.x,p.z);if(!bins.has(k))bins.set(k,[]);bins.get(k).push(i);}
function nearest(x,z,hint){
 let candidates=[],radius=1,best=Infinity,result=null;const ix=Math.floor(x/cell),iz=Math.floor(z/cell);
 // Search spatial bins; distant landscape points need a wider search than a car.
 while(!candidates.length&&radius<=64){for(let a=-radius;a<=radius;a++)for(let b=-radius;b<=radius;b++){const bin=bins.get((ix+a)+','+(iz+b));if(bin)candidates.push(...bin);}if(!candidates.length)radius*=2;}
 for(const i of candidates){const a=table[i],b=table[(i+1)%count],dx=b.x-a.x,dz=b.z-a.z,t=clamp(((x-a.x)*dx+(z-a.z)*dz)/(dx*dx+dz*dz),0,1),px=a.x+t*dx,pz=a.z+t*dz,d=(px-x)**2+(pz-z)**2;if(d<best){best=d;const s=wrap(a.s+t*ds);result={s,offset:(x-px)*a.nx+(z-pz)*a.nz,distance:Math.sqrt(d),y:mix(a.y,b.y,t)};}}
 if(hint!==undefined&&result){const delta=wrap(result.s-wrap(hint)+length/2)-length/2;result.progress=hint+delta;}
 return result;
}
function nearby(x,z,range=38){const ix=Math.floor(x/cell),iz=Math.floor(z/cell),radius=Math.ceil(range/cell);let found=false;for(let a=-radius;a<=radius&&!found;a++)for(let b=-radius;b<=radius;b++)if(bins.has((ix+a)+','+(iz+b))){found=true;break;}if(!found)return null;const p=nearest(x,z);return p.distance<range?p:null;}
function height(x,z){
 const large=112*(noise(x/340,z/340)-.46)+54*(noise(x/140+8,z/140)-.45),detail=8*noise(x/24,z/24)+2.5*noise(x/7,z/7),natural=55+large+detail+14*Math.sin(x/420-z/300);
 const ix=Math.floor(x/cell),iz=Math.floor(z/cell);let close=false;for(let a=-2;a<=2&&!close;a++)for(let b=-2;b<=2;b++)if(bins.has((ix+a)+','+(iz+b))){close=true;break;}if(!close)return natural;
 const p=nearest(x,z),d=p.distance;if(d>67)return natural;const f=p.s/length,village=smooth((f-.69)/.025)*(1-smooth((f-.84)/.025)),flat=4.15+village*20,blend=smooth((d-flat)/42);
 return mix(p.y,natural,blend);
}
const heightCache=new Map();function gridHeight(x,z){const k=x+','+z;if(heightCache.has(k))return heightCache.get(k);const y=height(x,z);if(heightCache.size>=80000){let n=0;for(const key of heightCache.keys()){heightCache.delete(key);if(++n===8000)break;}}heightCache.set(k,y);return y;}

const bounds={minX:-650,maxX:2050,minZ:-2250,maxZ:700};
root.WatchSteerRoute={length,step:ds,table,sample,nearest,nearby,height,gridHeight,region,wrap,bounds,noise,smooth};
})(typeof window==='undefined'?globalThis:window);
