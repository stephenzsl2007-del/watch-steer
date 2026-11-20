// Record only explicit simulated input; no pairing credentials or desktop chrome.
const {chromium}=require('playwright');
const {spawn}=require('node:child_process');
const {randomBytes}=require('node:crypto');
const fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'..'),port=Number(process.env.WATCHSTEER_RECORD_PORT||8892);
const url='http://127.0.0.1:'+port,out=path.join(root,'work/demo-frames'),media=path.join(root,'docs/media');
fs.mkdirSync(out,{recursive:true});fs.mkdirSync(media,{recursive:true});
const server=spawn(process.env.PYTHON||'python3',['backend/server.py','--port',String(port),'--origin',url],{cwd:root,env:{...process.env,WATCHSTEER_TOKEN:randomBytes(32).toString('hex')},stdio:'ignore'});
const sleep=ms=>new Promise(r=>setTimeout(r,ms));let browser;
(async()=>{try{
 for(let i=0;i<40;i++){try{if((await fetch(url+'/healthz')).ok)break;}catch{}await sleep(100);}
 const gpu=process.env.WATCHSTEER_GPU_TEST==='1';
 browser=await chromium.launch(gpu?{headless:true,channel:'chromium',args:['--use-angle=metal','--enable-gpu']}:{headless:true,args:['--enable-unsafe-swiftshader']});
 const page=await browser.newPage({viewport:{width:1440,height:1080},deviceScaleFactor:1});
 const errors=[];page.on('pageerror',e=>errors.push(e.message));page.setDefaultTimeout(60000);
 await page.goto(url);await page.waitForFunction(()=>document.querySelector('#drive-scene').dataset.ready==='true');
 await page.getByLabel('选择路段').selectOption('0.49');
 await page.getByRole('button',{name:'键盘试驾',exact:true}).click();
 await page.evaluate(()=>{window.demoController=setInterval(()=>{
  const d=document.querySelector('#drive-scene').dataset;if(d.running!=='true')return;
  const v=Number(d.speed),look=Math.max(7,v*.65),p=WatchSteerRoute.sample(Number(d.distance)+look);
  const error=Math.atan2(p.x-p.nx*1.6-Number(d.x),-(p.z-p.nz*1.6-Number(d.z)))-Number(d.heading);
  const steer=Math.atan2(2*2.24*Math.sin(error),look)/(.38/(1+v*.06))*1.1;
  const slider=document.querySelector('#manual');slider.value=Math.max(-1,Math.min(1,steer));slider.dispatchEvent(new Event('input',{bubbles:true}));
 },40);});
 await page.waitForTimeout(3500);
 const shell=page.locator('.drive-shell');
 await shell.screenshot({path:path.join(media,'driving.png')});
 for(let i=0;i<60;i++){
  await shell.screenshot({path:path.join(out,String(i).padStart(3,'0')+'.png')});
  await page.waitForTimeout(65);
 }
 await page.evaluate(()=>clearInterval(window.demoController));
 await page.getByLabel('选择车型',{exact:true}).selectOption('db5');
 await page.getByRole('button',{name:'午夜蓝',exact:true}).click();
 await page.getByRole('button',{name:'查看车辆',exact:true}).click();
 const rect=await page.locator('#drive-scene canvas').boundingBox();
 await page.mouse.move(rect.x+rect.width*.55,rect.y+rect.height*.5);await page.mouse.down();
 await page.mouse.move(rect.x+rect.width*.28,rect.y+rect.height*.57,{steps:18});await page.mouse.up();
 await page.waitForTimeout(1200);await shell.screenshot({path:path.join(media,'garage.png')});
 if(errors.length)throw new Error(errors.join('\n'));
 console.log('Recorded 60 simulation frames and two curated screenshots.');
}finally{if(browser)await browser.close();server.kill('SIGTERM');}})().catch(e=>{console.error(e);process.exitCode=1;});
