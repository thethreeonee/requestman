import React, { useMemo } from 'react';
import { AnimateIcon } from '@/components/animate-ui/icons/icon';
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
};

export default function RuleTree({
  groups,
  rules,
  activeRuleId,
  onSelectRule,
  onCreateGroup,
  onCreateRule,
}: Props) {
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

                  return (
                    <Collapsible
                      key={group.id}
                      defaultOpen
                      className="group/collapsible"
                    >
                      <SidebarMenuItem>
                        <CollapsibleTrigger asChild>
                          <AnimateIcon animateOnHover asChild>
                            <SidebarMenuButton tooltip={group.name}>
                              <Layers size={16} />
                              <span>{group.name}</span>
                              <ChevronRight className="ml-auto transition-transform duration-300 group-data-[state=open]/collapsible:rotate-90" />
                            </SidebarMenuButton>
                          </AnimateIcon>
                        </CollapsibleTrigger>
                        <CollapsibleContent className="rule-tree-sidebar__collapsible-content">
                          <SidebarMenuSub>
                            {groupRules.length > 0
                              ? groupRules.map((rule) => (
                                <SidebarMenuSubItem key={rule.id}>
                                  <AnimateIcon animateOnHover asChild>
                                    <SidebarMenuSubButton
                                      asChild
                                      isActive={activeRuleId === rule.id}
                                      className="rule-tree-sidebar__rule-sub-button"
                                    >
                                      <button
                                        type="button"
                                        className="rule-tree-sidebar__rule-button"
                                        onClick={() => onSelectRule(rule.id)}
                                      >
                                        <span className="rule-tree-sidebar__rule-icon" aria-hidden="true">
                                          {renderRuleTypeIcon(rule.type)}
                                        </span>
                                        <span>{rule.name}</span>
                                      </button>
                                    </SidebarMenuSubButton>
                                  </AnimateIcon>
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
