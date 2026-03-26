import React, { useMemo, useState } from 'react';
import { Button } from '@/components/animate-ui/components/buttons/button';
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from '@/components/animate-ui/components/radix/tooltip';
import {
  AutoComplete,
  Input,
  Select,
} from '../../../components';
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/animate-ui/components/radix/tabs';
import { t } from '../../../i18n';
import {
  DeleteOutlined,
  PlusOutlined,
} from '../../../icons';
import { createDefaultCondition, genId, simulateRuleEffect, type SimulateRuleResult } from '../../../rule-utils';
import type { HeaderModification, RedirectCondition } from '../../../types';
import ConditionUrlMatchEditor from '../../../components/ConditionUrlMatchEditor';
import TestRuleDrawer from '../../../components/TestRuleDrawer';
import ConditionFilterModal, { isConditionFilterConfigured } from '../../../components/ConditionFilterModal';
import ConditionList from '../ConditionList';
import RuleDetailHeader from '../RuleDetailHeader';
import type { RuleDetailProps as Props } from '../types';

const HEADER_ACTION_OPTIONS = [
  { label: t('添加', 'Add'), value: 'add' },
  { label: t('修改', 'Update'), value: 'update' },
  { label: t('删除', 'Delete'), value: 'delete' },
] as const;

const COMMON_HEADERS = [
  'Accept',
  'Accept-Encoding',
  'Accept-Language',
  'Authorization',
  'Cache-Control',
  'Content-Length',
  'Content-Type',
  'Cookie',
  'Host',
  'Origin',
  'Pragma',
  'Referer',
  'Operation-Type',
  'User-Agent',
  'X-Forwarded-For',
  'X-Requested-With',
  'ETag',
  'If-Modified-Since',
  'Last-Modified',
  'Location',
  'Set-Cookie',
  'Access-Control-Allow-Origin',
  'Access-Control-Allow-Headers',
  'Access-Control-Allow-Methods',
  'Access-Control-Expose-Headers',
];

const HEADER_OPTIONS = COMMON_HEADERS.map((header) => ({
  value: header,
  label: (
    <Tooltip>
      <TooltipTrigger asChild>
        <span
          style={{
            display: 'inline-block',
            width: '100%',
            overflow: 'hidden',
            textOverflow: 'ellipsis',
            whiteSpace: 'nowrap',
          }}
        >
          {header}
        </span>
      </TooltipTrigger>
      <TooltipContent side="right" sideOffset={6}>
        {header}
      </TooltipContent>
    </Tooltip>
  ),
}));

