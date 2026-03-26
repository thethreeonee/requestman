import React from 'react';
import { Button } from '@/components/animate-ui/components/buttons/button';
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/animate-ui/components/radix/dialog';
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from '@/components/animate-ui/components/radix/tooltip';
import { ReloadOutlined } from '../icons';
import { AutoComplete, Input, Select } from '.';
import { t } from '../i18n';
import {
  COMMON_HEADER_OPTIONS,
  REQUEST_HEADER_FILTER_OPERATOR_OPTIONS,
  REQUEST_METHOD_OPTIONS,
  RESOURCE_TYPE_OPTIONS,
} from '../constants';
import type { RedirectCondition } from '../types';

type Props = {
  open: boolean;
  condition?: RedirectCondition;
  onClose: () => void;
  onConditionChange: (conditionId: string, patch: Partial<RedirectCondition>) => void;
};

export function isConditionFilterConfigured(condition: RedirectCondition) {
  return !!condition.filter.pageDomain.trim()
    || condition.filter.resourceType !== 'all'
    || condition.filter.requestMethod !== 'all'
    || (!!condition.filter.requestHeaderKey.trim() && !!condition.filter.requestHeaderValue.trim());
}

export default function ConditionFilterModal({ open, condition, onClose, onConditionChange }: Props) {
  const filterItemStyle: React.CSSProperties = { marginBottom: 12 };

  const renderResetButton = (title: string, onClick: () => void) => (
    <Tooltip>
      <TooltipTrigger asChild>
        <span className="inline-flex">
          <Button variant="outline" size="icon" onClick={onClick} style={{ width: 32 }}>
            <ReloadOutlined />
          </Button>
        </span>
      </TooltipTrigger>
      <TooltipContent sideOffset={6}>
        {title}
      </TooltipContent>
    </Tooltip>
  );

  return (
    <Dialog open={open} onOpenChange={(nextOpen) => { if (!nextOpen) onClose(); }}>
      <DialogContent showCloseButton={false}>
        <DialogHeader>
          <DialogTitle>{t('过滤条件', 'Filter conditions')}</DialogTitle>
        </DialogHeader>
        {condition && (
          <div>
          <label style={{ display: 'block', ...filterItemStyle }}>
            <div>{t('页面域名', 'Page domain')}</div>
            <div className="aui-compact">
              <Input
                value={condition.filter.pageDomain}
                onChange={(e) => onConditionChange(condition.id, {
                  filter: { ...condition.filter, pageDomain: e.target.value },
                })}
              />
              {renderResetButton(t('重置页面域名', 'Reset page domain'), () => onConditionChange(condition.id, {
                filter: { ...condition.filter, pageDomain: '' },
              }))}
            </div>
          </label>

          <label style={{ display: 'block', ...filterItemStyle }}>
            <div>{t('资源类型', 'Resource type')}</div>
            <div className="aui-compact">
              <Select
                value={condition.filter.resourceType}
                options={RESOURCE_TYPE_OPTIONS as never}
                onChange={(v) => onConditionChange(condition.id, {
                  filter: { ...condition.filter, resourceType: v },
                })}
              />
              {renderResetButton(t('重置资源类型', 'Reset resource type'), () => onConditionChange(condition.id, {
                filter: { ...condition.filter, resourceType: 'all' },
              }))}
            </div>
          </label>

          <label style={{ display: 'block', ...filterItemStyle }}>
            <div>{t('请求方法', 'Request method')}</div>
            <div className="aui-compact">
              <Select
                value={condition.filter.requestMethod}
                options={REQUEST_METHOD_OPTIONS as never}
                onChange={(v) => onConditionChange(condition.id, {
                  filter: { ...condition.filter, requestMethod: v },
                })}
              />
              {renderResetButton(t('重置请求方法', 'Reset request method'), () => onConditionChange(condition.id, {
                filter: { ...condition.filter, requestMethod: 'all' },
              }))}
            </div>
          </label>

          <label style={{ display: 'block', ...filterItemStyle }}>
            <div>{t('请求 Header 过滤', 'Request header filter')}</div>
            <div className="aui-compact">
              <AutoComplete
                options={COMMON_HEADER_OPTIONS}
                value={condition.filter.requestHeaderKey}
                placeholder={t('Header', 'Header')}
                style={{ width: '30%' }}
                onChange={(value) => onConditionChange(condition.id, {
                  filter: { ...condition.filter, requestHeaderKey: value },
                })}
              />
              <Select
                value={condition.filter.requestHeaderOperator}
                options={REQUEST_HEADER_FILTER_OPERATOR_OPTIONS as never}
                style={{ width: '22%' }}
                onChange={(value) => onConditionChange(condition.id, {
                  filter: { ...condition.filter, requestHeaderOperator: value },
                })}
              />
              <Input
                value={condition.filter.requestHeaderValue}
                placeholder={t('目标值', 'Target value')}
                style={{ width: '48%' }}
                onChange={(e) => onConditionChange(condition.id, {
                  filter: { ...condition.filter, requestHeaderValue: e.target.value },
                })}
              />
              {renderResetButton(t('重置 Header 过滤', 'Reset header filter'), () => onConditionChange(condition.id, {
                filter: {
                  ...condition.filter,
                  requestHeaderKey: '',
                  requestHeaderOperator: 'equals',
                  requestHeaderValue: '',
                },
              }))}
            </div>
          </label>
          </div>
        )}
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>{t('取消', 'Cancel')}</Button>
          <Button variant="default" onClick={onClose}>OK</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
