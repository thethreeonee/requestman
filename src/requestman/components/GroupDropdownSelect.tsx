import React from 'react';
import { ChevronsUpDown } from 'lucide-react';
import { Button } from '.';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuTrigger,
} from '@/components/animate-ui/components/radix/dropdown-menu';

type GroupDropdownSelectOption = {
  value: string;
  label: React.ReactNode;
};

type Props = {
  options: GroupDropdownSelectOption[];
  value?: string;
  onChange?: (value: string) => void;
  placeholder?: React.ReactNode;
  disabled?: boolean;
  style?: React.CSSProperties;
  contentStyle?: React.CSSProperties;
  contentMinWidth?: number | string;
  className?: string;
};

export default function GroupDropdownSelect({
  options,
  value,
  onChange,
  placeholder,
  disabled,
  style,
  contentStyle,
  contentMinWidth,
  className,
}: Props) {
  const selectedOption = options.find((item) => item.value === value);
  const triggerLabel = selectedOption?.label ?? placeholder ?? '';
  const isDisabled = disabled || options.length === 0;

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild disabled={isDisabled}>
        <span className="group-dropdown-select" style={style}>
          <Button
            type="dashed"
            className={`group-dropdown-select__trigger${className ? ` ${className}` : ''}`}
            disabled={isDisabled}
          >
            <span className="group-dropdown-select__inner">
              <span className={`group-dropdown-select__label${selectedOption ? '' : ' is-placeholder'}`}>{triggerLabel}</span>
              <ChevronsUpDown size={14} />
            </span>
          </Button>
        </span>
      </DropdownMenuTrigger>
      <DropdownMenuContent
        align="start"
        sideOffset={6}
        className="group-dropdown-select__content"
        style={{
          minWidth: 'var(--radix-dropdown-menu-trigger-width)',
          ...(contentMinWidth != null ? { width: 'max-content', minWidth: contentMinWidth } : { width: 'var(--radix-dropdown-menu-trigger-width)' }),
          ...contentStyle,
        }}
      >
        <DropdownMenuRadioGroup value={value} onValueChange={onChange}>
          {options.map((item) => (
            <DropdownMenuRadioItem
              key={item.value}
              value={item.value}
              className="group-dropdown-select__item"
            >
              <span className="group-dropdown-select__item-label">{item.label}</span>
            </DropdownMenuRadioItem>
          ))}
        </DropdownMenuRadioGroup>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
