import React from 'react';
import { ArrowUpRight } from 'lucide-react';
import { motion, type Transition } from 'motion/react';

type NotificationPayload = string | { content: string; duration?: number; title?: string };
type Notice = {
  id: string;
  type: 'success' | 'warning' | 'error';
  title: string;
  content: string;
};

export type NotificationApi = {
  success: (content: NotificationPayload) => void;
  warning: (content: NotificationPayload) => void;
  error: (content: NotificationPayload) => void;
};

const NotificationContext = React.createContext<NotificationApi>({
  success: () => undefined,
  warning: () => undefined,
  error: () => undefined,
});

const DEFAULT_TITLES: Record<Notice['type'], string> = {
  success: 'Success',
  warning: 'Warning',
  error: 'Error',
};

function normalizeNotification(type: Notice['type'], content: NotificationPayload) {
  if (typeof content === 'string') {
    return {
      title: DEFAULT_TITLES[type],
      content,
      duration: 1.6,
    };
  }

  return {
    title: content.title ?? DEFAULT_TITLES[type],
    content: content.content,
    duration: content.duration ?? 1.6,
  };
}

const transition: Transition = {
  type: 'spring',
  stiffness: 300,
  damping: 26,
};

const textSwitchTransition: Transition = {
  duration: 0.22,
  ease: 'easeInOut',
};

const notificationTextVariants = {
  collapsed: { opacity: 1, y: 0, pointerEvents: 'auto' as const },
  expanded: { opacity: 0, y: -16, pointerEvents: 'none' as const },
};

const viewAllTextVariants = {
  collapsed: { opacity: 0, y: 16, pointerEvents: 'none' as const },
  expanded: { opacity: 1, y: 0, pointerEvents: 'auto' as const },
};

const getCardVariants = (i: number) => ({
  collapsed: {
    marginTop: i === 0 ? 0 : -44,
    scaleX: 1 - i * 0.05,
  },
  expanded: {
    marginTop: i === 0 ? 0 : 4,
    scaleX: 1,
  },
});

function AppProvider({ children }: { children: React.ReactNode }) {
  const [notices, setNotices] = React.useState<Notice[]>([]);

  const pushNotice = React.useCallback((type: Notice['type'], payload: NotificationPayload) => {
    const msg = normalizeNotification(type, payload);
    const id = `${Date.now()}-${Math.random()}`;
    setNotices((prev) => [...prev, { id, type, title: msg.title, content: msg.content }]);
    window.setTimeout(() => {
      setNotices((prev) => prev.filter((item) => item.id !== id));
    }, Math.max(msg.duration, 0.6) * 1000);
  }, []);

  const api = React.useMemo<NotificationApi>(() => ({
    success: (content) => pushNotice('success', content),
    warning: (content) => pushNotice('warning', content),
    error: (content) => pushNotice('error', content),
  }), [pushNotice]);

  return (
    <NotificationContext.Provider value={api}>
      {children}
      {notices.length > 0 ? (
        <div className="pointer-events-none fixed top-3 right-3 z-[1100]" aria-live="polite" aria-label="Notifications">
          <motion.div
            className="w-xs space-y-3 rounded-3xl bg-neutral-200 p-3 shadow-md dark:bg-neutral-900"
            initial="collapsed"
            whileHover="expanded"
          >
            <div>
              {notices.map((item, i) => (
                <motion.div
                  key={item.id}
                  className="relative rounded-xl bg-neutral-100 px-4 py-2 shadow-sm transition-shadow duration-200 hover:shadow-lg dark:bg-neutral-800"
                  variants={getCardVariants(i)}
                  transition={transition}
                  style={{ zIndex: notices.length - i }}
                >
                  <div className="flex items-center justify-between gap-3">
                    <h1 className="text-sm font-medium">{item.title}</h1>
                    <span className="text-xs font-medium text-neutral-500 capitalize dark:text-neutral-300">{item.type}</span>
                  </div>
                  <div className="text-xs font-medium text-neutral-500 dark:text-neutral-300">
                    <span>{item.content}</span>
                  </div>
                </motion.div>
              ))}
            </div>

            <div className="flex items-center gap-2">
              <div className="flex size-5 items-center justify-center rounded-full bg-neutral-400 text-xs font-medium text-white">
                {notices.length}
              </div>
              <span className="grid">
                <motion.span
                  className="row-start-1 col-start-1 text-sm font-medium text-neutral-600 dark:text-neutral-300"
                  variants={notificationTextVariants}
                  transition={textSwitchTransition}
                >
                  Notifications
                </motion.span>
                <motion.span
                  className="row-start-1 col-start-1 flex items-center gap-1 text-sm font-medium text-neutral-600 dark:text-neutral-300"
                  variants={viewAllTextVariants}
                  transition={textSwitchTransition}
                >
                  View all <ArrowUpRight className="size-4" />
                </motion.span>
              </span>
            </div>
          </motion.div>
        </div>
      ) : null}
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
