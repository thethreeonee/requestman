import { Button as AnimateButton } from '@/components/animate-ui/components/buttons/button';

export function Button({ children, icon, type, ...rest }: any) {
  const variant = type === 'primary'
    ? 'default'
    : type === 'secondary'
      ? 'secondary'
      : type === 'text'
        ? 'ghost'
        : type === 'link'
          ? 'link'
          : type === 'dashed'
            ? 'outline'
            : 'outline';

  return <AnimateButton variant={variant} {...rest}>{icon}{children}</AnimateButton>;
}
