import { Switch as AnimateSwitch } from '@/components/animate-ui/components/radix/switch';
import {
  RadioGroup as AnimateRadioGroup,
  RadioGroupItem,
} from '@/components/animate-ui/components/radix/radio-group';

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

export function RadioGroup({ options = [], value, onChange }: any) {
  return (
    <AnimateRadioGroup value={value} onValueChange={(nextValue) => onChange?.({ target: { value: nextValue } })} className="aui-space">
      {options.map((opt: any) => (
        <label key={opt.value} className="flex items-center gap-2">
          <RadioGroupItem value={opt.value} />
          <span>{opt.label}</span>
        </label>
      ))}
    </AnimateRadioGroup>
  );
}

export function FieldGroup({ label, help, children, style }: any) {
  return (
    <label style={{ display: 'block', ...style }}>
      <div>{label}</div>
      {children}
      {help ? <div style={{ marginTop: 4, fontSize: 12, opacity: 0.75 }}>{help}</div> : null}
    </label>
  );
}
