import React from 'react';
import { FieldShell } from './Field';

const InputBase = React.forwardRef(function InputBase(
  { addonAfter, className, style, ...props }: any,
  ref: React.Ref<HTMLInputElement>,
) {
  return (
    <FieldShell addonAfter={addonAfter} className={className} disabled={props.disabled} style={style}>
      <input ref={ref} className="aui-input" style={style} {...props} />
    </FieldShell>
  );
}) as any;

InputBase.TextArea = React.forwardRef(function TextArea(
  { className, style, ...props }: any,
  ref: React.Ref<HTMLTextAreaElement>,
) {
  return (
    <FieldShell className={className} disabled={props.disabled} style={style}>
      <textarea ref={ref} className="aui-textarea" style={style} {...props} />
    </FieldShell>
  );
});

export const Input = InputBase;

export function AutoComplete({ options = [], value, onChange, placeholder, style, children, disabled }: any) {
  const listId = React.useId();
  const child = React.isValidElement(children)
    ? React.cloneElement(children, {
      ...children.props,
      disabled: disabled ?? children.props.disabled,
      value,
      placeholder: placeholder ?? children.props.placeholder,
      style: { ...children.props.style, ...style },
      onChange: (event: React.ChangeEvent<HTMLInputElement>) => {
        children.props.onChange?.(event);
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
          onChange={(e: React.ChangeEvent<HTMLInputElement>) => onChange?.(e.target.value)}
          list={listId}
        />
      )}
      <datalist id={listId}>{options.map((o: any) => <option key={o.value} value={o.value} />)}</datalist>
    </>
  );
}

export const InputNumber = React.forwardRef(function InputNumber(
  { value, onChange, min, className, style, ...props }: any,
  ref: React.Ref<HTMLInputElement>,
) {
  return (
    <FieldShell className={className} disabled={props.disabled} style={style}>
      <input
        ref={ref}
        type="number"
        className="aui-input"
        style={style}
        value={value}
        min={min}
        onChange={(e) => onChange?.(Number(e.target.value))}
        {...props}
      />
    </FieldShell>
  );
});
