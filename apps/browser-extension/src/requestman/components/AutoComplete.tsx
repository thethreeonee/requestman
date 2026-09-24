import React from 'react';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@/components/animate-ui/components/radix/dropdown-menu';
import { AnimateIcon } from '@/components/animate-ui/icons/icon';
import { Ellipsis } from '@/components/animate-ui/icons/ellipsis';
import {
  InputGroup,
  InputGroupAddon,
  InputGroupInput,
} from '@/components/ui/input-group';
import { t } from '../i18n';

export function AutoComplete({
  options = [],
  value,
  onChange,
  placeholder,
  style,
  disabled,
  inputStyle,
  filterOption: _filterOption,
  ...inputProps
}: {
  options?: { value: string }[];
  value?: string;
  onChange?: (value: string) => void;
  placeholder?: string;
  style?: React.CSSProperties;
  disabled?: boolean;
  inputStyle?: React.CSSProperties;
  filterOption?: boolean;
  [key: string]: unknown;
}) {
  const [open, setOpen] = React.useState(false);

  const menuOptions = React.useMemo(() => {
    const seen = new Set<string>();

    return options
      .filter((option) => {
        const optionValue = option.value.trim();
        if (!optionValue || seen.has(optionValue)) return false;
        seen.add(optionValue);
        return true;
      })
      .sort((a, b) => a.value.localeCompare(b.value))
      .slice(0, 50);
  }, [options]);

  return (
    <div style={style}>
      <InputGroup>
        <InputGroupInput
          value={value}
          disabled={disabled}
          placeholder={placeholder}
          autoComplete="off"
          style={inputStyle}
          onChange={(event) => onChange?.(event.target.value)}
          {...inputProps}
        />
        <InputGroupAddon align="inline-end">
          <DropdownMenu open={open} onOpenChange={setOpen} modal={false}>
            <DropdownMenuTrigger asChild>
              <button
                type="button"
                aria-label={t('选择 Header', 'Select header')}
                disabled={disabled}
                data-slot="input-group-control"
                className="inline-flex size-6 items-center justify-center rounded-[calc(var(--radius)-3px)] text-muted-foreground transition-colors hover:bg-muted hover:text-foreground disabled:pointer-events-none disabled:opacity-50"
              >
                <AnimateIcon animateOnHover asChild>
                  <span style={{ display: 'inline-flex', color: 'var(--muted-foreground)' }}>
                    <Ellipsis size={14} animation="pulse" />
                  </span>
                </AnimateIcon>
              </button>
            </DropdownMenuTrigger>
            <DropdownMenuContent
              align="end"
              className="z-[60] min-w-[220px]"
              side="bottom"
              sideOffset={4}
              avoidCollisions={false}
              collisionPadding={0}
            >
              <div
                style={{ maxHeight: 240, overflowY: 'auto', overscrollBehavior: 'contain' }}
                onWheel={(event) => event.stopPropagation()}
              >
                {menuOptions.length > 0 ? menuOptions.map((option) => (
                  <DropdownMenuItem
                    key={option.value}
                    onClick={() => {
                      onChange?.(option.value);
                      setOpen(false);
                    }}
                  >
                    {option.value}
                  </DropdownMenuItem>
                )) : (
                  <DropdownMenuItem
                    disabled
                  >
                    {t('没有匹配的 Header', 'No matching headers')}
                  </DropdownMenuItem>
                )}
              </div>
            </DropdownMenuContent>
          </DropdownMenu>
        </InputGroupAddon>
      </InputGroup>
    </div>
  );
}
