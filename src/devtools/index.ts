const isFirefox = typeof navigator !== 'undefined' && /firefox/i.test(navigator.userAgent);

chrome.devtools.panels.create(
  isFirefox ? 'Requestman' : '🔄 Requestman',
  '',
  isFirefox ? '/requestman/index.html' : 'requestman/index.html',
);
