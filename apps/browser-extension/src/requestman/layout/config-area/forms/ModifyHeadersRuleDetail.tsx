import React, { useMemo, useState } from 'react';
import { Button } from '@/components/animate-ui/components/buttons/button';
import { AnimateIcon } from '@/components/animate-ui/icons/icon';
import { Trash2 } from '@/components/animate-ui/icons/trash-2';
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from '@/components/animate-ui/components/radix/tooltip';
import { Input } from '@/components/ui/input';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { AutoComplete } from '../../../components/AutoComplete';
import { Tabs, TabsList, TabsTrigger, TabsContents, TabsContent } from '@/components/animate-ui/components/animate/tabs';
import { t } from '../../../i18n';
import {
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
  isNewRule,
  setWorkingRule,
  setRules,
  saveDetailRule,
  toggleDetailRuleEnabled,
  duplicateDetailRule,
  deleteDetailRule,
  renameRule,
  moveRuleToGroupById,
  setPageToList,
  notifyApi,
}: Props) {
  const [testDrawerOpen, setTestDrawerOpen] = useState(false);
  const [testUrl, setTestUrl] = useState('');
  const [testResult, setTestResult] = useState<SimulateRuleResult | null>(null);
  const [filterModal, setFilterModal] = useState<{ open: boolean; conditionId?: string }>({ open: false });
  const [activeHeaderTabs, setActiveHeaderTabs] = useState<Record<string, 'requestHeaderModifications' | 'responseHeaderModifications'>>({});
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
            onValueChange={(value) => updateHeaderModification(condition.id, tabKey, modification.id, { action: value })}
          >
            <SelectTrigger style={{ width: 100 }}>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {HEADER_ACTION_OPTIONS.map((opt) => (
                <SelectItem key={opt.value} value={opt.value}>{opt.label}</SelectItem>
              ))}
            </SelectContent>
          </Select>
          <AutoComplete
            style={{ width: 400 }}
            options={HEADER_OPTIONS}
            filterOption={false}
            value={modification.key}
            placeholder={t('Header', 'Header')}
            title={modification.key || undefined}
            inputStyle={{
              textOverflow: 'ellipsis',
            }}
            onChange={(value) => updateHeaderModification(condition.id, tabKey, modification.id, { key: value })}
          />
          <Input
            placeholder={t('值', 'Value')}
            value={modification.value}
            disabled={modification.action === 'delete'}
            onChange={(e) => updateHeaderModification(condition.id, tabKey, modification.id, { value: e.target.value })}
          />
          <Button variant="outline" size="icon-sm" onClick={() => removeHeaderModification(condition.id, tabKey, modification.id)}>
            <AnimateIcon animateOnHover asChild>
              <span className="inline-flex items-center justify-center" style={{ color: '#ff4d4f' }}>
                <Trash2 size={14} />
              </span>
            </AnimateIcon>
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
      isNewRule={isNewRule}
      saveDetailRule={saveDetailRule}
      toggleDetailRuleEnabled={toggleDetailRuleEnabled}
      duplicateDetailRule={duplicateDetailRule}
      deleteDetailRule={deleteDetailRule}
      renameRule={renameRule}
      moveRuleToGroupById={moveRuleToGroupById}
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
      renderConditionContent={(c) => (
        <ConditionUrlMatchEditor
          condition={c}
          filterConfigured={isConditionFilterConfigured(c)}
          onConditionChange={(patch) => updateCondition(c.id, patch)}
          onFilterClick={() => setFilterModal({ open: true, conditionId: c.id })}
        />
      )}
      renderExecutionContent={(c) => (
        <Tabs
          value={activeHeaderTabs[c.id] ?? 'requestHeaderModifications'}
          onValueChange={(value) => setActiveHeaderTabs((prev) => ({
            ...prev,
            [c.id]: value as 'requestHeaderModifications' | 'responseHeaderModifications',
          }))}
        >
          <TabsList>
            <TabsTrigger value="requestHeaderModifications">
              {t('请求 Headers', 'Request headers')}
            </TabsTrigger>
            <TabsTrigger value="responseHeaderModifications">
              {t('响应 Headers', 'Response headers')}
            </TabsTrigger>
          </TabsList>
          <TabsContents style={{ overflow: 'visible' }}>
            <TabsContent value="requestHeaderModifications" style={{ overflow: 'visible', paddingTop: 4 }}>{renderHeaderTabContent(c, 'requestHeaderModifications')}</TabsContent>
            <TabsContent value="responseHeaderModifications" style={{ overflow: 'visible', paddingTop: 4 }}>{renderHeaderTabContent(c, 'responseHeaderModifications')}</TabsContent>
          </TabsContents>
        </Tabs>
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
