import React from 'react';
import ReactDOM from 'react-dom/client';
import { App, ConfigProvider } from './primitives';
import '@/styles/globals.css';
import './index.css';
import RequestmanPanel from './RequestmanPanel';

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <ConfigProvider
      theme={{
        token: {
          colorPrimary: '#FF8700',
        },
      }}
    >
      <App>
        <RequestmanPanel />
      </App>
    </ConfigProvider>
  </React.StrictMode>,
);
