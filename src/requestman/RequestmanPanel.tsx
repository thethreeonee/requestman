import React, { Suspense, lazy, useEffect, useMemo, useRef, useState } from 'react';
import { App, Button, Modal, Segmented, Space, Switch, Typography } from 'antd';
import {
  DEFAULT_GROUP_ID,
  REDIRECT_ENABLED_KEY,
  REDIRECT_GROUPS_KEY,
  REDIRECT_RULES_KEY,
  DEFAULT_MODIFY_REQUEST_BODY_SCRIPT,
  DEFAULT_MODIFY_RESPONSE_BODY_SCRIPT,
} from './constants';
import { t } from './i18n';
import {
  createDefaultCondition,
  genId,
  getConditionRedirectTarget,
  hasModifyRequestBodyFunction,
  hasModifyResponseBodyFunction,
  normalizeGroups,
  normalizeRules,
  simulateRedirect,
} from './rule-utils';
import type { RedirectGroup, RedirectRule } from './types';
import RedirectRuleList from './components/RedirectRuleList';
import RuleTestPanel from './components/RuleTestPanel';
import './index.css';

const RedirectRuleDetail = lazy(() => import('./components/RedirectRuleDetail'));
const RewriteStringRuleDetail = lazy(() => import('./components/RewriteStringRuleDetail'));
const QueryParamsRuleDetail = lazy(() => import('./components/QueryParamsRuleDetail'));
const ModifyRequestBodyRuleDetail = lazy(() => import('./components/ModifyRequestBodyRuleDetail'));
const ModifyResponseBodyRuleDetail = lazy(() => import('./components/ModifyResponseBodyRuleDetail'));
const ModifyHeadersRuleDetail = lazy(() => import('./components/ModifyHeadersRuleDetail'));
const UserAgentRuleDetail = lazy(() => import('./components/UserAgentRuleDetail'));
const CancelRequestRuleDetail = lazy(() => import('./components/CancelRequestRuleDetail'));
const RequestDelayRuleDetail = lazy(() => import('./components/RequestDelayRuleDetail'));

type PageState = { type: 'list' } | { type: 'detail'; ruleId: string; isNew: boolean };

