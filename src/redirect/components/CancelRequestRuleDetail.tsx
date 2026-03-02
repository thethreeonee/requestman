import React from 'react';
import RuleDetailPlaceholder from './RuleDetailPlaceholder';
import type { RedirectGroup, RedirectRule } from '../types';

type Props = {
  groups: RedirectGroup[];
  workingRule: RedirectRule;
  originalRule: RedirectRule | null;
  setWorkingRule: React.Dispatch<React.SetStateAction<RedirectRule | null>>;
  setRules: React.Dispatch<React.SetStateAction<RedirectRule[]>>;
  onBack: () => void;
  saveDetailRule: () => void;
  toggleDetailRuleEnabled: (ruleId: string, enabled: boolean) => void;
  setPageToList: () => void;
};

export default function CancelRequestRuleDetail({ groups, workingRule, originalRule, setWorkingRule, setRules, onBack, saveDetailRule, toggleDetailRuleEnabled, setPageToList }: Props) {
  return <RuleDetailPlaceholder
    groups={groups}
    workingRule={workingRule}
    originalRule={originalRule}
    setWorkingRule={setWorkingRule}
    setRules={setRules}
    onBack={onBack}
    saveDetailRule={saveDetailRule}
    toggleDetailRuleEnabled={toggleDetailRuleEnabled}
    setPageToList={setPageToList}
    title="取消请求"
  />;
}
