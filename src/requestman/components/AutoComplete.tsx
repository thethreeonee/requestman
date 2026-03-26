import React from 'react';
import { Input } from '@/components/ui/input';

export function AutoComplete({ options = [], value, onChange, placeholder, style, children, disabled }: {
  options?: { value: string }[];
  value?: string;
  onChange?: (value: string) => void;
  placeholder?: string;
  style?: React.CSSProperties;
  children?: React.ReactElement;
  disabled?: boolean;
  [key: string]: unknown;
}) {
  const listId = React.useId();
  const child = React.isValidElement(children)
    ? React.cloneElement(children as React.ReactElement<any>, {
      disabled: disabled ?? (children as React.ReactElement<any>).props.disabled,
      value,
      placeholder: placeholder ?? (children as React.ReactElement<any>).props.placeholder,
      style: { ...(children as React.ReactElement<any>).props.style, ...style },
      onChange: (event: React.ChangeEvent<HTMLInputElement>) => {
        (children as React.ReactElement<any>).props.onChange?.(event);
        onChange?.(event.target.value);
      },
      list: listId,
    })
    : null;

  return (
    <>
      {child ?? (
        <Input
          value={value}
          disabled={disabled}
          placeholder={placeholder}
          style={style}
          onChange={(e) => onChange?.(e.target.value)}
          list={listId}
        />
      )}
      <datalist id={listId}>{options.map((o) => <option key={o.value} value={o.value} />)}</datalist>
    </>
  );
}
