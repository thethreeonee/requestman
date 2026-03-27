import React from 'react';
import RuleDetailToolbar from '../../components/RuleDetailToolbar';
import type { RuleDetailProps } from './types';

type Props = Pick<
  RuleDetailProps,
  'groups'
  | 'workingRule'
  | 'originalRule'
  | 'isNewRule'
  | 'setWorkingRule'
  | 'saveDetailRule'
  | 'toggleDetailRuleEnabled'
  | 'duplicateDetailRule'
  | 'deleteDetailRule'
> & {
  onTest: () => void;
};

export default function RuleDetailHeader({
  groups,
  workingRule,
  originalRule,
  isNewRule,
  setWorkingRule,
  saveDetailRule,
  toggleDetailRuleEnabled,
  duplicateDetailRule,
  deleteDetailRule,
  onTest,
}: Props) {
  const { enabled: _workingEnabled, ...workingRuleWithoutEnabled } = workingRule;
  const { enabled: _originalEnabled, ...originalRuleWithoutEnabled } = originalRule ?? workingRule;
  const dirty = !!originalRule && JSON.stringify(workingRuleWithoutEnabled) !== JSON.stringify(originalRuleWithoutEnabled);

  return (
    <RuleDetailToolbar
      rule={workingRule}
      groups={groups}
      groupId={workingRule.groupId}
      isNewRule={isNewRule}
      dirty={dirty}
      onGroupChange={(value) => setWorkingRule({ ...workingRule, groupId: value })}
      onEnabledChange={(enabled) => toggleDetailRuleEnabled(workingRule.id, enabled)}
      onRename={(name) => setWorkingRule({ ...workingRule, name })}
      onDuplicate={() => duplicateDetailRule(workingRule.id)}
      onDelete={() => deleteDetailRule(workingRule.id)}
      onTest={onTest}
      onSave={saveDetailRule}
    />
  );
}
