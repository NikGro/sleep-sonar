// Rendert assets/icon.svg (Suya-Logo, Vektor) als 1024×1024-PNG für App-Symbol und SideStore.
const { chromium } = require('playwright');
const path = require('path');
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1024, height: 1024 } });
  await p.goto('file://' + path.resolve(__dirname, '../assets/icon.svg'));
  await p.screenshot({ path: path.resolve(__dirname, '../assets/icon.png') });
  await b.close();
})();
