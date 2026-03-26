import React from 'react';
import { Button } from '@/components/animate-ui/components/buttons/button';
import { Input } from '@/components/ui/input';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { Funnel } from 'lucide-react';
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
  return <div className="aui-compact" style={{ width: '100%' }}>
    <Select value={condition.matchTarget} onValueChange={(value) => onConditionChange({ matchTarget: value })}>
      <SelectTrigger style={{ width: 90 }}>
        <SelectValue />
      </SelectTrigger>
      <SelectContent style={{ minWidth: 160 }}>
        {MATCH_TARGET_OPTIONS.map((opt) => (
          <SelectItem key={opt.value} value={opt.value}>{opt.label}</SelectItem>
        ))}
      </SelectContent>
    </Select>
    <Select value={condition.matchMode} onValueChange={(value) => onConditionChange({ matchMode: value })}>
      <SelectTrigger style={{ width: 110 }}>
        <SelectValue />
      </SelectTrigger>
      <SelectContent style={{ minWidth: 180 }}>
        {MATCH_MODE_OPTIONS.map((opt) => (
          <SelectItem key={opt.value} value={opt.value}>{opt.label}</SelectItem>
        ))}
      </SelectContent>
    </Select>
    <Input
      style={{ flex: 1, minWidth: 0 }}
      value={condition.expression}
      onChange={(event) => onConditionChange({ expression: event.target.value })}
    />
    <Button
      variant="outline"
      size="icon-sm"
      onClick={onFilterClick}
    >
      <Funnel style={filterConfigured ? { color: '#FF8700' } : undefined} />
    </Button>
  </div>;
}
