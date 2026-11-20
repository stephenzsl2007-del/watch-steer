const assert=require('node:assert/strict');
require('../web/highland-route.js');globalThis.CANNON=require('../web/vendor/cannon-es.cjs.js');require('../web/vehicle-physics.js');
const R=WatchSteerRoute,{Vehicle}=WatchSteerPhysics,dt=1/120;
const angle=v=>Math.atan2(Math.sin(v),Math.cos(v));
function follow(v){const st=v.state,look=Math.max(7,st.speed*.65),p=R.sample(st.s+look),x=p.x-p.nx*1.6,z=p.z-p.nz*1.6,error=angle(Math.atan2(x-st.x,-(z-st.z))-st.heading),steer=Math.atan2(2*2.24*Math.sin(error),look);return Math.max(-1,Math.min(1,steer/(.38/(1+st.speed*.06))*1.1));}
assert(R.length>5900&&R.length<6300);assert(Math.max(...R.table.map(p=>Math.abs(p.grade)))<.086);
const a=R.sample(-.001),b=R.sample(.001);assert(Math.hypot(a.x-b.x,a.z-b.z,a.y-b.y)<.01,'loop surface continuous');assert(Math.hypot(a.tx-b.tx,a.tz-b.tz)<.005,'loop tangent continuous');
for(const p of R.table.filter((_,i)=>i%50===0)){const near=R.nearest(p.x,p.z,p.s);assert(near.distance<.02);assert(Math.abs(near.progress-p.s)<.03);}
assert(Math.max(...R.table.map(p=>p.speed))*3.6>99);assert(R.table.some(p=>p.limit*3.6<28));assert(R.table.filter(p=>p.zone==='village').every(p=>p.speed<=36/3.6+.001));
const car=new Vehicle();assert.equal(car.state.grounded,4);car.wheelTransforms();assert.equal(car.state.grounded,4,'render transforms preserve contact state');assert(car.state.suspension.every(n=>n>.1&&n<.5));
for(let i=0;i<600;i++)car.step(0,dt);assert(car.state.odometer>20&&car.state.speed>8);
const heading=car.state.heading;for(let i=0;i<80;i++)car.step(.35,dt);assert(angle(car.state.heading-heading)>.05,'right input turns right');
const left=new Vehicle();for(let i=0;i<600;i++)left.step(0,dt);const lh=left.state.heading;for(let i=0;i<80;i++)left.step(-.35,dt);assert(angle(left.state.heading-lh)<-.05,'left input turns left');
assert(car.state.suspension.some((n,i)=>Math.abs(n-car.state.suspension[(i+1)%4])>.005));car.freeze();assert.equal(car.state.speed,0);
const collision=new Vehicle(),p=R.sample(19);let hits=0;collision.setObstacles([{x:p.x-p.nx*1.6,z:p.z-p.nz*1.6,radius:3,halfHeight:3}]);collision.body.addEventListener('collide',e=>{if(collision.obstacles.includes(e.body))hits++});for(let i=0;i<900;i++)collision.step(0,dt);assert(hits>0,'physical roadside collision');assert(collision.state.s<24);
const v=new Vehicle();let grounded=0,maxSpeed=0,maxOffset=0,maxVillage=0,minCurve=Infinity,steps=0,maxBodies=0,firstLap=false;
for(let i=0;i<110000;i++){
 v.step(follow(v),dt);const st=v.state;grounded+=st.grounded>=3?1:0;maxSpeed=Math.max(maxSpeed,st.speed*3.6);maxOffset=Math.max(maxOffset,Math.abs(st.offset+1.6));if(st.zone==='village'&&R.sample(st.s-60).zone==='village')maxVillage=Math.max(maxVillage,st.speed*3.6);if(Math.abs(R.sample(st.s).curvature)>.04)minCurve=Math.min(minCurve,st.speed*3.6);maxBodies=Math.max(maxBodies,v.world.bodies.length);steps=i+1;
 assert(Number.isFinite(st.y)&&st.y>R.height(st.x,st.z)-.5,'no terrain penetration');
 if(i%10000===0)console.log('tour',i,Math.round(st.s),Math.round(st.speed*3.6),Math.round(st.offset*100)/100);
 if(st.s>R.length+25){firstLap=true;break;}
 if(Math.abs(st.offset)>15)throw new Error('route tracking failed at '+JSON.stringify(st));
}
assert(firstLap,'completed full loop including join');assert(maxSpeed>=85,'actual straight speed >=85 km/h');assert(maxVillage<42,'village braking');assert(grounded/steps>.97,'wheels stay grounded');assert.equal(maxBodies,2,'terrain body count bounded');assert(maxOffset<2.0,'test controller remains in lane');
const report={length:R.length,seconds:steps*dt,maxSpeed,maxVillage,minCurve,maxOffset,groundedRatio:grounded/steps,maxBodies};console.log(JSON.stringify(report,null,2));console.log('PASS: full highland route, cruise, braking, steering, suspension, collision, ground continuity and bounded world');
