import type React from 'react';

export type RequestmanDropdownMenuBaseItem = {
  key?: React.Key;
  label?: React.ReactNode;
  icon?: React.ReactNode;
  danger?: boolean;
  disabled?: boolean;
  onClick?: () => void;
  onMouseEnter?: React.MouseEventHandler;
  onMouseLeave?: React.MouseEventHandler;
};

export type RequestmanDropdownMenuDividerItem = {
  key?: React.Key;
  type: 'divider';
};

export type RequestmanDropdownMenuGroupItem = {
  key?: React.Key;
  type: 'group';
  label?: React.ReactNode;
  children?: RequestmanDropdownMenuBaseItem[];
};

export type RequestmanDropdownMenuItem =
  | RequestmanDropdownMenuBaseItem
  | RequestmanDropdownMenuDividerItem
  | RequestmanDropdownMenuGroupItem;
