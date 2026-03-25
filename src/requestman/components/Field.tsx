import React from 'react';
import { motion } from 'motion/react';
import { cn } from '@/lib/utils';

export const FieldShell = React.forwardRef(function FieldShell(
  {
    addonAfter,
    children,
    className,
    disabled,
    style,
  }: any,
  ref: React.Ref<HTMLDivElement>,
) {
  return (
    <motion.div
      ref={ref}
      className={cn('aui-input-wrap', disabled && 'is-disabled', className)}
      style={style}
      initial={false}
      whileHover={disabled ? undefined : { y: -1 }}
      transition={{ type: 'spring', stiffness: 420, damping: 30 }}
    >
      {children}
      {addonAfter ? <span className="aui-input-addon">{addonAfter}</span> : null}
    </motion.div>
  );
});
