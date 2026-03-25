import React from 'react';
import type { RedirectGroup, RedirectRule } from '../../types';
import type { NotificationApi } from '../../components/AppProvider';

export type RuleDetailProps = {
  groups: RedirectGroup[];
  workingRule: RedirectRule;
  originalRule: RedirectRule | null;
  setWorkingRule: React.Dispatch<React.SetStateAction<RedirectRule | null>>;
  setRules: React.Dispatch<React.SetStateAction<RedirectRule[]>>;
  onBack: () => void;
  saveDetailRule: () => void;
  toggleDetailRuleEnabled: (ruleId: string, enabled: boolean) => void;
  setPageToList: () => void;
  notifyApi: Pick<NotificationApi, 'warning'>;
  onRename?: (name: string) => void;
};
