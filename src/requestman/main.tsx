import React from 'react';
import ReactDOM from 'react-dom/client';
import { App } from './components';
import '@/styles/globals.css';
import './index.css';
import RequestmanPanel from './RequestmanPanel';

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App>
      <RequestmanPanel />
    </App>
  </React.StrictMode>,
);
