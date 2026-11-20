/* Four-wheel raycast dynamics, route-aware cruise and finite rolling terrain. */
(function(root){
'use strict';const C=root.CANNON,R=root.WatchSteerRoute;
const clamp=(v,a,b)=>Math.max(a,Math.min(b,v));
class Vehicle {
 constructor(){
  this.world=new C.World({gravity:new C.Vec3(0,-9.81,0)});this.world.broadphase=new C.SAPBroadphase(this.world);this.world.solver.iterations=12;
  this.groundMaterial=new C.Material('ground');this.carMaterial=new C.Material('car');this.world.addContactMaterial(new C.ContactMaterial(this.groundMaterial,this.carMaterial,{friction:.55,restitution:.02}));
  this.body=new C.Body({mass:1100,material:this.carMaterial,linearDamping:.012,angularDamping:.3});this.body.addShape(new C.Box(new C.Vec3(.85,.23,1.85)),new C.Vec3(0,-.13,0));
  this.vehicle=new C.RaycastVehicle({chassisBody:this.body,indexRightAxis:0,indexUpAxis:1,indexForwardAxis:2});
  for(const z of [-1.25,1.25])for(const x of [-.80,.80])this.vehicle.addWheel({radius:.35,directionLocal:new C.Vec3(0,-1,0),axleLocal:new C.Vec3(-1,0,0),chassisConnectionPointLocal:new C.Vec3(x,.05,z),suspensionRestLength:.36,suspensionStiffness:38,dampingRelaxation:4.8,dampingCompression:2.7,frictionSlip:4.6,rollInfluence:.06,maxSuspensionForce:30000,maxSuspensionTravel:.24,customSlidingRotationalSpeed:-30,useCustomSlidingRotationalSpeed:true});
  this.vehicle.addToWorld(this.world);this.obstacles=[];this.terrainKey='';this.steering=0;this.odometer=0;this.progress=0;this.targetSpeed=0;this.reset();
 }
 ensureTerrain(x,z){
  const ox=Math.floor(x/48)*48-112,oz=Math.floor(z/48)*48+112,k=ox+','+oz;if(k===this.terrainKey)return;this.terrainKey=k;
  const data=[];for(let i=0;i<=112;i++){const col=[];for(let j=0;j<=112;j++)col.push(R.gridHeight(ox+i*2,oz-j*2));data.push(col);}
  const b=new C.Body({mass:0,material:this.groundMaterial});b.addShape(new C.Heightfield(data,{elementSize:2}));b.position.set(ox,0,oz);b.quaternion.setFromEuler(-Math.PI/2,0,0);
  this.world.addBody(b);if(this.terrain)this.world.removeBody(this.terrain);this.terrain=b;
 }
 setObstacles(items){
  for(const b of this.obstacles)this.world.removeBody(b);
  this.obstacles=items.map(p=>{const b=new C.Body({mass:0,material:this.groundMaterial});b.addShape(new C.Box(new C.Vec3(p.halfX||p.radius||.3,p.halfHeight||.9,p.halfZ||p.radius||.3)));b.position.set(p.x,p.y===undefined?R.height(p.x,p.z)+(p.halfHeight||.9):p.y,p.z);b.quaternion.setFromEuler(0,p.yaw||0,0);this.world.addBody(b);return b;});
 }
 reset(s=0){
  const p=R.sample(s);this.progress=s;this.near=R.nearest(p.x,p.z,s);this.steering=0;this.odometer=0;this.targetSpeed=0;
  this.ensureTerrain(p.x,p.z);this.body.position.set(p.x-p.nx*1.6,p.y+1.1,p.z-p.nz*1.6);this.body.quaternion.setFromEuler(0,Math.atan2(-p.tx,-p.tz),0);this.freeze();
  for(let i=0;i<4;i++)this.vehicle.setSteeringValue(0,i);
  for(let i=0;i<90;i++)this.world.step(1/120);this.freeze();this.near=R.nearest(this.body.position.x,this.body.position.z,this.progress);
 }
 freeze(){this.body.velocity.setZero();this.body.angularVelocity.setZero();this.body.force.setZero();this.body.torque.setZero();for(let i=0;i<4;i++){this.vehicle.applyEngineForce(0,i);this.vehicle.setBrake(0,i);}}
 step(input,dt){
  const pos=this.body.position;this.ensureTerrain(pos.x,pos.z);this.near=R.nearest(pos.x,pos.z,this.progress);this.progress=this.near.progress;
  const road=R.sample(this.progress),speed=this.body.velocity.length(),offroad=this.near.distance>3.7;
  const maxSteer=(.38*2.5/2.24)/(1+speed*.06),desired=clamp(input,-1,1)*maxSteer;this.steering+=(desired-this.steering)*(1-Math.exp(-dt/.075));for(let i=0;i<2;i++)this.vehicle.setSteeringValue(-this.steering,i);
  const forward=this.body.quaternion.vmult(new C.Vec3(0,0,-1)),v=this.body.velocity.dot(forward);
  const target=offroad?6:road.speed;this.targetSpeed=target;
  const error=target-v,force=clamp(error*1100+1100*9.81*forward.y+v*Math.abs(v)*.4,-4500,3900);
  const braking=v>target+.35?clamp((v-target)*1.8,0,4.2):0;
  for(let i=0;i<4;i++){this.vehicle.wheelInfos[i].frictionSlip=offroad?2.1:4.6;this.vehicle.applyEngineForce(i>=2?Math.max(0,force)/2:0,i);this.vehicle.setBrake(braking*1100*dt/4,i);}
  this.body.applyForce(new C.Vec3(-this.body.velocity.x*speed*.4,0,-this.body.velocity.z*speed*.4));
  const oldX=pos.x,oldZ=pos.z;this.world.step(dt);this.odometer+=Math.hypot(pos.x-oldX,pos.z-oldZ);
 }
 get state(){const p=this.body.position,q=this.body.quaternion,f=q.vmult(new C.Vec3(0,0,-1)),near=R.nearest(p.x,p.z,this.progress),road=R.sample(near.s);return {x:p.x,y:p.y,z:p.z,s:near.progress,offset:near.offset,heading:Math.atan2(f.x,-f.z),speed:this.body.velocity.length(),quaternion:q,steering:this.steering,offroad:near.distance>3.7,grounded:this.vehicle.wheelInfos.filter(w=>w.isInContact).length,suspension:this.vehicle.wheelInfos.map(w=>w.suspensionLength),sliding:this.vehicle.sliding,odometer:this.odometer,targetSpeed:this.targetSpeed,zone:road.zone,roadName:road.name};}
 wheelTransforms(){return this.vehicle.wheelInfos.map((w,i)=>{const contact=w.isInContact;this.vehicle.updateWheelTransform(i);w.isInContact=contact;return w.worldTransform;});}
}
root.WatchSteerPhysics={Vehicle,route:R};
})(typeof window==='undefined'?globalThis:window);