export default function RequestmanPanel() {
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
  const [themeMode, setThemeMode] = useState<'light' | 'dark' | 'system'>('system');
  const [effectiveTheme, setEffectiveTheme] = useState<'light' | 'dark'>('light');
  const [testUrl, setTestUrl] = useState('');
  const [testResult, setTestResult] = useState<ReturnType<typeof simulateRedirect> | null>(null);

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

  useEffect(() => {
    const mediaQuery = window.matchMedia('(prefers-color-scheme: dark)');
    const applyTheme = () => setEffectiveTheme(themeMode === 'system' ? (mediaQuery.matches ? 'dark' : 'light') : themeMode);
    applyTheme();
    mediaQuery.addEventListener('change', applyTheme);
    return () => mediaQuery.removeEventListener('change', applyTheme);
  }, [themeMode]);

  const handleRedirectEnabledChange = (value: boolean) => {
    setRedirectEnabled(value);
    message.success(value ? t('总开关已开启', 'Master switch enabled') : t('总开关已关闭', 'Master switch disabled'));
  };

  const triggerRuleTest = () => {
    const groupEnabledMap = new Map(groups.map((g) => [g.id, g.enabled]));
    setTestResult(simulateRedirect(testUrl, rules, groupEnabledMap));
  };

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
      name: `${t('新建规则', 'New rule')} ${rules.length + 1}`,
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
        title: t('存在未保存修改', 'Unsaved changes'),
        content: t('修改不会被保存，确认返回吗？', 'Changes will not be saved. Leave anyway?'),
        onOk: () => setPage({ type: 'list' }),
      });
      return;
    }
    setPage({ type: 'list' });
  };

  const saveDetailRule = () => {
    if (!workingRule || page.type !== 'detail') return false;
    if (workingRule.type === 'redirect_request') {
      const invalid = workingRule.conditions.some((c) => !c.expression.trim() || !getConditionRedirectTarget(c));
      if (invalid) {
        message.warning(t('还有条件配置未输入完整', 'Some conditions are incomplete.'));
        return false;
      }
    }
    if (workingRule.type === 'rewrite_string') {
      const invalid = workingRule.conditions.some((c) => !c.expression.trim() || !c.rewriteFrom.trim());
      if (invalid) {
        message.warning(t('还有条件配置未输入完整', 'Some conditions are incomplete.'));
        return false;
      }
    }
    if (workingRule.type === 'query_params') {
      const invalid = workingRule.conditions.some((c) => {
        if (!c.expression.trim() || c.queryParamModifications.length === 0) return true;
        return c.queryParamModifications.some((item) => !item.key.trim() || (item.action !== 'delete' && !item.value.trim()));
      });
      if (invalid) {
        message.warning(t('还有条件配置未输入完整', 'Some conditions are incomplete.'));
        return false;
      }
    }


    if (workingRule.type === 'modify_request_body') {
      const invalid = workingRule.conditions.some((c) => {
        if (!c.expression.trim()) return true;
        if (c.requestBodyMode === 'dynamic') {
          const script = c.requestBodyDynamicValue.trim() || DEFAULT_MODIFY_REQUEST_BODY_SCRIPT;
          return !hasModifyRequestBodyFunction(script);
        }
        return !c.requestBodyStaticValue.trim();
      });
      if (invalid) {
        message.warning(t('还有条件配置未输入完整或 JavaScript 无效', 'Some conditions are incomplete or JavaScript is invalid.'));
        return false;
      }
    }


    if (workingRule.type === 'modify_response_body') {
      const invalid = workingRule.conditions.some((c) => {
        if (!c.expression.trim()) return true;
        if (c.responseBodyMode === 'dynamic') {
          const script = c.responseBodyDynamicValue.trim() || DEFAULT_MODIFY_RESPONSE_BODY_SCRIPT;
          return !hasModifyResponseBodyFunction(script);
        }
        return !c.responseBodyStaticValue.trim();
      });
      if (invalid) {
        message.warning(t('还有条件配置未输入完整或 JavaScript 无效', 'Some conditions are incomplete or JavaScript is invalid.'));
        return false;
      }
    }

    if (workingRule.type === 'user_agent') {
      const invalid = workingRule.conditions.some((c) => {
        if (!c.expression.trim()) return true;
        const type = c.userAgentType ?? 'device';
        if (type === 'custom') return !c.userAgentCustomValue?.trim();
        return !c.userAgentPresetKey?.trim();
      });
      if (invalid) {
        message.warning(t('还有条件配置未输入完整', 'Some conditions are incomplete.'));
        return false;
      }
    }

    if (workingRule.type === 'request_delay') {
      const invalid = workingRule.conditions.some((c) => !c.expression.trim() || !Number.isFinite(c.delayMs) || c.delayMs < 0);
      if (invalid) {
        message.warning(t('还有条件配置未输入完整', 'Some conditions are incomplete.'));
        return false;
      }
    }

    if (workingRule.type === 'modify_headers') {
      const invalid = workingRule.conditions.some((c) => {
        const allModifications = [...c.requestHeaderModifications, ...c.responseHeaderModifications];
        const hasAnyModificationInput = allModifications.some((item) => item.key.trim() || item.value.trim());
        const hasValidModification = allModifications.some((item) => item.key.trim() && (item.action === 'delete' || item.value.trim()));
        const hasInvalidPartialModification = allModifications.some((item) => {
          const hasAnyInput = !!(item.key.trim() || item.value.trim());
          if (!hasAnyInput) return false;
          return !item.key.trim() || (item.action !== 'delete' && !item.value.trim());
        });
        if (!c.expression.trim()) return true;
        if (!hasAnyModificationInput) return true;
        if (!hasValidModification) return true;
        return hasInvalidPartialModification;
      });
      if (invalid) {
        message.warning(t('还有条件配置未输入完整', 'Some conditions are incomplete.'));
        return false;
      }
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
    return true;
  };

  const toggleDetailRuleEnabled = (ruleId: string, enabled: boolean) => {
    setRules((prev) => prev.map((rule) => (rule.id === ruleId ? { ...rule, enabled } : rule)));
    setWorkingRule((prev) => (prev?.id === ruleId ? { ...prev, enabled } : prev));
    setOriginalRule((prev) => (prev?.id === ruleId ? { ...prev, enabled } : prev));
    if (enabled) {
      message.success({ content: t('规则已启用', 'Rule enabled'), duration: 0.8 });
      return;
    }
    message.warning({ content: t('规则已停用', 'Rule disabled'), duration: 0.8 });
  };

  const moveRuleToGroup = () => {
    if (!groupModal.ruleId) return;
    const target = groups.find((g) => g.id === groupInput);
    if (!target) return;
    const movedRule = rules.find((r) => r.id === groupModal.ruleId);
    if (!movedRule) return;
    setRules((prev) => prev.map((r) => (r.id === groupModal.ruleId ? { ...r, groupId: target.id } : r)));
    message.success(t(`规则「${movedRule.name}」已移动到规则组「${target.name}」`, `Rule "${movedRule.name}" moved to group "${target.name}".`));
    setGroupModal({ open: false, mode: 'create' });
    setGroupInput('');
  };

  const confirmGroupModal = () => {
    if (groupModal.mode === 'move') return moveRuleToGroup();
    const name = groupInput.trim();
    if (!name) return;
    if (groupModal.mode === 'create') {
      setGroups((prev) => [{ id: genId(), name, enabled: true }, ...prev]);
      message.success(t(`规则组「${name}」已创建`, `Group "${name}" created.`));
    }
    if (groupModal.mode === 'rename' && groupModal.groupId) {
      const group = groups.find((g) => g.id === groupModal.groupId);
      setGroups((prev) => prev.map((g) => (g.id === groupModal.groupId ? { ...g, name } : g)));
      message.success(t(`规则组「${group?.name ?? ''}」已重命名为「${name}」`, `Group "${group?.name ?? ''}" renamed to "${name}".`));
    }
    setGroupModal({ open: false, mode: 'create' });
    setGroupInput('');
  };

  const deleteGroup = (groupId: string) => {
    Modal.confirm({
      title: t('确认删除该规则组？', 'Delete this group?'),
      content: t('删除规则组会同时删除组内所有规则。', 'Deleting a group will also remove all rules in it.'),
      okButtonProps: { danger: true },
      onOk: () => {
        const deletedGroup = groups.find((g) => g.id === groupId);
        const deletedRuleCount = rules.filter((r) => r.groupId === groupId).length;
        setGroups((prev) => prev.filter((g) => g.id !== groupId));
        setRules((prev) => prev.filter((r) => r.groupId !== groupId));
        message.success(t(`规则组「${deletedGroup?.name ?? ''}」已删除（含 ${deletedRuleCount} 条规则）`, `Group "${deletedGroup?.name ?? ''}" deleted (${deletedRuleCount} rules).`));
      },
    });
  };

  const duplicateGroup = (groupId: string) => {
    const group = groups.find((g) => g.id === groupId);
    if (!group) return;
    const newGroupId = genId();
    setGroups((prev) => {
      const idx = prev.findIndex((g) => g.id === groupId);
      const cp = { ...group, id: newGroupId, name: `${group.name} ${t('副本', 'Copy')}` };
      const next = [...prev];
      next.splice(idx + 1, 0, cp);
      return next;
    });
    setRules((prev) => {
      const selected = prev.filter((r) => r.groupId === groupId).map((r) => ({ ...r, id: genId(), groupId: newGroupId, name: `${r.name} ${t('副本', 'Copy')}` }));
      return [...prev, ...selected];
    });
    message.success(t(`规则组「${group.name}」已复制`, `Group "${group.name}" duplicated.`));
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
      message.success(t(`导入成功：新增 ${mergedGroups.length} 个规则组，${mergedRules.length} 条规则`, `Imported successfully: ${mergedGroups.length} new groups and ${mergedRules.length} rules.`));
    } catch {
      message.error(t('导入失败，请检查配置文件格式', 'Import failed. Please check the config file format.'));
    }
  };


  let editorNode: React.ReactNode = (
    <div className="editor-placeholder">
      <Typography.Title level={4} style={{ marginTop: 0 }}>{t('选择一条规则开始编辑', 'Select a rule to start editing')}</Typography.Title>
      <Typography.Text type="secondary">{t('左侧规则列表选择规则后，可在此处编辑。', 'Select a rule from the sidebar to edit it here.')}</Typography.Text>
    </div>
  );

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
      editorNode = <RedirectRuleDetail {...detailProps} messageApi={message} />;
    } else if (currentRule.type === 'rewrite_string') {
      editorNode = <RewriteStringRuleDetail {...detailProps} messageApi={message} />;
    } else if (currentRule.type === 'query_params') {
      editorNode = <QueryParamsRuleDetail {...detailProps} messageApi={message} />;
    } else if (currentRule.type === 'modify_request_body') {
      editorNode = <ModifyRequestBodyRuleDetail {...detailProps} messageApi={message} />;
    } else if (currentRule.type === 'modify_response_body') {
      editorNode = <ModifyResponseBodyRuleDetail {...detailProps} messageApi={message} />;
    } else if (currentRule.type === 'modify_headers') {
      editorNode = <ModifyHeadersRuleDetail {...detailProps} messageApi={message} />;
    } else if (currentRule.type === 'user_agent') {
      editorNode = <UserAgentRuleDetail {...detailProps} messageApi={message} />;
    } else if (currentRule.type === 'cancel_request') {
      editorNode = <CancelRequestRuleDetail {...detailProps} messageApi={message} />;
    } else {
      editorNode = <RequestDelayRuleDetail {...detailProps} messageApi={message} />;
    }
  }

  const groupNameMap = new Map(groups.map((group) => [group.id, group.name]));

  return <div className="requestman-shell" data-theme={effectiveTheme}>
    <input ref={importInputRef} type="file" accept="application/json" style={{ display: 'none' }} onChange={onImportFileChange} />
    <div className="global-toolbar">
      <div className="toolbar-left-tools">
        <span className="toolbar-logo" aria-hidden>◎</span>
        <Typography.Text strong>Requestman</Typography.Text>
        <Space size={8}>
          <Typography.Text type="secondary">MASTER</Typography.Text>
          <Switch checked={redirectEnabled} onChange={handleRedirectEnabledChange} />
        </Space>
      </div>
      <div className="toolbar-right-tools">
        <Button onClick={importConfig}>{t('导入配置', 'Import')}</Button>
        <Button onClick={exportConfig}>{t('导出配置', 'Export')}</Button>
        <Segmented
          value={themeMode}
          onChange={(value) => setThemeMode(value as 'light' | 'dark' | 'system')}
          options={[
            { label: 'Light', value: 'light' },
            { label: 'Dark', value: 'dark' },
            { label: 'System', value: 'system' },
          ]}
        />
      </div>
    </div>

    <div className="main-body-layout">
      <aside className="main-sidebar">
        <RedirectRuleList
          groups={groups}
          rules={rules}
          redirectEnabled={redirectEnabled}
          collapsedGroupIds={collapsedGroupIds}
          groupModal={groupModal}
          groupInput={groupInput}
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
        />
      </aside>
      <main className="main-editor">
        <Suspense fallback={<div style={{ padding: 16 }}>{t('加载中...', 'Loading...')}</div>}>
          {editorNode}
        </Suspense>
      </main>
      <aside className="main-test-panel">
        <RuleTestPanel
          testUrl={testUrl}
          setTestUrl={setTestUrl}
          triggerTest={triggerRuleTest}
          testResult={testResult}
          groupNameMap={groupNameMap}
        />
      </aside>
    </div>
  </div>;
}
