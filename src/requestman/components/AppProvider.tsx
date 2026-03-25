import React from 'react';

type MessagePayload = string | { content: string; duration?: number };
type Notice = { id: string; type: 'success' | 'warning'; content: string };

type MessageApi = {
  success: (content: MessagePayload) => void;
  warning: (content: MessagePayload) => void;
};

const MessageContext = React.createContext<MessageApi>({
  success: () => undefined,
  warning: () => undefined,
});

function normalizeMessage(content: MessagePayload) {
  return typeof content === 'string'
    ? { content, duration: 1.6 }
    : { content: content.content, duration: content.duration ?? 1.6 };
}

function AppProvider({ children }: { children: React.ReactNode }) {
  const [notices, setNotices] = React.useState<Notice[]>([]);

  const pushNotice = React.useCallback((type: Notice['type'], payload: MessagePayload) => {
    const msg = normalizeMessage(payload);
    const id = `${Date.now()}-${Math.random()}`;
    setNotices((prev) => [...prev, { id, type, content: msg.content }]);
    window.setTimeout(() => {
      setNotices((prev) => prev.filter((item) => item.id !== id));
    }, Math.max(msg.duration, 0.6) * 1000);
  }, []);

  const api = React.useMemo<MessageApi>(() => ({
    success: (content) => pushNotice('success', content),
    warning: (content) => pushNotice('warning', content),
  }), [pushNotice]);

  return (
    <MessageContext.Provider value={api}>
      {children}
      <div className="aui-toast-stack">
        {notices.map((item) => <div key={item.id} className={`aui-toast aui-toast-${item.type}`}>{item.content}</div>)}
      </div>
    </MessageContext.Provider>
  );
}

type AppComponent = typeof AppProvider & {
  useApp: () => { message: MessageApi };
};

export const App = AppProvider as AppComponent;

App.useApp = function useApp() {
  return { message: React.useContext(MessageContext) };
};

export function ConfigProvider({ children }: { children: React.ReactNode; theme?: unknown }) {
  return <>{children}</>;
}
