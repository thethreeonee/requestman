import React from 'react';
import { Button } from '@/components/animate-ui/components/buttons/button';
import { Switch } from '@/components/animate-ui/components/radix/switch';
import { Ellipsis } from '@/components/animate-ui/icons/ellipsis';
import type { RedirectGroup, RedirectRule } from '../types';
import { t } from '../i18n';
import { renderRuleTypeIcon } from '../rule-type-meta';
import RuleActionsMenu from './RuleActionsMenu';

type Props = {
  rule: RedirectRule;
  groups: RedirectGroup[];
  isNewRule: boolean;
  dirty: boolean;
  onGroupChange: (groupId: string) => void;
  onEnabledChange: (enabled: boolean) => void;
  onTest: () => void;
  onSave: () => boolean | void;
  onRename: (name: string) => void;
  onDuplicate: () => void;
  onDelete: () => void;
};

export default function RuleDetailToolbar({
  rule,
  groups,
  isNewRule,
  dirty,
  onGroupChange,
  onEnabledChange,
  onTest,
  onSave,
  onRename,
  onDuplicate,
  onDelete,
}: Props) {
  return <>
    <div className="detail-header">
      <div className="detail-header__title">
        <span className="detail-header__title-icon" aria-hidden="true">{renderRuleTypeIcon(rule.type)}</span>
        <span className="detail-header__title-text">{rule.name || t('未命名规则', 'Untitled rule')}</span>
        <Switch
          checked={rule.enabled}
          onCheckedChange={onEnabledChange}
          aria-label={rule.enabled ? t('禁用规则', 'Disable rule') : t('启用规则', 'Enable rule')}
          className="detail-header__enabled-switch"
        />
      </div>
      <div className="aui-space">
        <RuleActionsMenu
          rule={rule}
          groups={groups}
          dirty={dirty}
          isNewRule={isNewRule}
          onGroupChange={onGroupChange}
          onRename={onRename}
          onDuplicate={onDuplicate}
          onDelete={onDelete}
          onSave={onSave}
          trigger={(
            <span>
              <Button
                variant="outline"
                size="icon"
                className="detail-header__menu-btn"
                aria-label={t('规则操作', 'Rule actions')}
              >
                <Ellipsis size={16} />
              </Button>
            </span>
          )}
        />
        <Button variant="outline" onClick={onTest}>{t('测试', 'Test')}</Button>
        <Button
          variant="default"
          disabled={!dirty}
          onClick={() => {
            onSave();
          }}
        >
          <span>{t('保存规则', 'Save rule')}</span>
        </Button>
      </div>
    </div>
  </>;
}
