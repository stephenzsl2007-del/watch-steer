/* Original, procedural interpretations of four classics. Metres; front=-Z; common drive chassis. */
(function(root){
'use strict';
const T=root.THREE;
const catalog=[
 {id:'f40',brand:'FERRARI',name:'Ferrari F40',year:'1987',color:'#c82324',length:4.36,width:1.98,height:1.12,kind:'wedge',rim:'five',note:'楔形车身 · 高位尾翼 · 五辐轮毂'},
 {id:'250gto',brand:'FERRARI',name:'Ferrari 250 GTO',year:'1962',color:'#b92524',length:4.32,width:1.88,height:1.20,kind:'gto',rim:'wire',note:'长车头 · 圆润翼子板 · 钢丝轮毂'},
 {id:'db5',brand:'ASTON MARTIN',name:'Aston Martin DB5',year:'1963',color:'#b5b8ac',length:4.46,width:1.88,height:1.29,kind:'classic',rim:'wire',note:'圆灯 · 镀铬格栅 · 经典 GT 轮廓'},
 {id:'db9',brand:'ASTON MARTIN',name:'Aston Martin DB9',year:'2004',color:'#27554b',length:4.65,width:1.96,height:1.26,kind:'modern',rim:'split',note:'低伏车头 · 流线车顶 · 双辐轮毂'}
];
function mergeStatic(group){
 group.updateMatrixWorld(true);const inverse=group.matrixWorld.clone().invert(),batches=new Map(),old=[];
 group.traverse(o=>{if(!o.isMesh)return;const g=o.geometry.index?o.geometry.toNonIndexed():o.geometry.clone();g.applyMatrix4(new T.Matrix4().multiplyMatrices(inverse,o.matrixWorld));if(!g.attributes.normal)g.computeVertexNormals();if(!batches.has(o.material))batches.set(o.material,[]);batches.get(o.material).push(g);old.push(o);});
 for(const o of old){o.removeFromParent();o.geometry.dispose();}
 for(const [mat,gs]of batches){const count=gs.reduce((n,g)=>n+g.attributes.position.count,0),p=new Float32Array(count*3),normal=new Float32Array(count*3),uv=new Float32Array(count*2);let offset=0;for(const g of gs){p.set(g.attributes.position.array,offset*3);normal.set(g.attributes.normal.array,offset*3);if(g.attributes.uv)uv.set(g.attributes.uv.array,offset*2);offset+=g.attributes.position.count;g.dispose();}const g=new T.BufferGeometry();g.setAttribute('position',new T.BufferAttribute(p,3));g.setAttribute('normal',new T.BufferAttribute(normal,3));g.setAttribute('uv',new T.BufferAttribute(uv,2));g.computeBoundingSphere();const mesh=new T.Mesh(g,mat);mesh.castShadow=!mat.transparent;mesh.receiveShadow=true;group.add(mesh);}
}
function make(id){
 const spec=catalog.find(c=>c.id===id)||catalog[0],body=new T.Group(),paint=new T.MeshPhysicalMaterial({color:spec.color,metalness:.32,roughness:.26,clearcoat:1,clearcoatRoughness:.15,envMapIntensity:.7}),materials={paint};
 const mat=(color,opts={})=>new T.MeshStandardMaterial({color,roughness:.6,...opts});
 const chrome=mat('#c5cbd0',{metalness:.92,roughness:.2}),black=mat('#111719',{roughness:.83,side:T.DoubleSide}),rubber=mat('#202425',{roughness:.96}),seam=mat('#282c2b'),glass=new T.MeshPhysicalMaterial({color:'#a9c4cc',metalness:.06,roughness:.11,clearcoat:1,transparent:true,opacity:.40,side:T.DoubleSide,depthWrite:false}),lamp=mat('#9cabb1',{emissive:'#fff4d5',emissiveIntensity:.10,metalness:.18,roughness:.15}),red=mat('#a80e15',{emissive:'#b60a0a',emissiveIntensity:.28,roughness:.2}),amber=mat('#b97c24',{emissive:'#f38b0a',emissiveIntensity:.16}),leather=mat(spec.kind==='classic'?'#73513d':spec.kind==='modern'?'#855d40':'#292c2b',{roughness:.88});
 function mesh(g,m,parent=body,x=0,y=0,z=0){const o=new T.Mesh(g,m);o.position.set(x,y,z);o.castShadow=!m.transparent;o.receiveShadow=true;parent.add(o);return o;}
 function box(w,h,d,m,x,y,z,parent=body){return mesh(new T.BoxGeometry(w,h,d),m,parent,x,y,z);}
 function ball(x,y,z,sx,sy,sz,m,parent=body){const o=mesh(new T.SphereGeometry(1,24,12),m,parent,x,y,z);o.scale.set(sx,sy,sz);return o;}
 function line(points,r,m,parent=body,closed=false){return mesh(new T.TubeGeometry(new T.CatmullRomCurve3(points.map(p=>new T.Vector3(...p)),closed,'centripetal'),Math.max(12,points.length*6),r,6,closed),m,parent);}
 function face(points,m,parent=body){const g=new T.BufferGeometry();g.setAttribute('position',new T.Float32BufferAttribute(points.flat(),3));const indices=[];for(let i=1;i<points.length-1;i++)indices.push(0,i,i+1);g.setIndex(indices);g.computeVertexNormals();const o=mesh(g,m,parent);return o;}
 function disc(x,y,z,r,depth,m,axis='z',parent=body){const o=mesh(new T.CylinderGeometry(r,r,depth,40),m,parent,x,y,z);o.rotation[axis==='x'?'z':'x']=Math.PI/2;return o;}
 const half=spec.length/2,wide=spec.width/2,axles=[-1.25,1.25];
 const sections=spec.kind==='wedge'?[
 [-half,.91,.39,.40],[-1.95,.96,.49,.54],[-1.5,wide,.64,.73],[-1.25,wide,.65,.74],[-.8,.94,.65,.68],[0,.94,.64,.67],[.8,wide,.71,.73],[1.25,wide,.74,.76],[1.95,.96,.72,.72],[half,.91,.65,.66]
 ]:[[-half,spec.kind==='modern'?.78:.55,.52,.53],[-half+.22,.80,.57,.62],[-1.65,wide*.97,.63,.70],[-1.25,wide,.66,.70],[-.7,wide*.92,.65,.66],[0,wide*.93,.63,.67],[.75,wide*.98,.67,.70],[1.25,wide,.69,.72],[1.8,wide*.94,.67,.68],[half,spec.kind==='modern'?.90:.78,.70,.70]];
 const cat=(a,b,c,d,t)=>.5*((2*b)+(-a+c)*t+(2*a-5*b+4*c-d)*t*t+(-a+3*b-3*c+d)*t*t*t);
 function profile(z){let i=0;while(i<sections.length-2&&sections[i+1][0]<z)i++;const b=sections[i],c=sections[i+1],t=(z-b[0])/(c[0]-b[0]);return [0,1,2,3].map(k=>k===0?z:cat(sections[Math.max(0,i-1)][k],b[k],c[k],sections[Math.min(sections.length-1,i+2)][k],t));}
 function topSurface(x,z){const pr=profile(z),w=pr[1],d=pr[2],h=pr[3]+axles.reduce((n,a)=>n+.14*Math.exp(-(((z-a)/.48)**2)),0),b=.18,points=[[0,d],[w*.52,d+.025],[w*.87,h],[w,h-.05],[w,b+.09],[w*.88,b],[0,b],[-w*.88,b],[-w,b+.09],[-w,h-.05],[-w*.87,h],[-w*.52,d+.025]],curve=new T.CatmullRomCurve3(points.map(p=>new T.Vector3(p[0],p[1],0)),true,'centripetal');let lo=0,hi=.25;for(let i=0;i<16;i++){const t=(lo+hi)/2;if(curve.getPoint(t).x<Math.min(Math.abs(x),w*.999))lo=t;else hi=t;}return curve.getPoint((lo+hi)/2).y;}
 const positions=[],uv=[],indices=[],rings=200,sides=48;
 for(let i=0;i<=rings;i++){
  const z=-half+i/rings*spec.length,pr=profile(z),w=pr[1],d=pr[2],shoulder=pr[3]+axles.reduce((n,a)=>n+.14*Math.exp(-(((z-a)/.48)**2)),0),bottom=.18;
  const cross=[[0,d],[w*.52,d+.025],[w*.87,shoulder],[w,shoulder-.05],[w,bottom+.09],[w*.88,bottom],[0,bottom],[-w*.88,bottom],[-w,bottom+.09],[-w,shoulder-.05],[-w*.87,shoulder],[-w*.52,d+.025]].map(p=>new T.Vector3(p[0],p[1],0));
  const curve=new T.CatmullRomCurve3(cross,true,'centripetal');
  for(let j=0;j<=sides;j++){const p=curve.getPoint(j/sides),weight=Math.max(0,Math.min(1,(Math.abs(p.x)/w-.63)/.23));let arch=bottom;for(const axle of axles){const dist=Math.abs(z-axle);if(dist<.43)arch=Math.max(arch,.35+Math.sqrt(.43*.43-dist*dist));}p.y=Math.max(p.y,arch*weight+bottom*(1-weight));positions.push(p.x,p.y,z);uv.push(j/sides,i/rings);}
 }
 for(let i=0;i<rings;i++)for(let j=0;j<sides;j++){const a=i*(sides+1)+j,b=a+sides+1;indices.push(a,b,a+1,a+1,b,b+1);}
 const hull=new T.BufferGeometry();hull.setAttribute('position',new T.Float32BufferAttribute(positions,3));hull.setAttribute('uv',new T.Float32BufferAttribute(uv,2));hull.setIndex(indices);hull.computeVertexNormals();mesh(hull,paint);
 // End panels and dark undertray close the loft without replacing the wheel openings.
 for(const side of [-1,1]){const ring=side<0?0:rings,pr=profile(side*half),p=[0,(pr[2]+.18)/2,side*half],idx=[];for(let j=0;j<=sides;j++){const i=(ring*(sides+1)+j)*3;p.push(positions[i],positions[i+1],positions[i+2]);}for(let j=0;j<sides;j++)idx.push(...(side<0?[0,j+1,j+2]:[0,j+2,j+1]));const g=new T.BufferGeometry();g.setAttribute('position',new T.Float32BufferAttribute(p,3));g.setIndex(idx);g.computeVertexNormals();mesh(g,paint);}
 box(1.35,.07,spec.length-.7,black,0,.19,0);
 for(const side of [-1,1])for(const z of axles){const x=side*(profile(z)[1]+.005);const arch=mesh(new T.TorusGeometry(.425,.012,6,56,Math.PI),spec.kind==='classic'?chrome:paint,body,x,.35,z);arch.rotation.y=Math.PI/2;}
 // Independent roof, windscreen, side glass and rear glass with a visible two-seat cabin.
 const roofFront=spec.kind==='wedge'?-.48:spec.kind==='gto'?-.28:-.40,roofRear=spec.kind==='wedge'?.56:spec.kind==='classic'?.8:.70,roofY=spec.height-.05,baseFront=spec.kind==='gto'?-.78:-.98,baseRear=spec.kind==='classic'?1.35:1.52,roofW=spec.kind==='wedge'?.64:.62;
 const cabin=[[-roofW,roofY,roofFront],[roofW,roofY,roofFront],[roofW,roofY,roofRear],[-roofW,roofY,roofRear]];
 if(spec.kind==='wedge'){face(cabin.slice().reverse(),paint);}
 else{const rp=[],ri=[];for(let i=0;i<=28;i++){const t=i/28,z=roofFront+(roofRear-roofFront)*t;for(let j=0;j<=20;j++){const u=j/20,x=(u-.5)*roofW*2,y=roofY+.075*Math.sin(Math.PI*t)+.065*Math.sin(Math.PI*u);rp.push(x,y,z);}}for(let i=0;i<28;i++)for(let j=0;j<20;j++){const a=i*21+j;ri.push(a,a+21,a+1,a+1,a+21,a+22);}const rg=new T.BufferGeometry();rg.setAttribute('position',new T.Float32BufferAttribute(rp,3));rg.setIndex(ri);rg.computeVertexNormals();mesh(rg,paint);}
 const frontGlass=[[-.77,.73,baseFront],[.77,.73,baseFront],[roofW,roofY-.025,roofFront],[-roofW,roofY-.025,roofFront]],rearGlass=[[-roofW,roofY-.02,roofRear],[roofW,roofY-.02,roofRear],[.76,profile(baseRear)[2]+.02,baseRear],[-.76,profile(baseRear)[2]+.02,baseRear]];
 face(frontGlass,glass);face(rearGlass,glass);line(frontGlass,.018,spec.kind==='classic'?chrome:black,body,true);line(rearGlass,.016,spec.kind==='classic'?chrome:black,body,true);
 for(const side of [-1,1]){
  const windowPoints=[[side*.80,.73,baseFront+.10],[side*roofW,roofY-.02,roofFront+.04],[side*roofW,roofY-.02,roofRear-.05],[side*.79,.75,baseRear-.10]];
  face(windowPoints,glass);line(windowPoints,.019,spec.kind==='classic'?chrome:paint,body,true);line([[side*roofW,roofY,roofRear-.24],[side*.79,.73,roofRear+.05]],.018,spec.kind==='classic'?chrome:black);
  // Door seams follow the changing body width rather than a flat rectangle.
  const door=[[-.58,.71],[-.48,.31],[.65,.31],[.92,.72]].map(([z,y])=>[side*(profile(z)[1]+.008),y,z]);line(door,.004,seam);
  box(.04,.035,.16,chrome,side*(profile(.65)[1]+.02),.70,.65);
  if(spec.kind!=='gto'){ball(side*1.01,.83,-.58,.11,.065,.085,spec.kind==='classic'?chrome:paint);ball(side*1.075,.834,-.58,.009,.045,.06,chrome);}
 }
 for(const side of [-1,1]){
  ball(side*.35,.48,.35,.23,.09,.28,leather);const seat=ball(side*.35,.74,.64,.22,.28,.075,leather);seat.rotation.x=-.13;ball(side*.35,.99,.66,.12,.065,.055,leather);for(const offset of [-.17,.17])ball(side*.35+offset,.65,.58,.06,.22,.10,leather);
  line([[side*.20,.49,.38],[side*.20,.68,.64],[side*.20,.91,.66]],.012,black);
 }
 box(1.38,.16,.25,leather,0,.73,-.62);box(.20,.22,.56,black,0,.52,.0);disc(0,.72,.14,.025,.15,chrome,'z');
 const steeringWheel=new T.Group();steeringWheel.position.set(spec.brand==='FERRARI'?-.35:.35,.82,-.36);steeringWheel.rotation.x=-.23;body.add(steeringWheel);mesh(new T.TorusGeometry(.135,.012,8,32),black,steeringWheel);for(let i=0;i<3;i++){const spoke=box(.012,.128,.01,chrome,0,.064,0,steeringWheel);spoke.rotation.z=i*2*Math.PI/3;}disc(0,0,0,.037,.018,black,'z',steeringWheel);
 for(let i=-1;i<=1;i++){disc((spec.brand==='FERRARI'?-.35:.35)+i*.085,.80,-.484,.037,.008,chrome);disc((spec.brand==='FERRARI'?-.35:.35)+i*.085,.80,-.478,.030,.009,black);}
 // Distinctive front/rear identity, intake architecture and exhaust arrangements.
 function roundLamp(x,y,z,r=.12,m=lamp){disc(x,y,z,r+.018,.035,chrome);disc(x,y,z+(z<0?-.025:.025),r,.045,m);}
 if(spec.kind==='wedge'){
  box(1.75,.12,.045,black,0,.30,-half-.025);for(const side of [-1,1]){box(.42,.13,.055,lamp,side*.66,.34,-half-.03);line([[side*.40,-1.97],[side*.75,-1.97],[side*.75,-1.57],[side*.4,-1.57]].map(([x,z])=>[x,topSurface(x,z)+.006,z]),.004,seam,body,true);face([[side*.20,-1.67],[side*.34,-1.39],[side*.12,-1.40]].map(([x,z])=>[x,topSurface(x,z)+.009,z]),black);box(.075,.16,.36,black,side*.972,.57,.60);box(.055,.08,.55,black,side*.986,.56,1.12);for(const x of [.58,.80])roundLamp(side*x,.57,half+.035,.09,red);box(.13,.36,.12,paint,side*.88,.98,1.77);}
  box(2.02,.065,.38,paint,0,1.17,1.80);for(const side of [-1,1]){box(.23,.10,.42,red,side*.21,.73,1.1);for(let i=0;i<4;i++)disc(side*.21,.79,.96+i*.09,.018,.012,chrome,'z');}box(1.80,.14,.04,black,0,.43,half+.04);for(let i=0;i<9;i++)box(1.10,.022,.028,black,0,.82-i*.009,.74+i*.075);for(const x of [-.11,0,.11]){disc(x,.26,half+.075,.049,.12,chrome);disc(x,.26,half+.14,.035,.012,black);}
 }else if(spec.kind==='gto'){
  ball(0,.37,-half-.017,.45,.16,.035,chrome);ball(0,.37,-half-.052,.41,.12,.025,black);for(let i=-4;i<=4;i++)box(.014,.18,.018,chrome,i*.08,.37,-half-.075);
  for(const side of [-1,1]){ball(side*.67,.60,-1.76,.20,.23,.35,paint);ball(side*.67,.69,-1.94,.15,.14,.19,chrome);ball(side*.67,.70,-1.985,.135,.13,.18,lamp);for(let i=0;i<3;i++)box(.012,.12,.12,black,side*(profile(-.70+i*.13)[1]+.012),.61,-.70+i*.13);roundLamp(side*.63,.53,half+.03,.085,red);roundLamp(side*.80,.53,half+.02,.055,amber);disc(side*.62,.25,half+.07,.048,.15,chrome);disc(side*.62,.25,half+.15,.034,.01,black);}
  for(const x of [-.23,0,.23])ball(x,.57,-1.99,.075,.033,.07,black);box(1.25,.045,.13,paint,0,.72,half-.06);
 }else{
  // Aston's wide, tapered radiator opening and horizontal brightwork.
  const mouth=[[-.63,.48,-half-.036],[-.48,.30,-half-.045],[.48,.30,-half-.045],[.63,.48,-half-.036]];face(mouth,black);line(mouth,.018,chrome,body,true);for(let i=0;i<6;i++)box(1.02+i*.027,.010,.025,chrome,0,.32+i*.028,-half-.059);
  for(const side of [-1,1]){
   if(spec.kind==='classic'){ball(side*.66,.57,-half+.34,.18,.23,.23,paint);roundLamp(side*.66,.64,-half+.12,.13);roundLamp(side*.37,.36,-half-.02,.075);for(let i=0;i<3;i++)roundLamp(side*.67,.42+i*.105,half+.04,.045,i===1?amber:red);line([[side*.82,.37,-half+.07],[side*.52,.28,-half-.07],[side*.20,.27,-half-.07]],.035,chrome);line([[side*.82,.33,half-.06],[side*.52,.27,half+.07],[side*.20,.27,half+.07]],.035,chrome);}
   else{const head=[[side*.48,-2.10],[side*.80,-1.97],[side*.82,-1.69],[side*.65,-1.82]].map(([x,z])=>[x,topSurface(x,z)+.012,z]);face(head,lamp);line(head,.008,chrome,body,true);for(const x of [.61,.73])ball(side*x,topSurface(side*x,-1.91)+.02,-1.91,.040,.025,.065,lamp);const tail=[[side*(profile(half-.15)[1]+.015),.61,half-.15],[side*.81,.63,half+.025],[side*.50,.61,half+.035],[side*.30,.59,half+.035]];line(tail,.029,black);line(tail.map(p=>[p[0]+side*.008,p[1],p[2]+.025]),.023,red);}
   for(let i=0;i<3;i++)box(.02,.014,.32,chrome,side*(profile(-.60)[1]+.016),.64+i*.032,-.60);disc(side*.65,.24,half+.06,.060,.16,chrome);disc(side*.65,.24,half+.15,.043,.012,black);
  }
  line([[-.13,.67,-1.65],[0,.70,-1.90],[.13,.67,-1.65]],.012,chrome);
 }
 // Plate, model script and a small bonnet badge; graphics are drawn locally.
 function textTexture(text,color,bg,w=512,h=96){const c=document.createElement('canvas');c.width=w;c.height=h;const ctx=c.getContext('2d');ctx.fillStyle=bg;ctx.fillRect(0,0,w,h);ctx.font='500 42px sans-serif';ctx.textAlign='center';ctx.textBaseline='middle';ctx.fillStyle=color;ctx.fillText(text,w/2,h/2);const t=new T.CanvasTexture(c);t.colorSpace=T.SRGBColorSpace;return t;}
 const plateMat=mat('#ffffff',{map:textTexture(spec.id==='250gto'?'GTO 62':spec.id.toUpperCase()+' GT','#292d2b','#d9d3b3'),roughness:.45});box(.43,.115,.025,plateMat,0,.42,half+.075);
 const scriptMat=new T.MeshBasicMaterial({map:textTexture(spec.brand,'#e2dfc7','#171c1d'),side:T.DoubleSide});const script=mesh(new T.PlaneGeometry(.53,.075),scriptMat,body,0,.62,half+.065);if(spec.kind==='wedge')script.position.y=.59;
 const badge=box(.052,.008,.075,spec.brand==='FERRARI'?mat('#d3ab2a'):chrome,0,profile(-1.60)[2]+.015,-1.60);
 // Keep the steering wheel separate from static batching so it can turn with live input.
 steeringWheel.removeFromParent();mergeStatic(body);body.add(steeringWheel);body.position.y=-.60;
 const wheel=new T.Group(),rimRadius=spec.rim==='split'?.252:.230;
 const tireProfile=[[.225,-.125],[.29,-.125],[.337,-.102],[.35,-.075],[.35,.075],[.337,.102],[.29,.125],[.225,.125]].map(p=>new T.Vector2(...p));const tire=mesh(new T.LatheGeometry(tireProfile,64),rubber,wheel);tire.rotation.z=Math.PI/2;
 for(const side of [-1,1]){
  const lip=mesh(new T.TorusGeometry(rimRadius,.014,8,64),chrome,wheel,side*.125,0,0);lip.rotation.y=Math.PI/2;disc(side*.075,0,0,rimRadius*.87,.018,mat('#7b8285',{metalness:.8,roughness:.42}),'x',wheel);
  if(spec.rim==='wire'){
   for(let i=0;i<56;i++){const a=i/56*Math.PI*2,finish=a+.36;line([[side*.125,.046*Math.cos(a),.046*Math.sin(a)],[side*.12,(rimRadius-.015)*Math.cos(finish),(rimRadius-.015)*Math.sin(finish)]],.0025,chrome,wheel);}
  }else{
   const count=spec.rim==='five'?5:10;for(let i=0;i<count;i++){const a=i/count*Math.PI*2;const spoke=box(.035,.19,spec.rim==='five'?.052:.022,chrome,side*.125,.132*Math.cos(a),.132*Math.sin(a),wheel);spoke.rotation.x=a;}
  }
  disc(side*.143,0,0,.047,.027,chrome,'x',wheel);for(let i=0;i<5;i++){const a=i*Math.PI*2/5;disc(side*.144,.067*Math.cos(a),.067*Math.sin(a),.008,.014,black,'x',wheel);}
  // Sidewall bead and shallow tread channels remain geometry at inspection distance.
  for(const rr of [.307,.319]){const ring=mesh(new T.TorusGeometry(rr,.002,4,64),black,wheel,side*.122,0,0);ring.rotation.y=Math.PI/2;}
 }
 mergeStatic(wheel);const wheels=Array.from({length:4},()=>wheel.clone(true));
 const calipers=wheels.map(w=>{const p=new T.Group();w.add(p);box(.085,.12,.09,spec.brand==='FERRARI'?mat('#a11818'):mat('#454b4c'),0,.17,.12,p);return p;});
 return {spec,body,wheels,setPaint(color){paint.color.set(color);},update(steering,braking,rotations){steeringWheel.rotation.z=-steering*8;red.emissiveIntensity=braking?1.7:.28;calipers.forEach((c,i)=>{c.rotation.x=rotations[i]||0;});}};
}
root.WatchSteerCars={catalog,make};
})(typeof window==='undefined'?globalThis:window);
