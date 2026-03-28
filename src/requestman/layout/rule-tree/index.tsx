import React, { useMemo } from 'react';
import { AnimateIcon } from '@/components/animate-ui/icons/icon';
import { EllipsisVertical } from '@/components/animate-ui/icons/ellipsis-vertical';
import { Plus } from '@/components/animate-ui/icons/plus';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@/components/animate-ui/components/radix/dropdown-menu';
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarMenuSub,
  SidebarMenuSubButton,
  SidebarMenuSubItem,
  SidebarProvider,
} from '@/components/animate-ui/components/radix/sidebar';
import {
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
} from '@/components/animate-ui/primitives/radix/collapsible';
import { ChevronRight } from 'lucide-react';
import { Layers } from '@/components/animate-ui/icons/layers';
import RuleActionsMenu from '../../components/RuleActionsMenu';
import { Button } from '../../components';
import { t } from '../../i18n';
import {
  RULE_TYPE_LABEL_MAP,
  RULE_TYPE_ORDER,
  renderRuleTypeIcon,
} from '../../rule-type-meta';
import type { RedirectGroup, RedirectRule } from '../../types';

type Props = {
  groups: RedirectGroup[];
  rules: RedirectRule[];
  activeRuleId?: string;
  onSelectRule: (ruleId: string) => void;
  onCreateGroup: () => void;
  onCreateRule: (type: RedirectRule['type']) => void;
  onRenameGroup: (groupId: string) => void;
  onDuplicateGroup: (groupId: string) => void;
  onDeleteGroup: (groupId: string) => void;
  onRenameRule: (ruleId: string, name: string) => void;
  onMoveRuleToGroup: (ruleId: string, groupId: string) => void;
  onDuplicateRule: (ruleId: string) => void;
  onDeleteRule: (ruleId: string) => void;
  activeRuleDirty?: boolean;
  activeRuleIsNew?: boolean;
  onSaveActiveRule?: () => boolean | void;
};

