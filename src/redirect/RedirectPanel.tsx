import React, { useEffect, useMemo, useRef, useState } from 'react';
import { App, Modal } from 'antd';
import {
  DEFAULT_GROUP_ID,
  REDIRECT_ENABLED_KEY,
  REDIRECT_GROUPS_KEY,
  REDIRECT_RULES_KEY,
} from './constants';
import { createDefaultCondition, genId, normalizeGroups, normalizeRules } from './rule-utils';
import type { RedirectGroup, RedirectRule } from './types';
import RedirectRuleDetail from './components/RedirectRuleDetail';
import RewriteStringRuleDetail from './components/RewriteStringRuleDetail';
import QueryParamsRuleDetail from './components/QueryParamsRuleDetail';
import ModifyRequestBodyRuleDetail from './components/ModifyRequestBodyRuleDetail';
import ModifyResponseBodyRuleDetail from './components/ModifyResponseBodyRuleDetail';
import ModifyHeadersRuleDetail from './components/ModifyHeadersRuleDetail';
import UserAgentRuleDetail from './components/UserAgentRuleDetail';
import CancelRequestRuleDetail from './components/CancelRequestRuleDetail';
import RequestDelayRuleDetail from './components/RequestDelayRuleDetail';
import RedirectRuleList from './components/RedirectRuleList';
import './index.css';

type PageState = { type: 'list' } | { type: 'detail'; ruleId: string; isNew: boolean };

