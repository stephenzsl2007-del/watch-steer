const fs = require('node:fs');
const path = require('node:path');
const output = path.resolve(__dirname, '../work/test-results');
fs.mkdirSync(output, {recursive: true});
const launchOptions = () => process.env.WATCHSTEER_GPU_TEST === '1'
  ? {headless: true, channel: 'chromium', args: ['--use-angle=metal', '--enable-gpu']}
  : {headless: true, args: ['--enable-unsafe-swiftshader']};
module.exports = {output, launchOptions};
