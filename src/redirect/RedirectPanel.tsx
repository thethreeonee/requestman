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

  const createRule = () => {
    const groupId = groups[0]?.id;
    if (!groupId) return;
    const newRule: RedirectRule = { id: genId(), name: `新建规则 ${rules.length + 1}`, type: 'redirect_request', enabled: true, groupId, conditions: [createDefaultCondition()] };
    setWorkingRule(JSON.parse(JSON.stringify(newRule)));
    setOriginalRule(JSON.parse(JSON.stringify(newRule)));
    setPage({ type: 'detail', ruleId: newRule.id, isNew: true });
  };

  const onBack = () => {
    if (!workingRule || !originalRule) return setPage({ type: 'list' });
    if (JSON.stringify(workingRule) !== JSON.stringify(originalRule)) {
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
    const invalid = workingRule.conditions.some((c) => !c.expression.trim() || !c.redirectTarget.trim());
    if (invalid) return message.warning('还有条件配置未输入完整');
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

  const moveRuleToGroup = () => {
    if (!groupModal.ruleId) return;
    const name = groupInput.trim();
    if (!name) return;
    let target = groups.find((g) => g.name === name);
    if (!target) {
      target = { id: genId(), name, enabled: true };
      setGroups((prev) => [...prev, target!]);
    }
    setRules((prev) => prev.map((r) => (r.id === groupModal.ruleId ? { ...r, groupId: target!.id } : r)));
    setGroupModal({ open: false, mode: 'create' });
    setGroupInput('');
  };

  const confirmGroupModal = () => {
    if (groupModal.mode === 'move') return moveRuleToGroup();
    const name = groupInput.trim();
    if (!name) return;
    if (groupModal.mode === 'create') setGroups((prev) => [{ id: genId(), name, enabled: true }, ...prev]);
    if (groupModal.mode === 'rename' && groupModal.groupId) setGroups((prev) => prev.map((g) => (g.id === groupModal.groupId ? { ...g, name } : g)));
    setGroupModal({ open: false, mode: 'create' });
    setGroupInput('');
  };

  const deleteGroup = (groupId: string) => {
    Modal.confirm({
      title: '确认删除该规则组？',
      content: '删除规则组会同时删除组内所有规则。',
      okButtonProps: { danger: true },
      onOk: () => {
        setGroups((prev) => prev.filter((g) => g.id !== groupId));
        setRules((prev) => prev.filter((r) => r.groupId !== groupId));
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
  };

  const currentRule = useMemo(() => {
    if (page.type !== 'detail' || !workingRule) return null;
    return workingRule;
  }, [page, workingRule]);

  if (currentRule) {
    return <RedirectRuleDetail
      groups={groups}
      workingRule={currentRule}
      originalRule={originalRule}
      setWorkingRule={setWorkingRule}
      setRules={setRules}
      onBack={onBack}
      saveDetailRule={saveDetailRule}
      setPageToList={() => setPage({ type: 'list' })}
      messageApi={message}
    />;
  }

  return <RedirectRuleList
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
  />;
}
