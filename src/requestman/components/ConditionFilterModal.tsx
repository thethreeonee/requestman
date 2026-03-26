import React from 'react';
import { Button } from '@/components/animate-ui/components/buttons/button';
import { AnimateIcon } from '@/components/animate-ui/icons/icon';
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/animate-ui/components/radix/dialog';
import { Input } from '@/components/ui/input';
import { Toggle } from '@/components/animate-ui/components/radix/toggle';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { Separator } from '@/components/ui/separator';
import { RefreshCw } from '@/components/animate-ui/icons/refresh-cw';
import { Trash2 } from '@/components/animate-ui/icons/trash-2';
import { AutoComplete } from './AutoComplete';
import { PlusOutlined } from '../icons';
import { t } from '../i18n';
import {
  COMMON_HEADER_OPTIONS,
  REQUEST_HEADER_FILTER_OPERATOR_OPTIONS,
  REQUEST_METHOD_OPTIONS,
  RESOURCE_TYPE_OPTIONS,
} from '../constants';
import type { RedirectCondition, ResourceTypeFilter, RequestMethodFilter, RequestHeaderFilterEntry } from '../types';

type Props = {
  open: boolean;
  condition?: RedirectCondition;
  onClose: () => void;
  onConditionChange: (conditionId: string, patch: Partial<RedirectCondition>) => void;
};

export function isConditionFilterConfigured(condition: RedirectCondition) {
  return !!condition.filter.pageDomain.trim()
    || condition.filter.resourceTypes.length > 0
    || condition.filter.requestMethods.length > 0
    || condition.filter.requestHeaderFilters.some((f) => f.key.trim() && f.value.trim());
}

const RESOURCE_TYPE_TOGGLE_OPTIONS = RESOURCE_TYPE_OPTIONS.filter((opt) => opt.value !== 'all');
const REQUEST_METHOD_TOGGLE_OPTIONS = REQUEST_METHOD_OPTIONS.filter((opt) => opt.value !== 'all');

