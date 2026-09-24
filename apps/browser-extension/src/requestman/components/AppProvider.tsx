import React from 'react';
import { toast } from 'sonner';
import { t } from '../i18n';

type NotificationPayload = string | { content: string; duration?: number; title?: string };

export type NotificationApi = {
  success: (content: NotificationPayload) => void;
  warning: (content: NotificationPayload) => void;
  error: (content: NotificationPayload) => void;
};

const DEFAULT_TITLES: Record<'success' | 'warning' | 'error', string> = {
  success: t('成功', 'Success'),
  warning: t('警告', 'Warning'),
  error: t('错误', 'Error'),
};

function normalize(type: 'success' | 'warning' | 'error', payload: NotificationPayload) {
  if (typeof payload === 'string') {
    return { title: DEFAULT_TITLES[type], content: payload, duration: 1600 };
  }
  return {
    title: payload.title ?? DEFAULT_TITLES[type],
    content: payload.content,
    duration: (payload.duration ?? 1.6) * 1000,
  };
}

const NotificationContext = React.createContext<NotificationApi>({
  success: () => undefined,
  warning: () => undefined,
  error: () => undefined,
});

function AppProvider({ children }: { children: React.ReactNode }) {
  const api = React.useMemo<NotificationApi>(() => ({
    success: (payload) => {
      const { title, content, duration } = normalize('success', payload);
      toast.success(title, { description: content, duration });
    },
    warning: (payload) => {
      const { title, content, duration } = normalize('warning', payload);
      toast.warning(title, { description: content, duration });
    },
    error: (payload) => {
      const { title, content, duration } = normalize('error', payload);
      toast.error(title, { description: content, duration });
    },
  }), []);

  return (
    <NotificationContext.Provider value={api}>
      {children}
    </NotificationContext.Provider>
  );
}

type AppComponent = typeof AppProvider & {
  useApp: () => { notification: NotificationApi };
};

export const App = AppProvider as AppComponent;

App.useApp = function useApp() {
  return { notification: React.useContext(NotificationContext) };
};

export function ConfigProvider({ children }: { children: React.ReactNode; theme?: unknown }) {
  return <>{children}</>;
}
