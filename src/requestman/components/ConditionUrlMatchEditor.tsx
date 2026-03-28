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
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from '@/components/animate-ui/components/radix/tooltip';
import { Badge } from '@/components/ui/badge';
import { Funnel } from 'lucide-react';
import { MATCH_MODE_OPTIONS, MATCH_TARGET_OPTIONS, RESOURCE_TYPE_OPTIONS, REQUEST_METHOD_OPTIONS, REQUEST_HEADER_FILTER_OPERATOR_OPTIONS } from '../constants';
import type { RedirectCondition } from '../types';
import { t } from '../i18n';

type Props = {
  condition: RedirectCondition;
  filterConfigured: boolean;
  onConditionChange: (patch: Partial<RedirectCondition>) => void;
  onFilterClick: () => void;
};

function truncateDomain(domain: string): { display: string; full: string; truncated: boolean } {
  const full = domain.trim();
  if (full.length <= 20) return { display: full, full, truncated: false };
  const parts = full.split('.');
  if (parts.length >= 3) {
    const display = `...${parts.slice(-2).join('.')}`;
    return { display, full, truncated: true };
  }
  return { display: `...${full.slice(-17)}`, full, truncated: true };
}

function getResourceTypeLabel(value: string): string {
  return RESOURCE_TYPE_OPTIONS.find((opt) => opt.value === value)?.label ?? value;
}

function getOperatorLabel(value: string): string {
  return REQUEST_HEADER_FILTER_OPERATOR_OPTIONS.find((opt) => opt.value === value)?.label ?? value;
}

export default function ConditionUrlMatchEditor({
  condition,
  filterConfigured,
  onConditionChange,
  onFilterClick,
}: Props) {
  const filter = condition.filter;

  const filterBadges: React.ReactNode[] = [];

  if (filter.pageDomain.trim()) {
    const { display, full, truncated } = truncateDomain(filter.pageDomain);
    const badge = (
      <Badge key="domain" variant="secondary" style={{ cursor: 'default' }}>
        {t('域名', 'Domain')}: {display}
      </Badge>
    );
    filterBadges.push(
      truncated ? (
        <Tooltip key="domain">
          <TooltipTrigger asChild>
            {badge}
          </TooltipTrigger>
          <TooltipContent sideOffset={4}>{full}</TooltipContent>
        </Tooltip>
      ) : badge
    );
  }

  for (const rt of filter.resourceTypes) {
    filterBadges.push(
      <Badge key={`rt-${rt}`} variant="secondary" style={{ cursor: 'default' }}>
        {t('资源类型', 'Resource type')}: {getResourceTypeLabel(rt)}
      </Badge>
    );
  }

  for (const m of filter.requestMethods) {
    filterBadges.push(
      <Badge key={`m-${m}`} variant="secondary" style={{ cursor: 'default' }}>
        {t('请求方法', 'Method')}: {m.toUpperCase()}
      </Badge>
    );
  }

  for (let i = 0; i < filter.requestHeaderFilters.length; i++) {
    const f = filter.requestHeaderFilters[i];
    if (f.key.trim() && f.value.trim()) {
      filterBadges.push(
        <Badge key={`h-${i}`} variant="secondary" style={{ cursor: 'default' }}>
          {f.key} {getOperatorLabel(f.operator)} {f.value}
        </Badge>
      );
    }
  }

  return (
    <div style={{ width: '100%' }}>
      <div className="aui-compact">
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
          <Funnel className="size-4" />
        </Button>
      </div>
      {filterBadges.length > 0 && (
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, marginTop: 12 }}>
          {filterBadges}
        </div>
      )}
    </div>
  );
}
