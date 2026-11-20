// Optional browser QA: npm install --no-save playwright; npx playwright install chromium
const { chromium } = require('playwright');
const {output, launchOptions} = require('./browser-runtime.cjs');
const { spawn } = require('node:child_process');
const { randomBytes } = require('node:crypto');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const token = randomBytes(24).toString('hex');
const port = Number(process.env.WATCHSTEER_TEST_PORT || 8877);
const url = `http://127.0.0.1:${port}`;
const server = spawn(process.env.PYTHON || 'python3', ['backend/server.py', '--port', String(port), '--origin', url],
  {cwd: root, env: {...process.env, WATCHSTEER_TOKEN: token}, stdio: 'ignore'});
let browser;
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
(async () => {
  try {
    let ready = false;
    for (let i=0;i<30;i++) {
      try { ready = (await fetch(url+'/healthz')).ok; if (ready) break; } catch {}
      await wait(100);
    }
    assert(ready, 'local backend ready');
    console.log('Backend ready; launching test browser');
    browser = await chromium.launch({...launchOptions(), timeout:20000});
    // A fresh browser opened from the Mac receiver pairs without entering the device token.
    const issued = await fetch(url+'/api/browser-ticket',{method:'POST',
      headers:{'Content-Type':'application/json','Authorization':'Bearer '+token},body:'{}'});
    assert.equal(issued.status,200);
    const {ticket}=await issued.json();
    const autoContext=await browser.newContext();
    const autoPage=await autoContext.newPage();
    await autoPage.goto(url+'/#connect='+ticket);
    await autoPage.waitForFunction(()=>document.querySelector('#pair-message').textContent.includes('已配对'));
    assert.equal(new URL(autoPage.url()).hash,'');
    assert.equal(await autoPage.locator('#token').inputValue(),'');
    assert.equal(await autoPage.evaluate(()=>localStorage.length),0);
    const autoCookie=(await autoContext.cookies()).find(c=>c.name==='watchsteer');
    assert(autoCookie.httpOnly && autoCookie.sameSite==='Strict');
    await autoContext.close();
    const page = await browser.newPage({viewport:{width:1440,height:1100}, deviceScaleFactor:1});
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    page.setDefaultTimeout(60000);
    await page.goto(url, {timeout:60000});
    await page.waitForFunction(()=>document.querySelector('#drive-scene').dataset.ready==='true');
    await page.getByRole('button',{name:'键盘试驾',exact:true}).click();
    await page.waitForFunction(()=>Number(document.querySelector('#drive-scene').dataset.distance)>1);
    assert.equal(await page.locator('#drive-source').textContent(),'键盘试驾 · 模拟输入');
    assert.equal(await page.locator('#drive-scene').getAttribute('data-engine'),'cannon-es');
    assert(Number(await page.locator('#drive-scene').getAttribute('data-grounded'))>=3,'physical tires contact terrain');
    await page.getByRole('button',{name:'光照：雨后晴隙'}).click();
    assert(await page.getByRole('button',{name:'光照：晴昼'}).isVisible());
    await page.getByRole('button',{name:'光照：晴昼'}).click();
    await page.getByRole('button',{name:'光照：薄雾'}).click();
    for(const [value,zone] of [['0.27','pass'],['0.49','highland'],['0.73','village'],['0','valley']]){
      await page.getByLabel('选择路段').selectOption(value);
      await page.waitForFunction(zone=>document.querySelector('#drive-scene').dataset.zone===zone,zone);
    }
    await page.getByRole('button',{name:'画质：高清'}).click();
    await page.getByRole('button',{name:'画质：流畅'}).click();
    await page.getByRole('button',{name:'暂停',exact:true}).focus();
    const heading=Number(await page.locator('#drive-scene').getAttribute('data-heading'));
    await page.keyboard.down('ArrowRight');
    await page.waitForTimeout(250);
    assert(Number(await page.locator('#drive-scene').getAttribute('data-heading'))>heading,'right input changes car heading');
    await page.keyboard.up('ArrowRight');
    await page.getByRole('button',{name:'回到起点'}).click();
    await page.getByLabel('开启本机演示').check();
    await page.locator('#manual').evaluate(node => {node.value='0.5';node.dispatchEvent(new Event('input',{bubbles:true}));});
    await page.waitForFunction(() => Number(document.querySelector('#steering').textContent) > .49);
    assert.equal(await page.locator('#status').textContent(), '本机演示');
    await page.screenshot({path:path.join(output,'preview.png'),fullPage:true});
    await page.getByLabel('开启本机演示').uncheck();
    await page.locator('#token').fill(token);
    await page.getByRole('button',{name:'连接 ↗'}).click();
    await page.waitForFunction(() => document.querySelector('#pair-message').textContent.includes('已配对'));
    let seq=0;
    let publishing=true;
    const publish = async () => {
      while(publishing) {
        const r=await fetch(url+'/api/steer',{method:'POST',headers:{'Content-Type':'application/json','Authorization':'Bearer '+token},
          body:JSON.stringify({session:'browser-test-session',seq:++seq,steering:-.75,angleDeg:-45,sampleHz:50,sampleAgeMs:2,rttMs:12,calibrated:true})});
        assert.equal(r.status,200);
        await wait(50);
      }
    };
    const sender=publish();
    await page.waitForFunction(() => Number(document.querySelector('#steering').textContent) < -.74);
    assert.equal(await page.locator('#status').textContent(),'手表已连接');
    await page.getByRole('button',{name:/^(继续驾驶|开始驾驶)$/}).click();
    await page.waitForFunction(()=>document.querySelector('#drive-scene').dataset.running==='true' && Number(document.querySelector('#drive-scene').dataset.steering)<-.7);
    const beforeLeft=Number(await page.locator('#drive-scene').getAttribute('data-heading'));
    await page.waitForTimeout(400);
    assert(Number(await page.locator('#drive-scene').getAttribute('data-heading'))<beforeLeft,'watch left input turns vehicle left');
    await page.screenshot({path:path.join(output,'driving.png'),fullPage:true});
    publishing=false; await sender;
    await page.waitForFunction(() => document.querySelector('#status').textContent === '等待新鲜数据');
    await page.waitForFunction(() => Math.abs(Number(document.querySelector('#steering').textContent)) < .01);
    await page.waitForFunction(()=>document.querySelector('#drive-scene').dataset.running==='false');
    const stopped=Number(await page.locator('#drive-scene').getAttribute('data-distance'));
    await page.waitForTimeout(350);
    assert.equal(Number(await page.locator('#drive-scene').getAttribute('data-distance')),stopped,'lost watch data pauses vehicle');
    assert.equal(await page.evaluate(() => localStorage.length),0);
    const cookie=(await page.context().cookies()).find(c=>c.name==='watchsteer');
    assert(cookie.httpOnly && cookie.sameSite === 'Strict');
    const downloadPromise=page.waitForEvent('download');
    await page.getByRole('button',{name:'导出诊断 CSV ↓'}).click();
    const download=await downloadPromise;
    assert.equal(download.suggestedFilename(),'watchsteer-diagnostics.csv');
    await page.setViewportSize({width:390,height:844});
    await page.screenshot({path:path.join(output,'preview-mobile.png'),fullPage:true});
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),'mobile has no horizontal overflow');
    assert(await page.locator('.brand-icon').evaluate(img => img.complete && img.naturalWidth > 0),'logo loaded');
    const local = await browser.newPage();
    await local.goto(require('node:url').pathToFileURL(path.join(root,'web/index.html')).href);
    assert.equal(await local.locator('body').evaluate(node => getComputedStyle(node).backgroundColor),'rgb(16, 22, 19)');
    assert(await local.locator('#token').isDisabled(),'file preview explains connection requirement');
    await local.getByLabel('开启本机演示').check();
    await local.locator('#manual').evaluate(node => {node.value='0.3';node.dispatchEvent(new Event('input',{bubbles:true}));});
    await local.waitForFunction(() => Number(document.querySelector('#steering').textContent) > .29);
    await local.close();
    assert.deepEqual(errors,[]);
    console.log('PASS: 3D driving, keyboard/right + watch/left steering, pause-on-stale, demo, pairing, HTTP→SSE→wheel, stale neutral, cookie, CSV, responsive layout, no JS errors, direct-file demo');
  } finally {
    if(browser) await browser.close();
    server.kill('SIGTERM');
  }
})().catch(error=>{console.error(error);process.exitCode=1;});
