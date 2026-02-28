import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  App,
  Button,
  Collapse,
  Dropdown,
  Input,
  Modal,
  Popconfirm,
  Select,
  Space,
  Switch,
  Typography,
} from 'antd';
import {
  CopyOutlined,
  DeleteOutlined,
  DownloadOutlined,
  EditOutlined,
  EllipsisOutlined,
  HolderOutlined,
  PlusOutlined,
  SaveOutlined,
  SwapOutlined,
  UploadOutlined,
} from '@ant-design/icons';
import {
  DndContext,
  PointerSensor,
  useSensor,
  useSensors,
  type DragEndEvent,
} from '@dnd-kit/core';
import { SortableContext, arrayMove, useSortable, verticalListSortingStrategy } from '@dnd-kit/sortable';
import { CSS } from '@dnd-kit/utilities';
import './index.css';
import {
  DEFAULT_GROUP_ID,
  DEFAULT_GROUP_NAME,
  REDIRECT_ENABLED_KEY,
  REDIRECT_GROUPS_KEY,
  REDIRECT_RULES_KEY,
} from './constants';
import {
  genId,
  isRuleEffectivelyEnabled,
  normalizeGroups,
  normalizeRules,
  simulateRedirect,
} from './rule-utils';
import {
  parseGroupSortDndId,
  projectRulesByDragTarget,
  ruleDropCollisionDetection,
  toGroupSortDndId,
} from './dnd-utils';
import type { DragData, MatchMode, MatchTarget, RedirectGroup, RedirectRule, RuleDraft, RuleDragData } from './types';

const MATCH_TARGET_OPTIONS: { label: string; value: MatchTarget }[] = [
  { label: 'URL', value: 'url' },
  { label: 'Host', value: 'host' },
];

const MATCH_MODE_OPTIONS: { label: string; value: MatchMode }[] = [
  { label: '等于', value: 'equals' },
  { label: '包含', value: 'contains' },
  { label: '通配符', value: 'wildcard' },
  { label: '正则', value: 'regex' },
];

function SortableGroupHeader({
  id,
  children,
}: {
  id: string;
  children: (dnd: { attributes: Record<string, unknown>; listeners: Record<string, unknown>; isDragging: boolean }) => React.ReactNode;
}) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({
    id: toGroupSortDndId(id),
    data: { type: 'group-sort', groupId: id },
  });

  return (
    <div
      ref={setNodeRef}
      style={{ transform: CSS.Transform.toString(transform), transition }}
      className={isDragging ? 'simple-group-head simple-group-card-dragging' : 'simple-group-head'}
    >
      {children({
        attributes: attributes as Record<string, unknown>,
        listeners: listeners as Record<string, unknown>,
        isDragging,
      })}
    </div>
  );
}

function SortableRuleCard({
  rule,
  children,
}: {
  rule: RedirectRule;
  children: (dnd: { attributes: Record<string, unknown>; listeners: Record<string, unknown>; isDragging: boolean }) => React.ReactNode;
}) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({
    id: rule.id,
    data: { type: 'rule', groupId: rule.groupId } as RuleDragData,
  });

  return (
    <div
      ref={setNodeRef}
      style={{ transform: CSS.Transform.toString(transform), transition }}
      className={isDragging ? 'simple-rule-card simple-rule-card-dragging' : 'simple-rule-card'}
      data-rule-id={rule.id}
    >
      {children({ attributes: attributes as Record<string, unknown>, listeners: listeners as Record<string, unknown>, isDragging })}
    </div>
  );
}

