import React from 'react';
import type { RedirectGroup, RedirectRule } from '../../types';
import type { NotificationApi } from '../../components/AppProvider';

export type RuleDetailProps = {
  groups: RedirectGroup[];
  workingRule: RedirectRule;
  originalRule: RedirectRule | null;
  isNewRule: boolean;
  setWorkingRule: React.Dispatch<React.SetStateAction<RedirectRule | null>>;
  setRules: React.Dispatch<React.SetStateAction<RedirectRule[]>>;
  onBack: () => void;
  saveDetailRule: () => void;
  toggleDetailRuleEnabled: (ruleId: string, enabled: boolean) => void;
  duplicateDetailRule: (ruleId: string) => void;
  deleteDetailRule: (ruleId: string) => void;
  renameRule: (ruleId: string, name: string) => void;
  moveRuleToGroupById: (ruleId: string, groupId: string) => void;
  setPageToList: () => void;
  notifyApi: Pick<NotificationApi, 'warning'>;
  onRename?: (name: string) => void;
};
