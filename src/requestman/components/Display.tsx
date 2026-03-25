import React from 'react';
import { Button } from './Button';

export const Typography = {
  Text: ({ children, strong, type, style }: any) => <span style={{ fontWeight: strong ? 600 : 400, opacity: type === 'secondary' ? 0.7 : 1, ...style }}>{children}</span>,
  Paragraph: ({ children, style }: any) => <p style={style}>{children}</p>,
  Title: ({ children, level = 4, style }: any) => React.createElement(`h${level}`, { style }, children),
};

export function Collapse({ items }: any) {
  return <div>{items?.map((item: any) => <details key={item.key} open><summary>{item.label}</summary>{item.children}</details>)}</div>;
}

export function Tabs({ items, activeKey, onChange }: any) {
  return <div><div className="aui-space">{items.map((item: any) => <Button key={item.key} type={item.key === activeKey ? 'primary' : 'default'} onClick={() => onChange?.(item.key)}>{item.label}</Button>)}</div><div>{items.find((item: any) => item.key === activeKey)?.children}</div></div>;
}