export default function RedirectPanel() {
  const { message } = App.useApp();
  const [groups, setGroups] = useState<RedirectGroup[]>([]);
  const [rules, setRules] = useState<RedirectRule[]>([]);
  const [redirectEnabled, setRedirectEnabled] = useState(true);
  const [rulesLoaded, setRulesLoaded] = useState(false);
  const [collapsedGroupIds, setCollapsedGroupIds] = useState<string[]>([]);
  const [groupModal, setGroupModal] = useState<{ open: boolean; mode: 'create' | 'rename' | 'move'; groupId?: string; ruleId?: string }>({ open: false, mode: 'create' });
  const [groupInput, setGroupInput] = useState('');
  const [page, setPage] = useState<PageState>({ type: 'list' });
  const [workingRule, setWorkingRule] = useState<RedirectRule | null>(null);
  const [originalRule, setOriginalRule] = useState<RedirectRule | null>(null);
  const hasInitializedStorageSync = useRef(false);
  const importInputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    chrome.storage.local.get([REDIRECT_RULES_KEY, REDIRECT_ENABLED_KEY, REDIRECT_GROUPS_KEY], (res) => {
      const normalizedGroups = normalizeGroups(res?.[REDIRECT_GROUPS_KEY]);
      const groupIds = new Set(normalizedGroups.map((g) => g.id));
      setGroups(normalizedGroups);
      setRules(normalizeRules(res?.[REDIRECT_RULES_KEY], groupIds, normalizedGroups[0]?.id ?? DEFAULT_GROUP_ID));
      setRedirectEnabled(res?.[REDIRECT_ENABLED_KEY] !== false);
      setRulesLoaded(true);
    });
  }, []);

  useEffect(() => {
    if (!rulesLoaded) return;
    if (!hasInitializedStorageSync.current) {
      hasInitializedStorageSync.current = true;
      return;
    }
    chrome.storage.local.set({ [REDIRECT_GROUPS_KEY]: groups, [REDIRECT_RULES_KEY]: rules, [REDIRECT_ENABLED_KEY]: redirectEnabled });
    chrome.runtime.sendMessage({ type: 'redirectRules/apply', groups, rules, enabled: redirectEnabled });
  }, [groups, rules, redirectEnabled, rulesLoaded]);

  const openRuleDetail = (ruleId: string) => {
    const found = rules.find((r) => r.id === ruleId);
    if (!found) return;
    setWorkingRule(JSON.parse(JSON.stringify(found)));
    setOriginalRule(JSON.parse(JSON.stringify(found)));
    setPage({ type: 'detail', ruleId, isNew: false });
  };

  const createRule = (ruleType: RedirectRule['type']) => {
    const groupId = groups[0]?.id;
    if (!groupId) return;
    const newRule: RedirectRule = {
      id: genId(),
      name: `新建规则 ${rules.length + 1}`,
      type: ruleType,
      enabled: true,
      groupId,
      conditions: [createDefaultCondition()],
    };
    setWorkingRule(JSON.parse(JSON.stringify(newRule)));
    setOriginalRule(JSON.parse(JSON.stringify(newRule)));
    setPage({ type: 'detail', ruleId: newRule.id, isNew: true });
  };

  const onBack = () => {
    if (!workingRule || !originalRule) return setPage({ type: 'list' });
    const { enabled: _workingEnabled, ...workingRuleWithoutEnabled } = workingRule;
    const { enabled: _originalEnabled, ...originalRuleWithoutEnabled } = originalRule;
    if (JSON.stringify(workingRuleWithoutEnabled) !== JSON.stringify(originalRuleWithoutEnabled)) {
      Modal.confirm({
        title: '存在未保存修改',
        content: '修改不会被保存，确认返回吗？',
        onOk: () => setPage({ type: 'list' }),
      });
      return;
    }
    setPage({ type: 'list' });
  };

  const saveDetailRule = () => {
    if (!workingRule || page.type !== 'detail') return;
    if (workingRule.type === 'redirect_request') {
      const invalid = workingRule.conditions.some((c) => !c.expression.trim() || !c.redirectTarget.trim());
      if (invalid) return message.warning('还有条件配置未输入完整');
    }
    if (workingRule.type === 'rewrite_string') {
      const invalid = workingRule.conditions.some((c) => !c.expression.trim() || !c.rewriteFrom.trim());
      if (invalid) return message.warning('还有条件配置未输入完整');
    }
    if (workingRule.type === 'query_params') {
      const invalid = workingRule.conditions.some((c) => {
        if (!c.expression.trim() || c.queryParamModifications.length === 0) return true;
        return c.queryParamModifications.some((item) => !item.key.trim() || (item.action !== 'delete' && !item.value.trim()));
      });
      if (invalid) return message.warning('还有条件配置未输入完整');
    }
    setRules((prev) => {
      if (page.isNew && !prev.some((r) => r.id === workingRule.id)) {
        return [workingRule, ...prev];
      }
      return prev.map((r) => (r.id === workingRule.id ? workingRule : r));
    });
    if (page.isNew) {
      setPage({ type: 'detail', ruleId: workingRule.id, isNew: false });
    }
    setOriginalRule(JSON.parse(JSON.stringify(workingRule)));
    message.success('规则已保存');
  };

  const toggleDetailRuleEnabled = (ruleId: string, enabled: boolean) => {
    setRules((prev) => prev.map((rule) => (rule.id === ruleId ? { ...rule, enabled } : rule)));
    setWorkingRule((prev) => (prev?.id === ruleId ? { ...prev, enabled } : prev));
    setOriginalRule((prev) => (prev?.id === ruleId ? { ...prev, enabled } : prev));
    message.success(enabled ? '规则已启用' : '规则已停用');
  };

  const moveRuleToGroup = () => {
    if (!groupModal.ruleId) return;
    const name = groupInput.trim();
    if (!name) return;
    let target = groups.find((g) => g.name === name);
    const movedRule = rules.find((r) => r.id === groupModal.ruleId);
    if (!movedRule) return;
    if (!target) {
      target = { id: genId(), name, enabled: true };
      setGroups((prev) => [...prev, target!]);
      message.success(`规则组「${name}」已创建`);
    }
    setRules((prev) => prev.map((r) => (r.id === groupModal.ruleId ? { ...r, groupId: target!.id } : r)));
    message.success(`规则「${movedRule.name}」已移动到规则组「${target.name}」`);
    setGroupModal({ open: false, mode: 'create' });
    setGroupInput('');
  };

  const confirmGroupModal = () => {
    if (groupModal.mode === 'move') return moveRuleToGroup();
    const name = groupInput.trim();
    if (!name) return;
    if (groupModal.mode === 'create') {
      setGroups((prev) => [{ id: genId(), name, enabled: true }, ...prev]);
      message.success(`规则组「${name}」已创建`);
    }
    if (groupModal.mode === 'rename' && groupModal.groupId) {
      const group = groups.find((g) => g.id === groupModal.groupId);
      setGroups((prev) => prev.map((g) => (g.id === groupModal.groupId ? { ...g, name } : g)));
      message.success(`规则组「${group?.name ?? ''}」已重命名为「${name}」`);
    }
    setGroupModal({ open: false, mode: 'create' });
    setGroupInput('');
  };

  const deleteGroup = (groupId: string) => {
    Modal.confirm({
      title: '确认删除该规则组？',
      content: '删除规则组会同时删除组内所有规则。',
      okButtonProps: { danger: true },
      onOk: () => {
        const deletedGroup = groups.find((g) => g.id === groupId);
        const deletedRuleCount = rules.filter((r) => r.groupId === groupId).length;
        setGroups((prev) => prev.filter((g) => g.id !== groupId));
        setRules((prev) => prev.filter((r) => r.groupId !== groupId));
        message.success(`规则组「${deletedGroup?.name ?? ''}」已删除（含 ${deletedRuleCount} 条规则）`);
      },
    });
  };

  const duplicateGroup = (groupId: string) => {
    const group = groups.find((g) => g.id === groupId);
    if (!group) return;
    const newGroupId = genId();
    setGroups((prev) => {
      const idx = prev.findIndex((g) => g.id === groupId);
      const cp = { ...group, id: newGroupId, name: `${group.name} 副本` };
      const next = [...prev];
      next.splice(idx + 1, 0, cp);
      return next;
    });
    setRules((prev) => {
      const selected = prev.filter((r) => r.groupId === groupId).map((r) => ({ ...r, id: genId(), groupId: newGroupId, name: `${r.name} 副本` }));
      return [...prev, ...selected];
    });
    message.success(`规则组「${group.name}」已复制`);
  };

  const currentRule = useMemo(() => {
    if (page.type !== 'detail' || !workingRule) return null;
    return workingRule;
  }, [page, workingRule]);

  const exportConfig = () => {
    const now = new Date();
    const pad = (value: number) => String(value).padStart(2, '0');
    const exportTime = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
    const payload = {
      version: 1,
      exportedAt: now.toISOString(),
      groups,
      rules,
    };
    const blob = new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `requestman-rules-${exportTime}.json`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  };

  const importConfig = () => {
    importInputRef.current?.click();
  };

  const onImportFileChange: React.ChangeEventHandler<HTMLInputElement> = async (event) => {
    const file = event.target.files?.[0];
    event.target.value = '';
    if (!file) return;
    try {
      const text = await file.text();
      const parsed = JSON.parse(text) as Record<string, unknown>;
      const importedGroups = normalizeGroups(parsed?.groups);
      const importedGroupIds = new Set(importedGroups.map((g) => g.id));
      const importedRules = normalizeRules(parsed?.rules, importedGroupIds, importedGroups[0]?.id ?? DEFAULT_GROUP_ID);

      const currentGroupIds = new Set(groups.map((g) => g.id));
      const currentRuleIds = new Set(rules.map((r) => r.id));

      const groupIdMap = new Map<string, string>();
      const mergedGroups = importedGroups.map((group) => {
        let nextId = group.id;
        if (currentGroupIds.has(nextId) || groupIdMap.has(nextId)) {
          nextId = genId();
        }
        groupIdMap.set(group.id, nextId);
        currentGroupIds.add(nextId);
        return { ...group, id: nextId };
      });

      const mergedRules = importedRules.map((rule) => {
        let nextRuleId = rule.id;
        if (currentRuleIds.has(nextRuleId)) nextRuleId = genId();
        currentRuleIds.add(nextRuleId);
        const nextConditions = rule.conditions.map((condition) => ({
          ...condition,
          id: genId(),
        }));
        return {
          ...rule,
          id: nextRuleId,
          groupId: groupIdMap.get(rule.groupId) ?? groups[0]?.id ?? DEFAULT_GROUP_ID,
          conditions: nextConditions,
        };
      });

      setGroups((prev) => [...prev, ...mergedGroups]);
      setRules((prev) => [...prev, ...mergedRules]);
      message.success(`导入成功：新增 ${mergedGroups.length} 个规则组，${mergedRules.length} 条规则`);
    } catch {
      message.error('导入失败，请检查配置文件格式');
    }
  };

  if (currentRule) {
    const detailProps = {
      groups,
      workingRule: currentRule,
      originalRule,
      setWorkingRule,
      setRules,
      onBack,
      saveDetailRule,
      toggleDetailRuleEnabled,
      setPageToList: () => setPage({ type: 'list' }),
    };

    if (currentRule.type === 'redirect_request') {
      return <RedirectRuleDetail {...detailProps} messageApi={message} />;
    }
    if (currentRule.type === 'rewrite_string') return <RewriteStringRuleDetail {...detailProps} messageApi={message} />;
    if (currentRule.type === 'query_params') return <QueryParamsRuleDetail {...detailProps} messageApi={message} />;
    if (currentRule.type === 'modify_request_body') return <ModifyRequestBodyRuleDetail {...detailProps} />;
    if (currentRule.type === 'modify_response_body') return <ModifyResponseBodyRuleDetail {...detailProps} />;
    if (currentRule.type === 'modify_headers') return <ModifyHeadersRuleDetail {...detailProps} />;
    if (currentRule.type === 'user_agent') return <UserAgentRuleDetail {...detailProps} />;
    if (currentRule.type === 'cancel_request') return <CancelRequestRuleDetail {...detailProps} />;
    return <RequestDelayRuleDetail {...detailProps} />;
  }

  return <>
    <input ref={importInputRef} type="file" accept="application/json" style={{ display: 'none' }} onChange={onImportFileChange} />
      <RedirectRuleList
      groups={groups}
      rules={rules}
      redirectEnabled={redirectEnabled}
      collapsedGroupIds={collapsedGroupIds}
      groupModal={groupModal}
      groupInput={groupInput}
      setRedirectEnabled={setRedirectEnabled}
      setCollapsedGroupIds={setCollapsedGroupIds}
      setGroupModal={setGroupModal}
      setGroupInput={setGroupInput}
      createRule={createRule}
      openRuleDetail={openRuleDetail}
      duplicateGroup={duplicateGroup}
      deleteGroup={deleteGroup}
      confirmGroupModal={confirmGroupModal}
        setRules={setRules}
        setGroups={setGroups}
        messageApi={message}
        exportConfig={exportConfig}
        importConfig={importConfig}
      />
  </>;
}
