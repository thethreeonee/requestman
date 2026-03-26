import React from 'react';
import ReactDOM from 'react-dom/client';
import '@/styles/globals.css';
import PopupApp from './PopupApp';

if (window.matchMedia('(prefers-color-scheme: dark)').matches) {
  document.documentElement.classList.add('dark');
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <PopupApp />
  </React.StrictMode>,
);
