import { t } from '../requestman/i18n';

const isFirefox = typeof navigator !== 'undefined' && /firefox/i.test(navigator.userAgent);

chrome.devtools.panels.create(
  isFirefox ? t('Requestman', 'Requestman') : `🔀 ${t('Requestman', 'Requestman')}`,
  '',
  isFirefox ? '/requestman/index.html' : 'requestman/index.html',
);
