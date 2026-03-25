import React from 'react';
import { Switch as AnimateSwitch } from '@/components/animate-ui/components/radix/switch';

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

export function Switch({ checked, onChange, disabled, ...rest }: any) {
  return <AnimateSwitch checked={checked} onCheckedChange={onChange} disabled={disabled} {...rest} />;
}

function RadioBase({ checked, onChange, value, children, name }: any) {
  return <label><input type="radio" checked={checked} value={value} name={name} onChange={(e) => onChange?.(e)} /> {children}</label>;
}

RadioBase.Group = function Group({ options = [], value, onChange }: any) {
  return <div className="aui-space">{options.map((opt: any) => <RadioBase key={opt.value} name="radio-group" value={opt.value} checked={opt.value === value} onChange={() => onChange?.({ target: { value: opt.value } })}>{opt.label}</RadioBase>)}</div>;
};

export const Radio = RadioBase as any;

export function Form({ children }: any) {
  return <div>{children}</div>;
}

Form.Item = ({ label, children, style }: any) => <label style={{ display: 'block', ...style }}><div>{label}</div>{children}</label>;