function RedirectPanel() {
  const { message } = App.useApp();
  const [groups, setGroups] = useState<RedirectGroup[]>([]);
  const [rules, setRules] = useState<RedirectRule[]>([]);
  const [ruleDrafts, setRuleDrafts] = useState<Record<string, RuleDraft>>({});
  const [newGroupName, setNewGroupName] = useState('');
  const [createGroupModalOpen, setCreateGroupModalOpen] = useState(false);
  const [editGroupModalOpen, setEditGroupModalOpen] = useState(false);
  const [editingGroupId, setEditingGroupId] = useState<string | null>(null);
  const [editingGroupName, setEditingGroupName] = useState('');
  const [redirectEnabled, setRedirectEnabled] = useState(true);
  const [rulesLoaded, setRulesLoaded] = useState(false);
  const [testUrl, setTestUrl] = useState('');
  const [testTrigger, setTestTrigger] = useState(0);
  const [highlightedRuleId, setHighlightedRuleId] = useState<string | null>(null);
  const [collapsedGroupIds, setCollapsedGroupIds] = useState<string[]>([]);
  const applySourceRef = useRef<'init' | 'input' | 'non_input' | 'add' | 'group_toggle'>('init');
  const highlightTimerRef = useRef<number | null>(null);
  const listScrollRef = useRef<HTMLDivElement | null>(null);
  const importInputRef = useRef<HTMLInputElement | null>(null);
  const sensors = useSensors(useSensor(PointerSensor, { activationConstraint: { distance: 4 } }));

  useEffect(() => {
    chrome.storage.local.get([REDIRECT_RULES_KEY, REDIRECT_ENABLED_KEY, REDIRECT_GROUPS_KEY], (res) => {
      const normalizedGroups = normalizeGroups(res?.[REDIRECT_GROUPS_KEY]);
      const groupIds = new Set(normalizedGroups.map((g) => g.id));
      const fallbackGroupId = normalizedGroups[0]?.id ?? DEFAULT_GROUP_ID;
      setGroups(normalizedGroups);
      setRules(normalizeRules(res?.[REDIRECT_RULES_KEY], groupIds, fallbackGroupId));
      setRedirectEnabled(res?.[REDIRECT_ENABLED_KEY] !== false);
      setRulesLoaded(true);
    });
  }, []);

  const addRule = (groupId: string) => {
    applySourceRef.current = 'add';
    setRules((prev) => [{
      id: genId(),
      enabled: true,
      groupId,
      matchTarget: 'url',
      matchMode: 'contains',
      expression: '',
      redirectUrl: '',
    }, ...prev]);
  };

  const updateRule = <K extends keyof RedirectRule>(id: string, key: K, value: RedirectRule[K]) => {
    setRules((prev) => prev.map((r) => (r.id === id ? { ...r, [key]: value } : r)));
  };

  const removeRule = (id: string) => {
    applySourceRef.current = 'non_input';
    setRules((prev) => prev.filter((r) => r.id !== id));
    setRuleDrafts((prev) => {
      const next = { ...prev };
      delete next[id];
      return next;
    });
    message.success('已删除规则');
  };

  const duplicateRule = (id: string) => {
    applySourceRef.current = 'non_input';
    setRules((prev) => {
      const idx = prev.findIndex((r) => r.id === id);
      if (idx < 0) return prev;
      const next = [...prev];
      next.splice(idx + 1, 0, { ...next[idx], id: genId() });
      return next;
    });
    message.success('已复制规则');
  };

  const createGroup = () => {
    const name = newGroupName.trim();
    if (!name) {
      message.warning('请输入分组名称');
      return false;
    }
    applySourceRef.current = 'non_input';
    const next: RedirectGroup = { id: genId(), name, enabled: true };
    setGroups((prev) => [next, ...prev]);
    setNewGroupName('');
    message.success(`已创建分组：${name}`);
    return true;
  };

  const toggleGroupEnabled = (id: string, enabled: boolean) => {
    applySourceRef.current = 'group_toggle';
    const groupName = groups.find((g) => g.id === id)?.name || '未命名分组';
    setGroups((prev) => prev.map((g) => (g.id === id ? { ...g, enabled } : g)));
    enabled ? message.success(`已开启分组：${groupName}`) : message.warning(`已关闭分组：${groupName}`);
  };

  const removeGroup = (groupId: string) => {
    const groupName = groups.find((g) => g.id === groupId)?.name || '未命名分组';
    applySourceRef.current = 'non_input';
    setGroups((prev) => {
      const next = prev.filter((g) => g.id !== groupId);
      if (next.length > 0) return next;
      return [{ id: DEFAULT_GROUP_ID, name: DEFAULT_GROUP_NAME, enabled: true }];
    });
    setRules((prev) => prev.filter((r) => r.groupId !== groupId));
    message.success(`已删除分组：${groupName}`);
  };

  const openEditGroupModal = (groupId: string) => {
    const group = groups.find((g) => g.id === groupId);
    if (!group) return;
    setEditingGroupId(groupId);
    setEditingGroupName(group.name);
    setEditGroupModalOpen(true);
  };

  const submitEditGroupName = () => {
    if (!editingGroupId) return false;
    const nextName = editingGroupName.trim();
    if (!nextName) {
      message.warning('请输入分组名称');
      return false;
    }
    applySourceRef.current = 'non_input';
    setGroups((prev) => prev.map((g) => (g.id === editingGroupId ? { ...g, name: nextName } : g)));
    setEditGroupModalOpen(false);
    setEditingGroupId(null);
    setEditingGroupName('');
    message.success(`已更新分组名称为：${nextName}`);
    return true;
  };

  const getRuleFieldValue = (row: RedirectRule, key: 'expression' | 'redirectUrl') => {
    const draft = ruleDrafts[row.id];
    if (!draft) return row[key];
    const v = draft[key];
    return typeof v === 'string' ? v : row[key];
  };

  const isRuleFieldDirty = (row: RedirectRule, key: 'expression' | 'redirectUrl') => {
    const draft = ruleDrafts[row.id];
    if (!draft || typeof draft[key] !== 'string') return false;
    return draft[key] !== row[key];
  };

  const updateRuleDraft = (row: RedirectRule, key: 'expression' | 'redirectUrl', value: string) => {
    setRuleDrafts((prev) => ({ ...prev, [row.id]: { ...(prev[row.id] ?? {}), [key]: value } }));
  };

  const saveRuleDraft = (row: RedirectRule) => {
    const expression = getRuleFieldValue(row, 'expression');
    const redirectUrl = getRuleFieldValue(row, 'redirectUrl');
    if (!expression.trim() || !redirectUrl.trim()) {
      message.warning('请先补全匹配表达式和重定向 URL');
      return;
    }
    if (!isRuleFieldDirty(row, 'expression') && !isRuleFieldDirty(row, 'redirectUrl')) return;
    applySourceRef.current = 'non_input';
    setRules((prev) => prev.map((r) => (r.id === row.id ? { ...r, expression, redirectUrl } : r)));
    setRuleDrafts((prev) => {
      const next = { ...prev };
      delete next[row.id];
      return next;
    });
    message.success('规则已保存并生效');
  };

  const exportRules = () => {
    try {
      const grouped = groups.map((g) => ({
        id: g.id,
        name: g.name,
        enabled: g.enabled,
        rules: rules.filter((r) => r.groupId === g.id),
      }));
      const payload = { version: 2, enabled: redirectEnabled, groups: grouped };
      const blob = new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json;charset=utf-8' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `asap-redirect-rules-${new Date().toISOString().slice(0, 19).replace(/:/g, '-')}.json`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
      message.success('导出成功');
    } catch (err) {
      message.error(`导出失败: ${String((err as Error)?.message || err)}`);
    }
  };

  const importRulesFromFile = async (file: File) => {
    try {
      const text = await file.text();
      const parsed = JSON.parse(text) as unknown;
      let importedGroups = groups;
      let importedRules: RedirectRule[] = [];
      let importedEnabled = redirectEnabled;

      if (Array.isArray(parsed)) {
        const groupIds = new Set(importedGroups.map((g) => g.id));
        importedRules = normalizeRules(parsed, groupIds, importedGroups[0]?.id ?? DEFAULT_GROUP_ID);
      } else if (parsed && typeof parsed === 'object') {
        const obj = parsed as Record<string, unknown>;
        const groupedInput = Array.isArray(obj.groups) ? obj.groups : [];
        const hasNestedRules = groupedInput.some(
          (it) => it && typeof it === 'object' && Array.isArray((it as Record<string, unknown>).rules),
        );

        if (hasNestedRules) {
          importedGroups = normalizeGroups(
            groupedInput.map((it) => {
              const x = (it && typeof it === 'object' ? it : {}) as Record<string, unknown>;
              return { id: x.id, name: x.name, enabled: x.enabled };
            }),
          );
          const flatRules: unknown[] = [];
          for (const g of groupedInput) {
            if (!g || typeof g !== 'object') continue;
            const gx = g as Record<string, unknown>;
            if (!Array.isArray(gx.rules) || typeof gx.id !== 'string') continue;
            for (const r of gx.rules) {
              if (!r || typeof r !== 'object') continue;
              flatRules.push({ ...(r as Record<string, unknown>), groupId: gx.id });
            }
          }
          const groupIds = new Set(importedGroups.map((g) => g.id));
          importedRules = normalizeRules(flatRules, groupIds, importedGroups[0]?.id ?? DEFAULT_GROUP_ID);
        } else {
          importedGroups = normalizeGroups(obj.groups);
          const groupIds = new Set(importedGroups.map((g) => g.id));
          importedRules = normalizeRules(obj.rules, groupIds, importedGroups[0]?.id ?? DEFAULT_GROUP_ID);
        }
        if (typeof obj.enabled === 'boolean') importedEnabled = obj.enabled;
      } else {
        throw new Error('文件内容格式不正确');
      }

      applySourceRef.current = 'non_input';
      setGroups(importedGroups);
      setRules(importedRules);
      setRedirectEnabled(importedEnabled);
      setRuleDrafts({});
      message.success(`导入成功，共 ${importedRules.length} 条规则`);
    } catch (err) {
      message.error(`导入失败: ${String((err as Error)?.message || err)}`);
    } finally {
      if (importInputRef.current) importInputRef.current.value = '';
    }
  };

  const persistRules = (nextGroups: RedirectGroup[], nextRules: RedirectRule[], enabled: boolean) => {
    chrome.storage.local.set(
      { [REDIRECT_GROUPS_KEY]: nextGroups, [REDIRECT_RULES_KEY]: nextRules, [REDIRECT_ENABLED_KEY]: enabled },
      () => {
        chrome.runtime.sendMessage({ type: 'redirectRules/apply', groups: nextGroups, rules: nextRules, enabled }, () => {
          if (chrome.runtime.lastError) {
            message.error(`应用失败: ${chrome.runtime.lastError.message}`);
          }
        });
      },
    );
  };

  useEffect(() => {
    if (!rulesLoaded) return;
    const timer = window.setTimeout(() => {
      persistRules(groups, rules, redirectEnabled);
      applySourceRef.current = 'input';
    }, 100);
    return () => window.clearTimeout(timer);
  }, [groups, rules, redirectEnabled, rulesLoaded]);

  const groupEnabledMap = useMemo(() => new Map(groups.map((g) => [g.id, g.enabled] as const)), [groups]);
  const groupNameMap = useMemo(() => new Map(groups.map((g) => [g.id, g.name] as const)), [groups]);

  const rulesByGroup = useMemo(() => {
    const m = new Map<string, RedirectRule[]>();
    for (const g of groups) m.set(g.id, []);
    for (const rule of rules) {
      const list = m.get(rule.groupId);
      if (list) list.push(rule);
    }
    return m;
  }, [groups, rules]);

  const invalidCount = useMemo(
    () => rules.filter((r) => !r.expression.trim() || !r.redirectUrl.trim() || !groups.find((g) => g.id === r.groupId)).length,
    [groups, rules],
  );

  const testResult = useMemo(() => {
    if (testTrigger === 0) return null;
    const t = testUrl.trim();
    if (!t) return null;
    return simulateRedirect(t, rules, groupEnabledMap);
  }, [groupEnabledMap, rules, testTrigger, testUrl]);

  useEffect(() => {
    if (!testResult?.ok) return;
    const ruleId = testResult.matchedRule.id;
    setHighlightedRuleId(ruleId);

    if (highlightTimerRef.current != null) window.clearTimeout(highlightTimerRef.current);
    highlightTimerRef.current = window.setTimeout(() => {
      setHighlightedRuleId((cur) => (cur === ruleId ? null : cur));
    }, 2000);

    const container = listScrollRef.current;
    if (!container) return;
    const target = container.querySelector(`[data-rule-id="${ruleId}"]`) as HTMLDivElement | null;
    if (!target) return;
    target.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }, [testResult]);

  const handleDragEnd = (evt: DragEndEvent) => {
    const activeDragData = evt.active.data.current as DragData | { type?: string } | undefined;
    if (activeDragData?.type === 'group-sort') {
      const activeGroupId = parseGroupSortDndId(String(evt.active.id));
      const overGroupId = evt.over ? parseGroupSortDndId(String(evt.over.id)) : null;
      if (!activeGroupId || !overGroupId || activeGroupId === overGroupId) return;
      const oldIndex = groups.findIndex((g) => g.id === activeGroupId);
      const newIndex = groups.findIndex((g) => g.id === overGroupId);
      if (oldIndex < 0 || newIndex < 0 || oldIndex === newIndex) return;
      applySourceRef.current = 'non_input';
      setGroups((prev) => arrayMove(prev, oldIndex, newIndex));
      message.success('已更新分组顺序');
      return;
    }

    const { active, over } = evt;
    if (!over) return;
    const activeData = active.data.current as RuleDragData | undefined;
    const overData = over.data.current as DragData | undefined;
    if (!activeData || activeData.type !== 'rule' || !overData) return;
    const nextRules = projectRulesByDragTarget(rules, groups.map((g) => g.id), String(active.id), String(over.id), overData);
    if (nextRules === rules) return;
    applySourceRef.current = 'non_input';
    setRules(nextRules);
  };

  const actionsMenu = {
    items: [
      { key: 'import', label: '导入配置', icon: <UploadOutlined /> },
      { key: 'export', label: '导出配置', icon: <DownloadOutlined /> },
    ],
    onClick: ({ key }: { key: string }) => {
      if (key === 'import') {
        Modal.confirm({
          title: '确认导入配置？',
          content: '导入后将覆盖当前所有分组和规则配置，此操作不可撤销。',
          okText: '确认导入',
          cancelText: '取消',
          okButtonProps: { danger: true },
          onOk: () => importInputRef.current?.click(),
        });
        return;
      }
      if (key === 'export') exportRules();
    },
  };

  return (
    <div
      style={{
        width: '100vw',
        height: '100vh',
        boxSizing: 'border-box',
        display: 'flex',
        flexDirection: 'column',
      }}
    >
      <div style={{ flex: 1, minHeight: 0, padding: 12, boxSizing: 'border-box' }}>
        <div style={{ height: '100%', display: 'flex', flexDirection: 'column', minHeight: 0 }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
            <Space size={8}>
              <Typography.Title level={5} style={{ margin: 0 }}>请求重定向规则</Typography.Title>
              <Switch
                checked={redirectEnabled}
                onChange={(checked) => {
                  applySourceRef.current = 'non_input';
                  setRedirectEnabled(checked);
                  checked ? message.success('已开启重定向') : message.warning('已关闭重定向');
                }}
              />
            </Space>
            <Space size={8}>
              <Dropdown menu={actionsMenu} trigger={['hover']}>
                <Button icon={<EllipsisOutlined />} />
              </Dropdown>
              <Button type="primary" icon={<PlusOutlined />} onClick={() => setCreateGroupModalOpen(true)}>创建分组</Button>
            </Space>
          </div>

          <Modal
            title="创建分组"
            open={createGroupModalOpen}
            onCancel={() => setCreateGroupModalOpen(false)}
            onOk={() => { if (createGroup()) setCreateGroupModalOpen(false); }}
            okText="创建"
            cancelText="取消"
            destroyOnClose
          >
            <Input value={newGroupName} placeholder="请输入分组名称" onChange={(e) => setNewGroupName(e.target.value)} />
          </Modal>

          <Modal
            title="编辑分组"
            open={editGroupModalOpen}
            onCancel={() => {
              setEditGroupModalOpen(false);
              setEditingGroupId(null);
              setEditingGroupName('');
            }}
            onOk={() => { submitEditGroupName(); }}
            okText="保存"
            cancelText="取消"
            destroyOnClose
          >
            <Input value={editingGroupName} placeholder="请输入新的分组名称" onChange={(e) => setEditingGroupName(e.target.value)} />
          </Modal>

          <input
            ref={importInputRef}
            type="file"
            accept=".json,application/json"
            style={{ display: 'none' }}
            onChange={(e) => {
              const file = e.target.files?.[0];
              if (!file) return;
              void importRulesFromFile(file);
            }}
          />

          <Typography.Paragraph type="secondary" style={{ marginTop: 0, marginBottom: 8 }}>
            提示：可拖拽规则或分组调整顺序；文本修改后点击“保存”才会生效。
          </Typography.Paragraph>

          <DndContext sensors={sensors} collisionDetection={ruleDropCollisionDetection} onDragEnd={handleDragEnd}>
            <div ref={listScrollRef} style={{ flex: 1, minHeight: 0, overflow: 'auto' }}>
              <SortableContext items={groups.map((group) => toGroupSortDndId(group.id))} strategy={verticalListSortingStrategy}>
                <Collapse
                  activeKey={groups.filter((group) => !collapsedGroupIds.includes(group.id)).map((group) => group.id)}
                  onChange={(keys) => {
                    const openKeys = (Array.isArray(keys) ? keys : [keys]).map((key) => String(key));
                    setCollapsedGroupIds(groups.filter((group) => !openKeys.includes(group.id)).map((group) => group.id));
                  }}
                  items={groups.map((group) => {
                    const groupRules = rulesByGroup.get(group.id) ?? [];
                    const activeCount = groupRules.filter((rule) => isRuleEffectivelyEnabled(rule, groupEnabledMap)).length;
                    return {
                      key: group.id,
                      label: (
                        <SortableGroupHeader id={group.id}>
                          {({ attributes, listeners }) => (
                            <div {...attributes} {...listeners}>
                              <Space size={8}>
                                <Switch checked={group.enabled && redirectEnabled} onChange={(checked) => toggleGroupEnabled(group.id, checked)} />
                                <Typography.Text strong>{group.name}</Typography.Text>
                                <Typography.Text type="secondary">{activeCount}/{groupRules.length}</Typography.Text>
                              </Space>
                            </div>
                          )}
                        </SortableGroupHeader>
                      ),
                      extra: (
                        <Space size={6} onClick={(e) => e.stopPropagation()}>
                          <Button icon={<PlusOutlined />} onClick={() => addRule(group.id)} />
                          <Button icon={<EditOutlined />} onClick={() => openEditGroupModal(group.id)} />
                          <Popconfirm title="删除分组？" description="该分组下规则会一并删除" onConfirm={() => removeGroup(group.id)}>
                            <Button danger icon={<DeleteOutlined />} />
                          </Popconfirm>
                        </Space>
                      ),
                      children: groupRules.length === 0 ? (
                        <Typography.Text type="secondary">暂无规则，点击右上角 + 添加规则。</Typography.Text>
                      ) : (
                        <SortableContext items={groupRules.map((rule) => rule.id)} strategy={verticalListSortingStrategy}>
                          <Space direction="vertical" size={10} style={{ width: '100%' }}>
                            {groupRules.map((rule) => {
                              const dirty = isRuleFieldDirty(rule, 'expression') || isRuleFieldDirty(rule, 'redirectUrl');
                              return (
                                <SortableRuleCard key={rule.id} rule={rule}>
                                  {({ attributes, listeners }) => (
                                    <>
                                      <div className={`simple-rule-card-content ${highlightedRuleId === rule.id ? 'simple-rule-card-highlighted' : ''}`}>
                                          <div className="simple-rule-top-row">
                                            <Space wrap size={8}>
                                              <Button type="text" size="small" icon={<HolderOutlined />} className="simple-rule-drag-handle" {...attributes} {...listeners} />
                                              <Switch
                                                checked={rule.enabled && group.enabled && redirectEnabled}
                                                onChange={(checked) => {
                                                  applySourceRef.current = 'non_input';
                                                  updateRule(rule.id, 'enabled', checked);
                                                }}
                                              />
                                              <Select
                                                style={{ width: 120 }}
                                                value={rule.matchTarget}
                                                options={MATCH_TARGET_OPTIONS}
                                                onChange={(value) => {
                                                  applySourceRef.current = 'non_input';
                                                  updateRule(rule.id, 'matchTarget', value);
                                                }}
                                              />
                                              <Select
                                                style={{ width: 120 }}
                                                value={rule.matchMode}
                                                options={MATCH_MODE_OPTIONS}
                                                onChange={(value) => {
                                                  applySourceRef.current = 'non_input';
                                                  updateRule(rule.id, 'matchMode', value);
                                                }}
                                              />
                                            </Space>
                                            <Space size={6}>
                                              <Dropdown
                                                trigger={['click']}
                                                disabled={groups.length <= 1}
                                                menu={{
                                                  items: groups
                                                    .filter((group) => group.id !== rule.groupId)
                                                    .map((group) => ({ key: group.id, label: group.name })),
                                                  onClick: ({ key }) => {
                                                    applySourceRef.current = 'non_input';
                                                    updateRule(rule.id, 'groupId', String(key));
                                                  },
                                                }}
                                              >
                                                <Button
                                                  type="text"
                                                  icon={<SwapOutlined />}
                                                  title="移动到其他分组"
                                                  aria-label="移动到其他分组"
                                                />
                                              </Dropdown>
                                              <Button
                                                type="text"
                                                icon={<SaveOutlined />}
                                                title="保存规则"
                                                aria-label="保存规则"
                                                disabled={!dirty}
                                                onClick={() => saveRuleDraft(rule)}
                                              />
                                              <Button
                                                type="text"
                                                icon={<CopyOutlined />}
                                                title="复制规则"
                                                aria-label="复制规则"
                                                onClick={() => duplicateRule(rule.id)}
                                              />
                                              <Popconfirm title="删除规则？" onConfirm={() => removeRule(rule.id)}>
                                                <Button type="text" danger icon={<DeleteOutlined />} title="删除规则" aria-label="删除规则" />
                                              </Popconfirm>
                                            </Space>
                                          </div>
                                          <div className="simple-rule-field">
                                            <Typography.Text type="secondary">匹配表达式</Typography.Text>
                                            <Input
                                              value={getRuleFieldValue(rule, 'expression')}
                                              placeholder="请输入用于匹配的表达式"
                                              onChange={(e) => updateRuleDraft(rule, 'expression', e.target.value)}
                                            />
                                          </div>
                                          <div className="simple-rule-field">
                                            <Typography.Text type="secondary">重定向 URL</Typography.Text>
                                            <Input
                                              value={getRuleFieldValue(rule, 'redirectUrl')}
                                              placeholder="请输入重定向目标 URL"
                                              onChange={(e) => updateRuleDraft(rule, 'redirectUrl', e.target.value)}
                                            />
                                          </div>
                                          {dirty ? (
                                            <div className="simple-rule-save-row">
                                              <Typography.Text type="warning">有未保存修改</Typography.Text>
                                            </div>
                                          ) : null}
                                      </div>
                                    </>
                                  )}
                                </SortableRuleCard>
                              );
                            })}
                          </Space>
                        </SortableContext>
                      ),
                    };
                  })}
                />
              </SortableContext>
            </div>
          </DndContext>

          <div style={{ marginTop: 10 }}>
            <Typography.Text type={invalidCount ? 'warning' : 'secondary'}>
              {invalidCount
                ? `有 ${invalidCount} 条规则缺少表达式或目标 URL，请先补全。`
                : '提示：正则模式使用 RE2 语法（Chrome DNR），重定向目标支持 $1/$2... 捕获组。'}
            </Typography.Text>
          </div>
        </div>
      </div>

      <div style={{ flex: '0 0 auto', padding: 12, boxSizing: 'border-box', background: '#eef6ff', borderTop: '1px solid #dbeafe' }}>
        <Typography.Title level={5} style={{ margin: '0 0 8px 0' }}>规则测试</Typography.Title>
        <Space direction="vertical" size={8} style={{ width: '100%' }}>
          <Input
            value={testUrl}
            placeholder="输入实际 URL，点击右侧按钮测试匹配"
            onChange={(e) => setTestUrl(e.target.value)}
            onPressEnter={() => setTestTrigger((n) => n + 1)}
            addonAfter={<Button size="small" type="link" style={{ paddingInline: 0, height: 22 }} onClick={() => setTestTrigger((n) => n + 1)}>测试</Button>}
          />
          {testResult ? (
            testResult.ok ? (
              <Space direction="vertical" size={4}>
                <Typography.Text>
                  命中规则：第 {testResult.matchedIndex + 1} 条（
                  {testResult.matchedRule.matchTarget}/{testResult.matchedRule.matchMode}）
                </Typography.Text>
                <Typography.Text type="secondary">所属分组：{groupNameMap.get(testResult.matchedRule.groupId) || '未知分组'}</Typography.Text>
                <Typography.Text type="secondary">匹配表达式：{testResult.matchedRule.expression}</Typography.Text>
                <Typography.Text copyable={{ text: testResult.redirectedUrl }}>重定向后：{testResult.redirectedUrl}</Typography.Text>
              </Space>
            ) : (
              <Typography.Text type="secondary">{testResult.reason}</Typography.Text>
            )
          ) : (
            <Typography.Text type="secondary">输入 URL 后点击“测试”</Typography.Text>
          )}
        </Space>
      </div>
    </div>
  );
}

export default RedirectPanel;
