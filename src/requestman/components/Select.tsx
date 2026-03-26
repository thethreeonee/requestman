import React from 'react';

type FlatOption = { label: React.ReactNode; value: string };
type GroupOption = { label: string; options: FlatOption[]; key?: string };
type SelectOption = FlatOption | GroupOption;

function isGroupOption(item: SelectOption): item is GroupOption {
  return Array.isArray((item as GroupOption).options);
}

export function Select({
  options = [],
  value,
  onChange,
  style,
  disabled,
  placeholder,
  ...rest
}: {
  options?: SelectOption[];
  value?: string;
  onChange?: (value: string) => void;
  style?: React.CSSProperties;
  disabled?: boolean;
  placeholder?: string;
  [key: string]: unknown;
}) {
  return (
    <select
      className="aui-select"
      value={value ?? ''}
      onChange={(e) => onChange?.(e.target.value)}
      style={style}
      disabled={disabled}
      {...rest}
    >
      {placeholder ? <option value="" disabled>{placeholder}</option> : null}
      {options.map((item, i) =>
        isGroupOption(item) ? (
          <optgroup key={item.key ?? item.label ?? i} label={item.label}>
            {item.options.map((opt) => (
              <option key={opt.value} value={opt.value}>{opt.label}</option>
            ))}
          </optgroup>
        ) : (
          <option key={item.value} value={item.value}>{item.label}</option>
        ),
      )}
    </select>
  );
}