export default function RuleTree({
  groups,
  rules,
  activeRuleId,
  onSelectRule,
  onCreateGroup,
  onCreateRule,
  onRenameGroup,
  onDuplicateGroup,
  onDeleteGroup,
  onRenameRule,
  onMoveRuleToGroup,
  onDuplicateRule,
  onDeleteRule,
  activeRuleDirty = false,
  activeRuleIsNew = false,
  onSaveActiveRule,
}: Props) {
  const stopRuleSelection = (event: React.SyntheticEvent) => {
    event.stopPropagation();
  };

  const stopGroupToggle = (event: React.SyntheticEvent) => {
    event.stopPropagation();
  };

  const stopGroupMenuItemPropagation = (
    event: Event | React.SyntheticEvent,
  ) => {
    event.stopPropagation();
  };

  const rulesByGroup = useMemo(() => {
    const next = new Map<string, RedirectRule[]>();
    for (const rule of rules) {
      const current = next.get(rule.groupId);
      if (current) {
        current.push(rule);
      } else {
        next.set(rule.groupId, [rule]);
      }
    }
    return next;
  }, [rules]);

  return (
    <aside className="main-sidebar">
      <SidebarProvider className="main-sidebar-provider">
        <Sidebar
          collapsible="none"
          className="rule-tree-sidebar w-full"
          containerClassName="rule-tree-sidebar__container"
        >
          <SidebarContent className="rule-tree-sidebar__content">
            <SidebarGroup>
              <SidebarMenu>
                {groups.map((group) => {
                  const groupRules = rulesByGroup.get(group.id) ?? [];
                  const enabledRuleCount = group.enabled
                    ? groupRules.filter((rule) => rule.enabled).length
                    : 0;

                  return (
                    <Collapsible
                      key={group.id}
                      defaultOpen
                      className="group/collapsible"
                    >
                      <SidebarMenuItem>
                        <CollapsibleTrigger asChild>
                          <AnimateIcon animateOnHover asChild>
                            <SidebarMenuButton
                              tooltip={group.name}
                              className="rule-tree-sidebar__group-button"
                            >
                              <Layers size={16} />
                              <span className="rule-tree-sidebar__group-label">{group.name}</span>
                              <span className="rule-tree-sidebar__group-count">
                                {t(
                                  `( ${enabledRuleCount} / ${groupRules.length} )`,
                                  `( ${enabledRuleCount} / ${groupRules.length} )`,
                                )}
                              </span>
                              <span className="rule-tree-sidebar__group-spacer" />
                              <DropdownMenu modal={false}>
                                <DropdownMenuTrigger asChild>
                                  <button
                                    type="button"
                                    aria-label={t('规则组操作', 'Group actions')}
                                    className="rule-tree-sidebar__group-action"
                                    onClick={stopGroupToggle}
                                    onMouseDown={stopGroupToggle}
                                    onPointerDown={stopGroupToggle}
                                    onKeyDown={stopGroupToggle}
                                  >
                                    <AnimateIcon animateOnHover asChild>
                                      <span className="rule-tree-sidebar__group-action-icon">
                                        <EllipsisVertical size={14} animation="pulse" />
                                      </span>
                                    </AnimateIcon>
                                  </button>
                                </DropdownMenuTrigger>
                                <DropdownMenuContent
                                  align="start"
                                  side="right"
                                  sideOffset={8}
                                  onClick={stopGroupMenuItemPropagation}
                                  onPointerDown={stopGroupMenuItemPropagation}
                                >
                                  <DropdownMenuItem
                                    onSelect={(event) => {
                                      stopGroupMenuItemPropagation(event);
                                      onRenameGroup(group.id);
                                    }}
                                  >
                                    <span>{t('重命名', 'Rename')}</span>
                                  </DropdownMenuItem>
                                  <DropdownMenuItem
                                    onSelect={(event) => {
                                      stopGroupMenuItemPropagation(event);
                                      onDuplicateGroup(group.id);
                                    }}
                                  >
                                    <span>{t('复制', 'Duplicate')}</span>
                                  </DropdownMenuItem>
                                  <DropdownMenuItem
                                    variant="destructive"
                                    onSelect={(event) => {
                                      stopGroupMenuItemPropagation(event);
                                      onDeleteGroup(group.id);
                                    }}
                                  >
                                    <span>{t('删除', 'Delete')}</span>
                                  </DropdownMenuItem>
                                </DropdownMenuContent>
                              </DropdownMenu>
                              <ChevronRight className="ml-auto transition-transform duration-300 group-data-[state=open]/collapsible:rotate-90" />
                            </SidebarMenuButton>
                          </AnimateIcon>
                        </CollapsibleTrigger>
                        <CollapsibleContent className="rule-tree-sidebar__collapsible-content">
                          <SidebarMenuSub>
                            {groupRules.length > 0
                              ? groupRules.map((rule) => (
                                <SidebarMenuSubItem key={rule.id} className="rule-tree-sidebar__rule-item">
                                  <AnimateIcon animateOnHover asChild>
                                    <SidebarMenuSubButton
                                      asChild
                                      isActive={activeRuleId === rule.id}
                                      className={`rule-tree-sidebar__rule-sub-button${!group.enabled || !rule.enabled ? ' rule-tree-sidebar__rule-sub-button--disabled' : ''}`}
                                    >
                                      <button
                                        type="button"
                                        className="rule-tree-sidebar__rule-button"
                                        onClick={() => onSelectRule(rule.id)}
                                      >
                                        <span className="rule-tree-sidebar__rule-icon" aria-hidden="true">
                                          {renderRuleTypeIcon(rule.type)}
                                        </span>
                                        <span className="rule-tree-sidebar__rule-label">{rule.name}</span>
                                      </button>
                                    </SidebarMenuSubButton>
                                  </AnimateIcon>
                                  <RuleActionsMenu
                                    rule={rule}
                                    groups={groups}
                                    dirty={activeRuleId === rule.id ? activeRuleDirty : false}
                                    isNewRule={activeRuleId === rule.id ? activeRuleIsNew : false}
                                    onSave={activeRuleId === rule.id ? onSaveActiveRule : undefined}
                                    onRename={(name) => onRenameRule(rule.id, name)}
                                    onGroupChange={(nextGroupId) => onMoveRuleToGroup(rule.id, nextGroupId)}
                                    onDuplicate={() => onDuplicateRule(rule.id)}
                                    onDelete={() => onDeleteRule(rule.id)}
                                    contentProps={{
                                      align: 'start',
                                      side: 'right',
                                      sideOffset: 8,
                                    }}
                                    trigger={(
                                      <button
                                        type="button"
                                        className="rule-tree-sidebar__rule-action"
                                        aria-label={t('规则操作', 'Rule actions')}
                                        onClick={stopRuleSelection}
                                        onMouseDown={stopRuleSelection}
                                        onPointerDown={stopRuleSelection}
                                        onKeyDown={stopRuleSelection}
                                      >
                                        <AnimateIcon animateOnHover asChild>
                                          <span className="rule-tree-sidebar__rule-action-icon">
                                            <EllipsisVertical size={14} animation="pulse" />
                                          </span>
                                        </AnimateIcon>
                                      </button>
                                    )}
                                  />
                                </SidebarMenuSubItem>
                              ))
                              : (
                                <SidebarMenuSubItem
                                  aria-hidden="true"
                                  className="pointer-events-none select-none"
                                >
                                  <div className="rule-tree-sidebar__empty-placeholder">
                                    {t('暂无规则', 'No rules yet')}
                                  </div>
                                </SidebarMenuSubItem>
                              )}
                          </SidebarMenuSub>
                        </CollapsibleContent>
                      </SidebarMenuItem>
                    </Collapsible>
                  );
                })}
              </SidebarMenu>
            </SidebarGroup>
          </SidebarContent>
          <SidebarFooter className="rule-tree-sidebar__footer">
            <div className="rule-tree-sidebar__footer-actions">
              <AnimateIcon animateOnHover asChild>
                <Button
                  variant="outline"
                  size="sm"
                  className="rule-tree-sidebar__footer-button rule-tree-sidebar__footer-button--group"
                  onClick={onCreateGroup}
                >
                  <Layers size={16} />
                  <span>新建规则组</span>
                </Button>
              </AnimateIcon>
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <span className="rule-tree-sidebar__footer-trigger">
                    <AnimateIcon animateOnHover asChild>
                      <Button
                        variant="default"
                        size="sm"
                        className="rule-tree-sidebar__footer-button rule-tree-sidebar__footer-button--rule"
                      >
                        <Plus size={16} />
                        <span>新建规则</span>
                      </Button>
                    </AnimateIcon>
                  </span>
                </DropdownMenuTrigger>
                <DropdownMenuContent
                  align="end"
                  side="top"
                  className="rule-tree-sidebar__create-rule-menu"
                >
                  {RULE_TYPE_ORDER.map((type) => (
                    <AnimateIcon key={type} animateOnHover asChild>
                      <DropdownMenuItem onSelect={() => onCreateRule(type)}>
                        {renderRuleTypeIcon(type)}
                        <span>{RULE_TYPE_LABEL_MAP[type]}</span>
                      </DropdownMenuItem>
                    </AnimateIcon>
                  ))}
                </DropdownMenuContent>
              </DropdownMenu>
            </div>
          </SidebarFooter>
        </Sidebar>
      </SidebarProvider>
    </aside>
  );
}