export default function ModifyHeadersRuleDetail({
  groups,
  workingRule,
  originalRule,
  setWorkingRule,
  setRules,
  saveDetailRule,
  setPageToList,
  notifyApi,
}: Props) {
  const [testDrawerOpen, setTestDrawerOpen] = useState(false);
  const [testUrl, setTestUrl] = useState('');
  const [testResult, setTestResult] = useState<SimulateRuleResult | null>(null);
  const [filterModal, setFilterModal] = useState<{ open: boolean; conditionId?: string }>({ open: false });
  const currentGroupEnabled = useMemo(() => new Map(groups.map((g) => [g.id, g.enabled])), [groups]);

  const updateCondition = (conditionId: string, patch: Partial<RedirectCondition>) => {
    setWorkingRule((prev) => (prev
      ? { ...prev, conditions: prev.conditions.map((c) => (c.id === conditionId ? { ...c, ...patch } : c)) }
      : prev));
  };

  const removeCondition = (conditionId: string) => {
    if (workingRule.conditions.length <= 1) {
      notifyApi.warning(t('至少保留一条条件配置', 'Keep at least one condition.'));
      return;
    }
    setWorkingRule({ ...workingRule, conditions: workingRule.conditions.filter((c) => c.id !== conditionId) });
  };


  const updateHeaderModification = (
    conditionId: string,
    tabKey: 'requestHeaderModifications' | 'responseHeaderModifications',
    modificationId: string,
    patch: Partial<HeaderModification>,
  ) => {
    const condition = workingRule.conditions.find((item) => item.id === conditionId);
    if (!condition) return;
    updateCondition(conditionId, {
      [tabKey]: condition[tabKey].map((item) => (item.id === modificationId ? { ...item, ...patch } : item)),
    });
  };

  const addHeaderModification = (
    conditionId: string,
    tabKey: 'requestHeaderModifications' | 'responseHeaderModifications',
  ) => {
    const condition = workingRule.conditions.find((item) => item.id === conditionId);
    if (!condition) return;
    updateCondition(conditionId, {
      [tabKey]: [...condition[tabKey], { id: genId(), action: 'add', key: '', value: '' }],
    });
  };

  const removeHeaderModification = (
    conditionId: string,
    tabKey: 'requestHeaderModifications' | 'responseHeaderModifications',
    modificationId: string,
  ) => {
    const condition = workingRule.conditions.find((item) => item.id === conditionId);
    if (!condition) return;
    updateCondition(conditionId, {
      [tabKey]: condition[tabKey].filter((item) => item.id !== modificationId),
    });
  };

  const activeCondition = workingRule.conditions.find((c) => c.id === filterModal.conditionId);

  const renderHeaderTabContent = (
    condition: RedirectCondition,
    tabKey: 'requestHeaderModifications' | 'responseHeaderModifications',
  ) => (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8, width: '100%' }}>
      {condition[tabKey].map((modification) => (
        <div key={modification.id} style={{ display: 'flex', gap: 6, width: '100%' }}>
          <Select
            value={modification.action}
            options={HEADER_ACTION_OPTIONS as never}
            style={{ width: 100 }}
            onChange={(value) => updateHeaderModification(condition.id, tabKey, modification.id, { action: value })}
          />
          <AutoComplete
            style={{ width: 400 }}
            options={HEADER_OPTIONS}
            filterOption={false}
            value={modification.key}
            onChange={(value) => updateHeaderModification(condition.id, tabKey, modification.id, { key: value })}
          >
            <Input
              placeholder="Header"
              title={modification.key || undefined}
              style={{
                textOverflow: 'ellipsis',
              }}
            />
          </AutoComplete>
          <Input
            placeholder={t('值', 'Value')}
            value={modification.value}
            disabled={modification.action === 'delete'}
            onChange={(e) => updateHeaderModification(condition.id, tabKey, modification.id, { value: e.target.value })}
          />
          <Button variant="destructive" size="icon" onClick={() => removeHeaderModification(condition.id, tabKey, modification.id)}>
            <DeleteOutlined />
          </Button>
        </div>
      ))}
      <Button variant="outline" onClick={() => addHeaderModification(condition.id, tabKey)}><PlusOutlined />{t('添加 Header', 'Add header')}</Button>
    </div>
  );

  return <div>
    <RuleDetailHeader
      groups={groups}
      workingRule={workingRule}
      originalRule={originalRule}
      setWorkingRule={setWorkingRule}
      saveDetailRule={saveDetailRule}
      onTest={() => setTestDrawerOpen(true)}
    />
    <ConditionList
      conditions={workingRule.conditions}
      onAdd={() => {
        const newCondition = createDefaultCondition();
        setWorkingRule({ ...workingRule, conditions: [...workingRule.conditions, newCondition] });
        return newCondition.id;
      }}
      onRemove={removeCondition}
      renderContent={(c) => (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8, width: '100%' }}>
          <ConditionUrlMatchEditor
            condition={c}
            filterConfigured={isConditionFilterConfigured(c)}
            onConditionChange={(patch) => updateCondition(c.id, patch)}
            onFilterClick={() => setFilterModal({ open: true, conditionId: c.id })}
          />
          <Tabs defaultValue="requestHeaderModifications">
            <TabsList>
              <TabsTrigger value="requestHeaderModifications">{t('请求 Headers', 'Request headers')}</TabsTrigger>
              <TabsTrigger value="responseHeaderModifications">{t('响应 Headers', 'Response headers')}</TabsTrigger>
            </TabsList>
            <TabsContent value="requestHeaderModifications">{renderHeaderTabContent(c, 'requestHeaderModifications')}</TabsContent>
            <TabsContent value="responseHeaderModifications">{renderHeaderTabContent(c, 'responseHeaderModifications')}</TabsContent>
          </Tabs>
        </div>
      )}
    />
    <TestRuleDrawer
      open={testDrawerOpen}
      testUrl={testUrl}
      testResult={testResult}
      onClose={() => setTestDrawerOpen(false)}
      onTest={() => setTestResult(simulateRuleEffect(testUrl, [workingRule], currentGroupEnabled, { includeDisabled: true }))}
      onTestUrlChange={setTestUrl}
    />
    <ConditionFilterModal
      open={filterModal.open}
      condition={activeCondition}
      onClose={() => setFilterModal({ open: false })}
      onConditionChange={updateCondition}
    />
  </div>;
}
