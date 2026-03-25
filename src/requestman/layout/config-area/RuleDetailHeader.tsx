import React from 'react';
import RuleDetailToolbar from '../../components/RuleDetailToolbar';
import type { RuleDetailProps } from './types';

type Props = Pick<
  RuleDetailProps,
  'groups' | 'workingRule' | 'originalRule' | 'setWorkingRule' | 'saveDetailRule'
> & {
  onTest: () => void;
};

export default function RuleDetailHeader({
  groups,
  workingRule,
  originalRule,
  setWorkingRule,
  saveDetailRule,
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
      dirty={dirty}
      onGroupChange={(value) => setWorkingRule({ ...workingRule, groupId: value })}
      onRename={(name) => setWorkingRule({ ...workingRule, name })}
      onTest={onTest}
      onSave={saveDetailRule}
    />
  );
}
