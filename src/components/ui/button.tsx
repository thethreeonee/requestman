import * as React from 'react';
import { cn } from '@/lib/utils';

type ButtonVariant = 'default' | 'primary' | 'text' | 'link' | 'dashed';

type ButtonProps = React.ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: ButtonVariant;
  danger?: boolean;
};

export const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant = 'default', danger, ...props }, ref) => {
    return (
      <button
        className={cn(
          'aui-btn',
          variant !== 'default' ? `aui-btn-${variant}` : '',
          danger ? 'aui-btn-danger' : '',
          className,
        )}
        ref={ref}
        {...props}
      />
    );
  },
);
Button.displayName = 'Button';
