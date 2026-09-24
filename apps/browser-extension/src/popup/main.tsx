import React from 'react';
import ReactDOM from 'react-dom/client';
import '@/styles/globals.css';
import PopupApp from './PopupApp';
import { applyLocaleToDocument, t } from '../requestman/i18n';

if (window.matchMedia('(prefers-color-scheme: dark)').matches) {
  document.documentElement.classList.add('dark');
}

applyLocaleToDocument(t('Requestman', 'Requestman'));

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <PopupApp />
  </React.StrictMode>,
);