export default function ConditionFilterModal({ open, condition, onClose, onConditionChange }: Props) {
  const sectionStyle: React.CSSProperties = { marginBottom: 16 };
  const sectionHeaderStyle: React.CSSProperties = {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: 8,
  };
  const labelStyle: React.CSSProperties = { display: 'block', fontSize: 13, color: 'var(--muted-foreground, #888)' };

  const [cachedCondition, setCachedCondition] = React.useState<RedirectCondition | undefined>(condition);

  React.useEffect(() => {
    if (condition) setCachedCondition(condition);
  }, [condition]);

  const activeCondition = condition ?? cachedCondition;

  if (!activeCondition) return null;

  const filter = activeCondition.filter;

  const updateFilter = (patch: Partial<RedirectCondition['filter']>) => {
    onConditionChange(activeCondition.id, { filter: { ...filter, ...patch } });
  };

  const toggleResourceType = (value: ResourceTypeFilter) => {
    const next = filter.resourceTypes.includes(value)
      ? filter.resourceTypes.filter((v) => v !== value)
      : [...filter.resourceTypes, value];
    updateFilter({ resourceTypes: next });
  };

  const toggleRequestMethod = (value: RequestMethodFilter) => {
    const next = filter.requestMethods.includes(value)
      ? filter.requestMethods.filter((v) => v !== value)
      : [...filter.requestMethods, value];
    updateFilter({ requestMethods: next });
  };

  const addHeaderFilter = () => {
    updateFilter({
      requestHeaderFilters: [...filter.requestHeaderFilters, { key: '', operator: 'equals', value: '' }],
    });
  };

  const updateHeaderFilter = (index: number, patch: Partial<RequestHeaderFilterEntry>) => {
    const next = filter.requestHeaderFilters.map((entry, i) =>
      i === index ? { ...entry, ...patch } : entry
    );
    updateFilter({ requestHeaderFilters: next });
  };

  const removeHeaderFilter = (index: number) => {
    updateFilter({ requestHeaderFilters: filter.requestHeaderFilters.filter((_, i) => i !== index) });
  };

  return (
    <Dialog open={open} onOpenChange={(nextOpen) => { if (!nextOpen) onClose(); }}>
      <DialogContent
        showCloseButton={false}
        className="max-w-none sm:max-w-none"
        style={{ width: 'min(720px, calc(100vw - 2rem))' }}
      >
        <DialogHeader>
          <DialogTitle>{t('过滤条件', 'Filter conditions')}</DialogTitle>
        </DialogHeader>

        <div>
          {/* Page Domain */}
          <div style={sectionStyle}>
            <div style={sectionHeaderStyle}>
              <div style={labelStyle}>{t('页面域名', 'Page domain')}</div>
            </div>
            <div className="aui-compact">
              <Input
                value={filter.pageDomain}
                placeholder={t('例如: example.com', 'e.g. example.com')}
                onChange={(e) => updateFilter({ pageDomain: e.target.value })}
              />
              <Button
                variant="outline"
                size="icon"
                className="h-8 w-8"
                onClick={() => updateFilter({ pageDomain: '' })}
              >
                <AnimateIcon animateOnHover asChild>
                  <span style={{ display: 'inline-flex', color: 'var(--muted-foreground)' }}>
                    <RefreshCw size={14} animation="rotate" />
                  </span>
                </AnimateIcon>
              </Button>
            </div>
          </div>
          <Separator className="my-4" />

          {/* Resource Types */}
          <div style={sectionStyle}>
            <div style={sectionHeaderStyle}>
              <span style={labelStyle}>{t('资源类型', 'Resource type')}</span>
              {filter.resourceTypes.length > 0 && (
                <Button
                  variant="ghost"
                  size="sm"
                  style={{ height: 20, padding: '0 6px', fontSize: 12 }}
                  onClick={() => updateFilter({ resourceTypes: [] })}
                >
                  {t('清除', 'Clear')}
                </Button>
              )}
            </div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
              {RESOURCE_TYPE_TOGGLE_OPTIONS.map((opt) => {
                const selected = filter.resourceTypes.includes(opt.value as ResourceTypeFilter);
                return (
                  <Toggle
                    key={opt.value}
                    variant="outline"
                    size="sm"
                    pressed={selected}
                    style={{ cursor: 'pointer', userSelect: 'none' }}
                    onPressedChange={() => toggleResourceType(opt.value as ResourceTypeFilter)}
                  >
                    {opt.label}
                  </Toggle>
                );
              })}
            </div>
          </div>
          <Separator className="my-4" />

          {/* Request Methods */}
          <div style={sectionStyle}>
            <div style={sectionHeaderStyle}>
              <span style={labelStyle}>{t('请求方法', 'Request method')}</span>
              {filter.requestMethods.length > 0 && (
                <Button
                  variant="ghost"
                  size="sm"
                  style={{ height: 20, padding: '0 6px', fontSize: 12 }}
                  onClick={() => updateFilter({ requestMethods: [] })}
                >
                  {t('清除', 'Clear')}
                </Button>
              )}
            </div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
              {REQUEST_METHOD_TOGGLE_OPTIONS.map((opt) => {
                const selected = filter.requestMethods.includes(opt.value as RequestMethodFilter);
                return (
                  <Toggle
                    key={opt.value}
                    variant="outline"
                    size="sm"
                    pressed={selected}
                    style={{ cursor: 'pointer', userSelect: 'none' }}
                    onPressedChange={() => toggleRequestMethod(opt.value as RequestMethodFilter)}
                  >
                    {opt.label}
                  </Toggle>
                );
              })}
            </div>
          </div>
          <Separator className="my-4" />

          {/* Request Header Filters */}
          <div style={sectionStyle}>
            <div style={sectionHeaderStyle}>
              <div style={labelStyle}>{t('请求 Header 过滤', 'Request header filter')}</div>
            </div>
            {filter.requestHeaderFilters.map((entry, idx) => (
              <div key={idx} className="aui-compact" style={{ marginBottom: 6 }}>
                <AutoComplete
                  options={COMMON_HEADER_OPTIONS}
                  value={entry.key}
                  placeholder="Header"
                  style={{ width: '30%' }}
                  onChange={(value) => updateHeaderFilter(idx, { key: value })}
                />
                <Select
                  value={entry.operator}
                  onValueChange={(value) => updateHeaderFilter(idx, { operator: value as RequestHeaderFilterEntry['operator'] })}
                >
                  <SelectTrigger className="h-8" style={{ width: '24%' }}>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {REQUEST_HEADER_FILTER_OPERATOR_OPTIONS.map((opt) => (
                      <SelectItem key={opt.value} value={opt.value}>{opt.label}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <Input
                  value={entry.value}
                  placeholder={t('目标值', 'Target value')}
                  style={{ flex: 1, minWidth: 0 }}
                  onChange={(e) => updateHeaderFilter(idx, { value: e.target.value })}
                />
                <Button
                  variant="outline"
                  size="icon"
                  className="h-8 w-8 shrink-0"
                  onClick={() => removeHeaderFilter(idx)}
                >
                  <AnimateIcon animateOnHover asChild>
                    <span style={{ display: 'inline-flex', color: '#ff4d4f' }}>
                      <Trash2 size={14} />
                    </span>
                  </AnimateIcon>
                </Button>
              </div>
            ))}
            <Button
              variant="outline"
              size="sm"
              onClick={addHeaderFilter}
              style={{ marginTop: 2, fontSize: 12 }}
            >
              <PlusOutlined />
              {t(' 添加过滤', ' Add filter')}
            </Button>
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={onClose}>{t('取消', 'Cancel')}</Button>
          <Button variant="default" onClick={onClose}>OK</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
