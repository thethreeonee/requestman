import React from 'react';
import { Button, Input, Select, Space } from 'antd';
import { FilterOutlined } from '@ant-design/icons';
import { MATCH_MODE_OPTIONS, MATCH_TARGET_OPTIONS } from '../constants';
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
  return <Space.Compact style={{ width: '100%' }}>
    <Select
      value={condition.matchTarget}
      options={MATCH_TARGET_OPTIONS as never}
      style={{ width: 90 }}
      onChange={(value) => onConditionChange({ matchTarget: value })}
    />
    <Select
      value={condition.matchMode}
      options={MATCH_MODE_OPTIONS as never}
      style={{ width: 110 }}
      onChange={(value) => onConditionChange({ matchMode: value })}
    />
    <Input
      style={{ flex: 1, minWidth: 0 }}
      value={condition.expression}
      onChange={(event) => onConditionChange({ expression: event.target.value })}
    />
    <Button
      icon={<FilterOutlined style={filterConfigured ? { color: '#DD5927' } : undefined} />}
      onClick={onFilterClick}
    />
  </Space.Compact>;
}
