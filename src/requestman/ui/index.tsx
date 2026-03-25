import React from 'react';
import { Button as AnimateButton } from '@/components/animate-ui/components/buttons/button';
import { Switch as AnimateSwitch } from '@/components/animate-ui/components/radix/switch';

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
  return typeof content === 'string' ? { content, duration: 1.6 } : { content: content.content, duration: content.duration ?? 1.6 };
}

export function App({ children }: { children: React.ReactNode }) {
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

App.useApp = function useApp() {
  return { message: React.useContext(MessageContext) };
};

export function ConfigProvider({ children }: { children: React.ReactNode; theme?: unknown }) {
  return <>{children}</>;
}

export function Button({ children, icon, type, ...rest }: any) {
  const variant = type === 'primary'
    ? 'default'
    : type === 'text'
      ? 'ghost'
      : type === 'link'
        ? 'link'
        : type === 'dashed'
          ? 'outline'
          : 'outline';
  return <AnimateButton variant={variant} {...rest}>{icon}{children}</AnimateButton>;
}

function InputBase({ addonAfter, ...props }: any) {
  return <div className="aui-input-wrap"><input className="aui-input" {...props} />{addonAfter ? <span>{addonAfter}</span> : null}</div>;
}

InputBase.TextArea = function TextArea(props: any) {
  return <textarea className="aui-textarea" {...props} />;
};

export const Input = InputBase as any;

export function Select({ options = [], value, onChange, style, disabled, placeholder, ...rest }: any) {
  return (
    <select
      className="aui-select"
      value={value}
      onChange={(e) => onChange?.(e.target.value)}
      style={style}
      disabled={disabled}
      {...rest}
    >
      {placeholder ? <option value="" disabled>{placeholder}</option> : null}
      {options.map((item: any) => <option key={item.value} value={item.value}>{item.label}</option>)}
    </select>
  );
}

export function Switch({ checked, onChange, disabled }: any) {
  return (
    <AnimateSwitch checked={checked} onCheckedChange={onChange} disabled={disabled} />
  );
}

function SpaceBase({ children, direction, size, style, align }: any) {
  return <div className={`aui-space ${direction === 'vertical' ? 'vertical' : ''}`} style={{ gap: size ?? 8, alignItems: align, ...style }}>{children}</div>;
}

SpaceBase.Compact = function Compact({ children, style }: any) {
  return <div className="aui-compact" style={style}>{children}</div>;
};
SpaceBase.Addon = function Addon({ children, style }: any) {
  return <span className="aui-addon" style={style}>{children}</span>;
};

export const Space = SpaceBase as any;

export const Typography = {
  Text: ({ children, strong, type, style }: any) => <span style={{ fontWeight: strong ? 600 : 400, opacity: type === 'secondary' ? 0.7 : 1, ...style }}>{children}</span>,
  Paragraph: ({ children, style }: any) => <p style={style}>{children}</p>,
  Title: ({ children, level = 4, style }: any) => React.createElement(`h${level}`, { style }, children),
};

export function Modal({ open, title, children, onCancel, onOk }: any) {
  if (!open) return null;
  return (
    <div className="aui-modal-backdrop">
      <div className="aui-modal">
        <h3>{title}</h3>
        <div>{children}</div>
        <div className="aui-space">
          <Button onClick={onCancel}>Cancel</Button>
          <Button type="primary" onClick={onOk}>OK</Button>
        </div>
      </div>
    </div>
  );
}

Modal.confirm = ({ title, content, onOk }: any) => {
  if (window.confirm(`${title ?? ''}\n${content ?? ''}`)) onOk?.();
};

export function Segmented({ options, value, onChange }: any) {
  return <div className="aui-segmented">{options.map((o: any) => <Button key={o.value} type={o.value === value ? 'primary' : 'default'} onClick={() => onChange?.(o.value)}>{o.label}</Button>)}</div>;
}

export function Tooltip({ title, children }: any) { return <span title={typeof title === 'string' ? title : ''}>{children}</span>; }

export function Popconfirm({ title, onConfirm, children }: any) {
  return <span onClick={() => { if (window.confirm(title ?? 'Confirm?')) onConfirm?.(); }}>{children}</span>;
}

function RadioBase({ checked, onChange, value, children, name }: any) {
  return <label><input type="radio" checked={checked} value={value} name={name} onChange={(e) => onChange?.(e)} /> {children}</label>;
}

RadioBase.Group = function Group({ options = [], value, onChange }: any) {
  return <div className="aui-space">{options.map((opt: any) => <RadioBase key={opt.value} name="radio-group" value={opt.value} checked={opt.value === value} onChange={() => onChange?.({ target: { value: opt.value } })}>{opt.label}</RadioBase>)}</div>;
};

export const Radio = RadioBase as any;

export function Collapse({ items }: any) {
  return <div>{items?.map((item: any) => <details key={item.key} open><summary>{item.label}</summary>{item.children}</details>)}</div>;
}

export function Tabs({ items, activeKey, onChange }: any) {
  return <div><div className="aui-space">{items.map((item: any) => <Button key={item.key} type={item.key === activeKey ? 'primary' : 'default'} onClick={() => onChange?.(item.key)}>{item.label}</Button>)}</div><div>{items.find((item: any) => item.key === activeKey)?.children}</div></div>;
}

export function Dropdown({ menu, children }: any) {
  const [open, setOpen] = React.useState(false);
  return (
    <span className="aui-dropdown">
      <span onClick={() => setOpen((v) => !v)}>{children}</span>
      {open ? (
        <div className="aui-dropdown-menu">
          {(menu?.items ?? []).map((item: any) => {
            if (item?.type === 'divider') return <div className="aui-dropdown-divider" key={item.key ?? Math.random()} />;
            if (item?.type === 'group') {
              return (
                <div key={item.key} className="aui-dropdown-group">
                  <div className="aui-dropdown-group-label">{item.label}</div>
                  {(item.children ?? []).map((child: any) => (
                    <button className={`aui-dropdown-item ${child.danger ? 'danger' : ''}`} key={child.key} onClick={() => { child.onClick?.(); setOpen(false); }}>
                      {child.icon}{child.label}
                    </button>
                  ))}
                </div>
              );
            }
            return (
              <button className={`aui-dropdown-item ${item?.danger ? 'danger' : ''}`} key={item?.key} onClick={() => { item?.onClick?.(); setOpen(false); }}>
                {item?.icon}{item?.label}
              </button>
            );
          })}
        </div>
      ) : null}
    </span>
  );
}

export type MenuProps = { items: any[] };

export function Form({ children }: any) { return <div>{children}</div>; }
Form.Item = ({ label, children, style }: any) => <label style={{ display: 'block', ...style }}><div>{label}</div>{children}</label>;

export function Drawer({ open, title, onClose, children }: any) {
  if (!open) return null;
  return (
    <div className="aui-modal-backdrop">
      <div className="aui-drawer">
        <div className="aui-space" style={{ justifyContent: 'space-between' }}>
          <h3>{title}</h3>
          <Button type="text" onClick={onClose}>Close</Button>
        </div>
        {children}
      </div>
    </div>
  );
}

export function AutoComplete({ options = [], value, onChange, placeholder }: any) {
  return <><input list="aui-autocomplete" className="aui-input" value={value} onChange={(e) => onChange?.(e.target.value)} placeholder={placeholder} /><datalist id="aui-autocomplete">{options.map((o: any) => <option key={o.value} value={o.value} />)}</datalist></>;
}

export function InputNumber({ value, onChange, min }: any) {
  return <input type="number" className="aui-input" value={value} min={min} onChange={(e) => onChange?.(Number(e.target.value))} />;
}

export function Table<T extends { key: string }>({ dataSource, columns, rowClassName, onRow }: any) {
  return <table className="aui-table"><thead><tr>{columns.map((c: any) => <th key={c.title}>{c.title}</th>)}</tr></thead><tbody>{dataSource.map((row: T) => {
    const cls = rowClassName?.(row);
    const rowProps = onRow?.(row) ?? {};
    return <tr key={row.key} className={cls} {...rowProps}>{columns.map((c: any, idx: number) => <td key={idx} onClick={c.onCell?.(row)?.onClick} className={c.onCell?.(row)?.className}>{c.render ? c.render(undefined, row) : (row as any)[c.dataIndex]}</td>)}</tr>;
  })}</tbody></table>;
}
