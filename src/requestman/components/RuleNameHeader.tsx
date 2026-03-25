import React from 'react';
import type { RedirectRule } from '../types';

type Props = {
  rule: RedirectRule;
  editRuleName: boolean;
  setEditRuleName: React.Dispatch<React.SetStateAction<boolean>>;
  setWorkingRule: React.Dispatch<React.SetStateAction<RedirectRule | null>>;
};

export default function RuleNameHeader({ rule, editRuleName, setEditRuleName, setWorkingRule }: Props) {
  void rule;
  void editRuleName;
  void setEditRuleName;
  void setWorkingRule;
  return null;
}
