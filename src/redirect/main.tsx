import React from 'react';
import ReactDOM from 'react-dom/client';
import { App } from 'antd';
import 'antd/dist/reset.css';
import './index.css';
import RedirectPanel from './RedirectPanel';

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App>
      <RedirectPanel />
    </App>
  </React.StrictMode>,
);
