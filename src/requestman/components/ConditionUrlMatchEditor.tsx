import React from 'react';
import { Button } from '@/components/animate-ui/components/buttons/button';
import { Input } from '.';
import { FilterOutlined } from '../icons';
import { MATCH_MODE_OPTIONS, MATCH_TARGET_OPTIONS } from '../constants';
import GroupDropdownSelect from './GroupDropdownSelect';
import type { RedirectCondition } from '../types';

type Props = {
  condition: RedirectCondition;
  filterConfigured: boolean;
  onConditionChange: (patch: Partial<RedirectCondition>) => void;
  onFilterClick: () => void;
};

export default function ConditionUrlMatchEditor({
  condition,
  filterConfigured,
  onConditionChange,
  onFilterClick,
}: Props) {
  return <div className="aui-compact" style={{ width: '100%' }}>
    <GroupDropdownSelect
      value={condition.matchTarget}
      options={MATCH_TARGET_OPTIONS as never}
      style={{ width: 90 }}
      contentMinWidth={160}
      onChange={(value) => onConditionChange({ matchTarget: value })}
    />
    <GroupDropdownSelect
      value={condition.matchMode}
      options={MATCH_MODE_OPTIONS as never}
      style={{ width: 110 }}
      contentMinWidth={180}
      onChange={(value) => onConditionChange({ matchMode: value })}
    />
    <Input
      style={{ flex: 1, minWidth: 0 }}
      value={condition.expression}
      onChange={(event) => onConditionChange({ expression: event.target.value })}
    />
    <Button
      variant="outline"
      size="icon"
      onClick={onFilterClick}
    >
      <FilterOutlined style={filterConfigured ? { color: '#FF8700' } : undefined} />
    </Button>
  </div>;
}
