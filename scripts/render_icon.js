const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch(); const p = await b.newPage({ viewport: { width: 1024, height: 1024 } });
  await p.goto('file://' + require('path').resolve(__dirname, '../assets/icon.svg') + ''); await p.screenshot({ path: '' + require('path').resolve(__dirname, '../assets/icon.png') + '' });
  await b.close();
})();
