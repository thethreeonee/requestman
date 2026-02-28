import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  App,
  Button,
  Dropdown,
  Input,
  Modal,
  Space,
  Switch,
  Table,
  Typography,
} from 'antd';
import {
  EllipsisOutlined,
  PlusOutlined,
  RightOutlined,
  UploadOutlined,
  DownloadOutlined,
} from '@ant-design/icons';
import type { DragEndEvent, DragOverEvent, DragStartEvent } from '@dnd-kit/core';
import './index.css';
import {
  DndContext,
  DragOverlay,
  PointerSensor,
  useSensor,
  useSensors,
} from '@dnd-kit/core';
import { SortableContext, arrayMove, verticalListSortingStrategy } from '@dnd-kit/sortable';
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
import GroupRulesTable from './components/GroupRulesTable';
import SortableGroupRow from './components/SortableGroupRow';
import { buildGroupColumns, buildRuleColumns } from './table-columns';
import type {
  DragData,
  RedirectGroup,
  RedirectRule,
  RuleDragData,
  RuleDraft,
} from './types';

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
  const [expandedGroupIds, setExpandedGroupIds] = useState<string[]>([]);
  const [testUrl, setTestUrl] = useState('');
  const [testTrigger, setTestTrigger] = useState(0);
  const [highlightedRuleId, setHighlightedRuleId] = useState<string | null>(null);
  const [draggingRuleId, setDraggingRuleId] = useState<string | null>(null);
  const [draggingGroupId, setDraggingGroupId] = useState<string | null>(null);
  const [draggingRuleWidth, setDraggingRuleWidth] = useState<number | null>(null);
  const [hoveredGroupId, setHoveredGroupId] = useState<string | null>(null);
  const [dragPreviewRules, setDragPreviewRules] = useState<RedirectRule[] | null>(null);
  const applySourceRef = useRef<'init' | 'input' | 'non_input' | 'add' | 'group_toggle'>('init');
  const dragPreviewRulesRef = useRef<RedirectRule[] | null>(null);
  const highlightTimerRef = useRef<number | null>(null);
  const listScrollRef = useRef<HTMLDivElement | null>(null);
  const importInputRef = useRef<HTMLInputElement | null>(null);
  const expandedBeforeGroupDragRef = useRef<string[] | null>(null);
  const sensors = useSensors(useSensor(PointerSensor, { activationConstraint: { distance: 4 } }));

  useEffect(() => {
    chrome.storage.local.get([REDIRECT_RULES_KEY, REDIRECT_ENABLED_KEY, REDIRECT_GROUPS_KEY], (res) => {
      const normalizedGroups = normalizeGroups(res?.[REDIRECT_GROUPS_KEY]);
      const groupIds = new Set(normalizedGroups.map((g) => g.id));
      const fallbackGroupId = normalizedGroups[0]?.id ?? DEFAULT_GROUP_ID;
      setGroups(normalizedGroups);
      setExpandedGroupIds(normalizedGroups.map((g) => g.id));
      setRules(normalizeRules(res?.[REDIRECT_RULES_KEY], groupIds, fallbackGroupId));
      setRedirectEnabled(res?.[REDIRECT_ENABLED_KEY] !== false);
      setRulesLoaded(true);
    });
  }, []);

  const addRule = (groupId: string) => {
    applySourceRef.current = 'add';
    setRules((prev) => [
      {
        id: genId(),
        enabled: true,
        groupId,
        matchTarget: 'url',
        matchMode: 'contains',
        expression: '',
        redirectUrl: '',
      },
      ...prev,
    ]);
  };

  const updateRule = <K extends keyof RedirectRule>(id: string, key: K, value: RedirectRule[K]) => {
    setRules((prev) =>
      prev.map((r) => (r.id === id ? { ...r, [key]: value } : r)),
    );
  };

  const toggleRuleEnabled = (id: string, enabled: boolean) => {
    applySourceRef.current = 'non_input';
    setRules((prev) => prev.map((r) => (r.id === id ? { ...r, enabled } : r)));
    enabled ? message.success('已启用规则') : message.warning('已禁用规则');
  };

  const updateRuleWithToast = <K extends keyof RedirectRule>(
    id: string,
    key: K,
    value: RedirectRule[K],
    toastText: string,
  ) => {
    applySourceRef.current = 'non_input';
    updateRule(id, key, value);
    message.success(toastText);
  };

  const removeRule = (id: string) => {
    const targetRule = rules.find((r) => r.id === id);
    const groupName = groups.find((g) => g.id === targetRule?.groupId)?.name || '未知分组';
    applySourceRef.current = 'non_input';
    setRules((prev) => prev.filter((r) => r.id !== id));
    setRuleDrafts((prev) => {
      const next = { ...prev };
      delete next[id];
      return next;
    });
    message.success(`已删除规则（分组：${groupName}）`);
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
    setExpandedGroupIds((prev) => [next.id, ...prev]);
    setNewGroupName('');
    message.success(`已创建分组：${name}`);
    return true;
  };

  const toggleGroupEnabled = (id: string, enabled: boolean) => {
    applySourceRef.current = 'group_toggle';
    const groupName = groups.find((g) => g.id === id)?.name || '未命名分组';
    setGroups((prev) => prev.map((g) => (g.id === id ? { ...g, enabled } : g)));
    enabled
      ? message.success(`已开启分组：${groupName}`)
      : message.warning(`已关闭分组：${groupName}`);
  };

  const removeGroup = (groupId: string) => {
    const groupName = groups.find((g) => g.id === groupId)?.name || '未命名分组';
    const count = rules.filter((r) => r.groupId === groupId).length;
    applySourceRef.current = 'non_input';
    setGroups((prev) => {
      const next = prev.filter((g) => g.id !== groupId);
      if (next.length > 0) return next;
      return [{ id: DEFAULT_GROUP_ID, name: DEFAULT_GROUP_NAME, enabled: true }];
    });
    setExpandedGroupIds((prev) => prev.filter((id) => id !== groupId));
    setRules((prev) => prev.filter((r) => r.groupId !== groupId));
    setRuleDrafts((prev) => {
      const next = { ...prev };
      for (const [ruleId, d] of Object.entries(prev)) {
        if (!d) continue;
        const targetRule = rules.find((r) => r.id === ruleId);
        if (targetRule?.groupId === groupId) {
          delete next[ruleId];
        }
      }
      return next;
    });
    message.success(`已删除分组：${groupName}（共 ${count} 条规则）`);
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
    setGroups((prev) =>
      prev.map((g) => (g.id === editingGroupId ? { ...g, name: nextName } : g)),
    );
    setEditGroupModalOpen(false);
    setEditingGroupId(null);
    setEditingGroupName('');
    message.success(`已更新分组名称为：${nextName}`);
    return true;
  };

  const duplicateRule = (id: string) => {
    const sourceRule = rules.find((r) => r.id === id);
    const groupName = groups.find((g) => g.id === sourceRule?.groupId)?.name || '未知分组';
    applySourceRef.current = 'non_input';
    setRules((prev) => {
      const idx = prev.findIndex((r) => r.id === id);
      if (idx < 0) return prev;
      const src = prev[idx];
      const copied: RedirectRule = {
        ...src,
        id: genId(),
      };
      const next = [...prev];
      next.splice(idx + 1, 0, copied);
      return next;
    });
    message.success(`已复制规则到分组：${groupName}`);
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

  const updateRuleDraft = (
    row: RedirectRule,
    key: 'expression' | 'redirectUrl',
    value: string,
  ) => {
    setRuleDrafts((prev) => {
      const cur = prev[row.id] ?? {};
      const next = { ...prev, [row.id]: { ...cur, [key]: value } };
      if (next[row.id]?.expression === undefined && next[row.id]?.redirectUrl === undefined) {
        delete next[row.id];
      }
      return next;
    });
  };

  const saveRuleField = (row: RedirectRule, key: 'expression' | 'redirectUrl') => {
    const value = getRuleFieldValue(row, key);
    if (!isRuleFieldDirty(row, key)) return;
    if (!value.trim()) return;
    applySourceRef.current = 'non_input';
    setRules((prev) =>
      prev.map((r) => (r.id === row.id ? { ...r, [key]: value } : r)),
    );
    setRuleDrafts((prev) => {
      const cur = prev[row.id];
      if (!cur) return prev;
      const nextDraft: RuleDraft = { ...cur, [key]: undefined };
      const next = { ...prev };
      if (nextDraft.expression === undefined && nextDraft.redirectUrl === undefined) {
        delete next[row.id];
      } else {
        next[row.id] = nextDraft;
      }
      return next;
    });
    message.success('规则已保存并生效');
  };

  const handleDragEnd = (evt: DragEndEvent) => {
    if (draggingGroupId) {
      setDraggingGroupId(null);
      const previousExpanded = expandedBeforeGroupDragRef.current;
      expandedBeforeGroupDragRef.current = null;

      const activeGroupId = parseGroupSortDndId(String(evt.active.id));
      const overGroupId = evt.over ? parseGroupSortDndId(String(evt.over.id)) : null;
      if (previousExpanded) {
        const visible = new Set(groups.map((g) => g.id));
        setExpandedGroupIds(previousExpanded.filter((id) => visible.has(id)));
      }
      if (!activeGroupId || !overGroupId || activeGroupId === overGroupId) return;

      const oldIndex = groups.findIndex((g) => g.id === activeGroupId);
      const newIndex = groups.findIndex((g) => g.id === overGroupId);
      if (oldIndex < 0 || newIndex < 0 || oldIndex === newIndex) return;

      applySourceRef.current = 'non_input';
      setGroups((prev) => arrayMove(prev, oldIndex, newIndex));
      message.success('已更新分组顺序');
      return;
    }

    setDraggingRuleId(null);
    setDraggingRuleWidth(null);
    setHoveredGroupId(null);
    const projectedRules = dragPreviewRulesRef.current;
    dragPreviewRulesRef.current = null;
    setDragPreviewRules((prev) => (prev === null ? prev : null));

    const { active, over } = evt;
    if (!over) return;

    const activeData = active.data.current as RuleDragData | undefined;
    const overData = over.data.current as DragData | undefined;
    if (!activeData || activeData.type !== 'rule' || !overData) return;

    const activeId = String(active.id);
    const sourceGroupId = activeData.groupId;
    const targetGroupId = overData.groupId;
    const groupOrder = groups.map((g) => g.id);
    const overId = String(over.id);
    const nextRules =
      projectedRules ?? projectRulesByDragTarget(rules, groupOrder, activeId, overId, overData);

    const changed = nextRules !== rules;
    if (nextRules !== rules) {
      applySourceRef.current = 'non_input';
      setRules(nextRules);
    }

    if (!changed) return;

    if (sourceGroupId !== targetGroupId) {
      const targetName = groups.find((g) => g.id === targetGroupId)?.name || '未知分组';
      message.success(`已移动到分组：${targetName}`);
      return;
    }

    message.success('已更新规则顺序');
  };

  const handleDragStart = (evt: DragStartEvent) => {
    const activeData = evt.active.data.current as RuleDragData | { type: 'group-sort'; groupId: string } | undefined;
    if (!activeData) return;

    if (activeData.type === 'group-sort') {
      setDraggingGroupId(activeData.groupId);
      if (expandedBeforeGroupDragRef.current === null) {
        expandedBeforeGroupDragRef.current = expandedGroupIds;
      }
      setExpandedGroupIds([]);
      setDraggingRuleId(null);
      setDraggingRuleWidth(null);
      setHoveredGroupId(null);
      dragPreviewRulesRef.current = null;
      setDragPreviewRules((prev) => (prev === null ? prev : null));
      return;
    }

    if (activeData.type !== 'rule') {
      setDraggingRuleId(null);
      setDraggingRuleWidth(null);
      setHoveredGroupId(null);
      dragPreviewRulesRef.current = null;
      setDragPreviewRules((prev) => (prev === null ? prev : null));
      return;
    }

    setDraggingGroupId(null);
    setDraggingRuleId(String(evt.active.id));
    const width = (evt.active.rect.current?.initial as { width?: number } | undefined)?.width;
    setDraggingRuleWidth(typeof width === 'number' && width > 0 ? width : null);
    setHoveredGroupId(null);
    dragPreviewRulesRef.current = null;
    setDragPreviewRules((prev) => (prev === null ? prev : null));
  };

  const handleRuleDragOver = (evt: DragOverEvent) => {
    if (draggingGroupId) return;
    const activeData = evt.active.data.current as RuleDragData | undefined;
    if (!activeData || activeData.type !== 'rule') {
      setHoveredGroupId((prev) => (prev === null ? prev : null));
      dragPreviewRulesRef.current = null;
      setDragPreviewRules((prev) => (prev === null ? prev : null));
      return;
    }

    const over = evt.over;
    const overData = over?.data.current as DragData | undefined;
    const nextGroupId = overData?.groupId ?? null;
    setHoveredGroupId((prev) => (prev === nextGroupId ? prev : nextGroupId));

    if (!over || !overData) {
      dragPreviewRulesRef.current = null;
      setDragPreviewRules((prev) => (prev === null ? prev : null));
      return;
    }

    const activeId = String(evt.active.id);
    const overId = String(over.id);
    const groupOrder = groups.map((g) => g.id);

    setDragPreviewRules((prev) => {
      const base = prev ?? rules;
      const next = projectRulesByDragTarget(base, groupOrder, activeId, overId, overData);
      const resolved = next === base ? prev : next;
      dragPreviewRulesRef.current = resolved;
      return resolved;
    });
  };

  const renderedRules = dragPreviewRules ?? rules;
  const draggingRule = useMemo(
    () => renderedRules.find((r) => r.id === draggingRuleId) ?? null,
    [draggingRuleId, renderedRules],
  );

  const exportRules = () => {
    try {
      const grouped = groups.map((g) => ({
        id: g.id,
        name: g.name,
        enabled: g.enabled,
        rules: rules
          .filter((r) => r.groupId === g.id)
          .map((r) => ({
            id: r.id,
            enabled: r.enabled,
            matchTarget: r.matchTarget,
            matchMode: r.matchMode,
            expression: r.expression,
            redirectUrl: r.redirectUrl,
          })),
      }));
      const payload = {
        version: 2,
        enabled: redirectEnabled,
        groups: grouped,
      };
      const blob = new Blob([JSON.stringify(payload, null, 2)], {
        type: 'application/json;charset=utf-8',
      });
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
        const fallbackGroupId = importedGroups[0]?.id ?? DEFAULT_GROUP_ID;
        importedRules = normalizeRules(parsed, groupIds, fallbackGroupId);
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
          const fallbackGroupId = importedGroups[0]?.id ?? DEFAULT_GROUP_ID;
          importedRules = normalizeRules(flatRules, groupIds, fallbackGroupId);
        } else {
          importedGroups = normalizeGroups(obj.groups);
          const groupIds = new Set(importedGroups.map((g) => g.id));
          const fallbackGroupId = importedGroups[0]?.id ?? DEFAULT_GROUP_ID;
          importedRules = normalizeRules(obj.rules, groupIds, fallbackGroupId);
        }
        if (typeof obj.enabled === 'boolean') {
          importedEnabled = obj.enabled;
        }
      } else {
        throw new Error('文件内容格式不正确');
      }

      applySourceRef.current = 'non_input';
      setGroups(importedGroups);
      setExpandedGroupIds(importedGroups.map((g) => g.id));
      setRules(importedRules);
      setRuleDrafts({});
      setRedirectEnabled(importedEnabled);
      message.success(`导入成功，共 ${importedRules.length} 条规则`);
    } catch (err) {
      message.error(`导入失败: ${String((err as Error)?.message || err)}`);
    } finally {
      if (importInputRef.current) {
        importInputRef.current.value = '';
      }
    }
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
          onOk: () => {
            importInputRef.current?.click();
          },
        });
        return;
      }
      if (key === 'export') {
        exportRules();
      }
    },
  };

  const persistRules = (
    nextGroups: RedirectGroup[],
    nextRules: RedirectRule[],
    enabled: boolean,
    opts?: { showSuccessToast?: boolean; onSuccess?: (activeCount: number) => void },
  ) => {
    chrome.storage.local.set(
      {
        [REDIRECT_GROUPS_KEY]: nextGroups,
        [REDIRECT_RULES_KEY]: nextRules,
        [REDIRECT_ENABLED_KEY]: enabled,
      },
      () => {
        chrome.runtime.sendMessage(
          { type: 'redirectRules/apply', groups: nextGroups, rules: nextRules, enabled },
          (resp) => {
            if (chrome.runtime.lastError) {
              message.error(`应用失败: ${chrome.runtime.lastError.message}`);
              return;
            }
            if (!resp?.ok) {
              message.error(`应用失败: ${resp?.error || 'unknown error'}`);
              return;
            }
            const ignored = Number(resp.ignoredCount || 0);
            if (ignored > 0) {
              // 具体操作本身会给出单独提示，这里避免重复弹出“已生效/忽略”提示。
              opts?.onSuccess?.(resp.activeCount);
              return;
            }
            opts?.onSuccess?.(resp.activeCount);
          },
        );
      },
    );
  };

  useEffect(() => {
    if (!rulesLoaded) return;
    const timer = window.setTimeout(() => {
      const source = applySourceRef.current;
      persistRules(groups, rules, redirectEnabled, { showSuccessToast: source === 'non_input' });
      applySourceRef.current = 'input';
    }, 100);
    return () => window.clearTimeout(timer);
  }, [groups, rules, redirectEnabled, rulesLoaded]);

  useEffect(() => {
    if (groups.length === 0) return;
    setExpandedGroupIds((prev) => {
      const visible = new Set(groups.map((g) => g.id));
      const kept = prev.filter((id) => visible.has(id));
      const missing = groups.map((g) => g.id).filter((id) => !kept.includes(id));
      return [...kept, ...missing];
    });
  }, [groups]);

  const invalidCount = useMemo(
    () =>
      rules.filter(
        (r) => !r.expression.trim() || !r.redirectUrl.trim() || !groups.find((g) => g.id === r.groupId),
      ).length,
    [groups, rules],
  );
  const groupEnabledMap = useMemo(
    () => new Map(groups.map((g) => [g.id, g.enabled] as const)),
    [groups],
  );
  const testResult = useMemo(() => {
    if (testTrigger === 0) return null;
    const t = testUrl.trim();
    if (!t) return null;
    return simulateRedirect(t, rules, groupEnabledMap);
  }, [groupEnabledMap, rules, testTrigger, testUrl]);
  const groupNameMap = useMemo(
    () => new Map(groups.map((g) => [g.id, g.name] as const)),
    [groups],
  );
  const rulesByGroup = useMemo(() => {
    const m = new Map<string, RedirectRule[]>();
    for (const g of groups) m.set(g.id, []);
    for (const rule of renderedRules) {
      const list = m.get(rule.groupId);
      if (list) list.push(rule);
    }
    return m;
  }, [groups, renderedRules]);
  const groupRuleCountMap = useMemo(() => {
    const m = new Map<string, number>();
    for (const rule of renderedRules) {
      m.set(rule.groupId, (m.get(rule.groupId) ?? 0) + 1);
    }
    return m;
  }, [renderedRules]);
  const groupActiveRuleCountMap = useMemo(() => {
    const m = new Map<string, number>();
    for (const rule of renderedRules) {
      if (!isRuleEffectivelyEnabled(rule, groupEnabledMap)) continue;
      m.set(rule.groupId, (m.get(rule.groupId) ?? 0) + 1);
    }
    return m;
  }, [groupEnabledMap, renderedRules]);

  const columns = buildRuleColumns({
    groups,
    redirectEnabled,
    groupEnabledMap,
    getRuleFieldValue,
    isRuleFieldDirty,
    updateRuleDraft,
    saveRuleField,
    onToggleRuleEnabled: toggleRuleEnabled,
    onUpdateRuleMatchTarget: (id, value) =>
      updateRuleWithToast(id, 'matchTarget', value, '已更新匹配对象'),
    onUpdateRuleMatchMode: (id, value) =>
      updateRuleWithToast(id, 'matchMode', value, '已更新匹配模式'),
    onMoveRuleGroup: (id, groupId) =>
      updateRuleWithToast(id, 'groupId', groupId, '已移动到新分组'),
    onDuplicateRule: duplicateRule,
    onRemoveRule: removeRule,
  });

  const groupColumns = buildGroupColumns({
    redirectEnabled,
    groupRuleCountMap,
    groupActiveRuleCountMap,
    onToggleGroupEnabled: toggleGroupEnabled,
    onAddRule: addRule,
    onOpenEditGroupModal: openEditGroupModal,
    onRemoveGroup: removeGroup,
  });

  useEffect(() => {
    if (!testResult?.ok) return;

    const ruleId = testResult.matchedRule.id;
    setHighlightedRuleId(ruleId);

    if (highlightTimerRef.current != null) {
      window.clearTimeout(highlightTimerRef.current);
    }
    highlightTimerRef.current = window.setTimeout(() => {
      setHighlightedRuleId((cur) => (cur === ruleId ? null : cur));
    }, 2000);

    const container = listScrollRef.current;
    if (!container) return;
    const rows = container.querySelectorAll('tr[data-row-key]');
    const target = Array.from(rows).find(
      (row) => (row as HTMLTableRowElement).dataset.rowKey === ruleId,
    ) as HTMLTableRowElement | undefined;
    if (!target) return;

    const rowRect = target.getBoundingClientRect();
    const containerRect = container.getBoundingClientRect();
    if (rowRect.top < containerRect.top || rowRect.bottom > containerRect.bottom) {
      target.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    }
  }, [testResult]);

  useEffect(() => {
    return () => {
      if (highlightTimerRef.current != null) {
        window.clearTimeout(highlightTimerRef.current);
      }
    };
  }, []);

  const renderGroupRulesTable = (group: RedirectGroup) => (
    <GroupRulesTable
      groupId={group.id}
      groupRules={rulesByGroup.get(group.id) ?? []}
      columns={columns}
      highlightedRuleId={highlightedRuleId}
      groupEnabledMap={groupEnabledMap}
      dragPreviewRules={dragPreviewRules}
      draggingRuleId={draggingRuleId}
    />
  );

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
      <div
        style={{
          flex: 1,
          minHeight: 0,
          padding: 12,
          boxSizing: 'border-box',
        }}
      >
        <div
          style={{
            height: '100%',
            display: 'flex',
            flexDirection: 'column',
            flex: 1,
            minHeight: 0,
          }}
        >
          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              marginBottom: 8,
            }}
          >
            <Space size={8}>
              <Typography.Title level={5} style={{ margin: 0 }}>
                请求重定向规则
              </Typography.Title>
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
              <Button
                type="primary"
                icon={<PlusOutlined />}
                onClick={() => {
                  setNewGroupName('');
                  setCreateGroupModalOpen(true);
                }}
              >
                创建分组
              </Button>
            </Space>
          </div>
          <Modal
            title="创建分组"
            open={createGroupModalOpen}
            onCancel={() => setCreateGroupModalOpen(false)}
            onOk={() => {
              if (createGroup()) {
                setCreateGroupModalOpen(false);
              }
            }}
            okText="创建"
            cancelText="取消"
            destroyOnClose
          >
            <Input
              autoFocus
              value={newGroupName}
              placeholder="请输入分组名称"
              onChange={(e) => setNewGroupName(e.target.value)}
              onPressEnter={() => {
                if (createGroup()) {
                  setCreateGroupModalOpen(false);
                }
              }}
            />
          </Modal>
          <Modal
            title="编辑分组"
            open={editGroupModalOpen}
            onCancel={() => {
              setEditGroupModalOpen(false);
              setEditingGroupId(null);
              setEditingGroupName('');
            }}
            onOk={() => {
              submitEditGroupName();
            }}
            okText="保存"
            cancelText="取消"
            destroyOnClose
          >
            <Input
              autoFocus
              value={editingGroupName}
              placeholder="请输入新的分组名称"
              onChange={(e) => setEditingGroupName(e.target.value)}
              onPressEnter={() => {
                submitEditGroupName();
              }}
            />
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

          <Typography.Paragraph type="secondary" style={{ marginTop: 0 }}>
            规则在网络层生效，支持 script/css/img/xhr/fetch。按列表顺序执行，命中第一条即重定向。
          </Typography.Paragraph>

          <DndContext
            sensors={sensors}
            collisionDetection={ruleDropCollisionDetection}
            onDragStart={handleDragStart}
            onDragOver={handleRuleDragOver}
            onDragEnd={handleDragEnd}
            onDragCancel={() => {
              setDraggingGroupId(null);
              if (expandedBeforeGroupDragRef.current) {
                const visible = new Set(groups.map((g) => g.id));
                setExpandedGroupIds(expandedBeforeGroupDragRef.current.filter((id) => visible.has(id)));
                expandedBeforeGroupDragRef.current = null;
              }
              setDraggingRuleId(null);
              setDraggingRuleWidth(null);
              setHoveredGroupId(null);
              dragPreviewRulesRef.current = null;
              setDragPreviewRules((prev) => (prev === null ? prev : null));
            }}
          >
            <div ref={listScrollRef} style={{ flex: 1, minHeight: 0, overflow: 'auto' }}>
              <SortableContext
                items={groups.map((g) => toGroupSortDndId(g.id))}
                strategy={verticalListSortingStrategy}
              >
                <Table
                  className="group-table"
                  size="small"
                  rowKey="id"
                  pagination={false}
                  columns={groupColumns as any}
                  dataSource={groups}
                  components={{
                    body: {
                      row: SortableGroupRow,
                    },
                  }}
                  onRow={(record) => ({
                    'data-group-id': (record as RedirectGroup).id,
                  })}
                  rowClassName={(record) => {
                    const groupId = (record as RedirectGroup).id;
                    if (draggingGroupId === groupId) return 'group-row-dragging';
                    return hoveredGroupId === groupId ? 'group-drop-target' : '';
                  }}
                  expandable={{
                  columnWidth: 24,
                  expandedRowKeys: expandedGroupIds,
                  expandedRowRender: (group) => renderGroupRulesTable(group as RedirectGroup),
                  onExpandedRowsChange: (keys) => setExpandedGroupIds(keys.map(String)),
                  expandIcon: ({ expanded, onExpand, record }) => (
                    <span
                      className="group-expand-icon-btn"
                      onClick={(e) => onExpand(record, e)}
                      style={{
                        display: 'inline-flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                        width: 24,
                        height: 24,
                        cursor: 'pointer',
                        color: 'rgba(0,0,0,0.45)',
                      }}
                      title={expanded ? '收起' : '展开'}
                    >
                      <RightOutlined
                        style={{
                          fontSize: 12,
                          transform: expanded ? 'rotate(90deg)' : 'rotate(0deg)',
                          transition: 'transform 0.2s ease',
                        }}
                      />
                    </span>
                  ),
                }}
                  locale={{ emptyText: '暂无分组，点击右上角创建分组' }}
                />
              </SortableContext>
            </div>
            <DragOverlay>
              {draggingGroupId ? (
                <div className="group-drag-overlay">
                  {groups.find((group) => group.id === draggingGroupId)?.name || '未命名分组'}
                </div>
              ) : draggingRule ? (
                <div
                  className="rule-drag-overlay"
                  style={draggingRuleWidth ? { width: draggingRuleWidth } : undefined}
                >
                  <Table
                    className="rules-table nested-rules-table rule-drag-overlay-table"
                    size="small"
                    rowKey="id"
                    showHeader={false}
                    pagination={false}
                    columns={columns as any}
                    dataSource={[draggingRule]}
                  />
                </div>
              ) : null}
            </DragOverlay>
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

      <div
        style={{
          flex: '0 0 auto',
          padding: 12,
          boxSizing: 'border-box',
          background: '#eef6ff',
          borderTop: '1px solid #dbeafe',
        }}
      >
        <div>
          <Typography.Title level={5} style={{ margin: '0 0 8px 0' }}>
            规则测试
          </Typography.Title>
          <Space direction="vertical" size={8} style={{ width: '100%' }}>
            <Input
              value={testUrl}
              placeholder="输入实际 URL，点击右侧按钮测试匹配"
              onChange={(e) => setTestUrl(e.target.value)}
              onPressEnter={() => setTestTrigger((n) => n + 1)}
              addonAfter={(
                <Button
                  size="small"
                  type="link"
                  style={{ paddingInline: 0, height: 22 }}
                  onClick={() => setTestTrigger((n) => n + 1)}
                >
                  测试
                </Button>
              )}
            />
            {testResult ? (
              testResult.ok ? (
                <Space direction="vertical" size={4}>
                  <Typography.Text>
                    命中规则：第 {testResult.matchedIndex + 1} 条（
                    {testResult.matchedRule.matchTarget}/{testResult.matchedRule.matchMode}
                    ）
                  </Typography.Text>
                  <Typography.Text type="secondary">
                    所属分组：{groupNameMap.get(testResult.matchedRule.groupId) || '未知分组'}
                  </Typography.Text>
                  <Typography.Text type="secondary">
                    匹配表达式：{testResult.matchedRule.expression}
                  </Typography.Text>
                  <Typography.Text copyable={{ text: testResult.redirectedUrl }}>
                    重定向后：{testResult.redirectedUrl}
                  </Typography.Text>
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
    </div>
  );
}

export default RedirectPanel;
